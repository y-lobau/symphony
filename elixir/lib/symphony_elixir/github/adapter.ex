defmodule SymphonyElixir.GitHub.Adapter do
  @moduledoc """
  GitHub Issues-backed tracker adapter.
  """

  @behaviour SymphonyElixir.Tracker

  alias SymphonyElixir.Config
  alias SymphonyElixir.GitHub.{AgentTool, Client, ProjectV2}
  alias SymphonyElixir.Tracker.Issue

  @active_states ["open"]
  @terminal_states ["closed"]

  @spec validate_config(map()) :: :ok | {:error, term()}
  def validate_config(tracker_settings) do
    with :ok <-
           validate_states(
             tracker_settings.active_states,
             @active_states,
             :missing_github_active_states
           ),
         :ok <-
           validate_states(
             tracker_settings.terminal_states,
             @terminal_states,
             :missing_github_terminal_states
           ),
         :ok <- validate_comment_policy(tracker_settings.provider) do
      Client.validate_settings(tracker_settings)
    end
  end

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_states(states) do
    with {:ok, issues} <- client_module().fetch_issues_by_states(states) do
      attach_project_statuses(issues)
    end
  end

  @spec fetch_issues_by_ids([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_ids(issue_ids) do
    with {:ok, issues} <- client_module().fetch_issues_by_ids(issue_ids) do
      attach_project_statuses(issues)
    end
  end

  @spec agent_tool_specs() :: [map()]
  def agent_tool_specs, do: AgentTool.tool_specs()

  @spec execute_agent_tool(String.t(), term(), keyword()) :: map()
  def execute_agent_tool(tool, arguments, opts), do: AgentTool.execute(tool, arguments, opts)

  @spec secret_environment_names(map()) :: [String.t()]
  def secret_environment_names(tracker_settings), do: Client.secret_environment_names(tracker_settings)

  @spec on_issue_started(Issue.t()) :: :ok | {:error, term()}
  def on_issue_started(%Issue{} = issue) do
    settings = Config.settings!().tracker
    provider = settings.provider
    assignee = Map.get(provider, "agent_assignee")
    project = Map.get(provider, "project")

    results = [
      if(is_binary(assignee), do: project_module().assign_issue(issue, assignee, settings), else: :ok),
      if(is_binary(project), do: project_module().update_status(issue, "In progress", settings), else: :ok)
    ]

    lifecycle_result(results)
  end

  @spec on_issue_input_required(Issue.t()) :: :ok | {:error, term()}
  def on_issue_input_required(%Issue{} = issue) do
    settings = Config.settings!().tracker
    provider = settings.provider
    project = Map.get(provider, "project")
    if is_binary(project), do: project_module().update_status(issue, "Human in the Loop", settings), else: :ok
  end

  defp attach_project_statuses(issues) do
    settings = Config.settings!().tracker
    provider = settings.provider

    if is_binary(provider["project"]) and is_list(provider["dispatch_statuses"]) do
      Enum.reduce_while(issues, {:ok, []}, fn
        %Issue{state: "open"} = issue, {:ok, acc} ->
          attach_project_status(issue, acc, settings)

        issue, {:ok, acc} ->
          {:cont, {:ok, [issue | acc]}}
      end)
      |> case do
        {:ok, reversed} -> {:ok, Enum.reverse(reversed)}
        error -> error
      end
    else
      {:ok, issues}
    end
  end

  defp attach_project_status(issue, acc, settings) do
    if Issue.routable?(issue, settings.required_labels) do
      case project_module().status(issue, settings) do
        {:ok, status} -> {:cont, {:ok, [%{issue | project_status: status} | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    else
      {:cont, {:ok, [issue | acc]}}
    end
  end

  defp lifecycle_result(results) do
    errors = Enum.reject(results, &(&1 == :ok))

    case errors do
      [] -> :ok
      _ -> {:error, {:github_issue_lifecycle_updates_failed, errors}}
    end
  end

  defp client_module do
    Application.get_env(:symphony_elixir, :github_client_module, Client)
  end

  defp project_module do
    Application.get_env(:symphony_elixir, :github_project_module, ProjectV2)
  end

  defp validate_states(states, allowed_states, _missing_error) when is_list(states) do
    if Enum.all?(states, &(normalize_state(&1) in allowed_states)) do
      :ok
    else
      {:error, :invalid_github_states}
    end
  end

  defp validate_states(_states, _allowed_states, missing_error), do: {:error, missing_error}

  defp validate_comment_policy(provider) when is_map(provider) do
    if Map.get(provider, "comment_policy") in [nil, "handoff_only"],
      do: :ok,
      else: {:error, :invalid_github_comment_policy}
  end

  defp validate_comment_policy(_provider), do: {:error, :invalid_github_comment_policy}

  defp normalize_state(state) when is_binary(state), do: state |> String.trim() |> String.downcase()
  defp normalize_state(_state), do: ""
end
