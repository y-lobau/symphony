defmodule SymphonyElixir.GitHub.ProjectV2 do
  @moduledoc """
  Reads and updates the configured GitHub Projects v2 status for repository issues.
  """

  alias SymphonyElixir.GitHub.Client
  alias SymphonyElixir.Tracker.Issue

  @project_query """
  query($owner: String!, $repo: String!, $number: Int!) {
    organization(login: $owner) {
      projectsV2(first: 100) {
        nodes {
          id
          title
          fields(first: 100) {
            nodes {
              ... on ProjectV2SingleSelectField {
                id
                name
                options { id name }
              }
            }
          }
        }
      }
    }
    repository(owner: $owner, name: $repo) {
      issue(number: $number) {
        projectItems(first: 100) {
          nodes {
            id
            project { id title }
            fieldValueByName(name: "Status") {
              ... on ProjectV2ItemFieldSingleSelectValue { name }
            }
          }
        }
      }
    }
  }
  """

  @update_status_mutation """
  mutation($projectId: ID!, $itemId: ID!, $fieldId: ID!, $optionId: String!) {
    updateProjectV2ItemFieldValue(input: {
      projectId: $projectId,
      itemId: $itemId,
      fieldId: $fieldId,
      value: { singleSelectOptionId: $optionId }
    }) {
      projectV2Item { id }
    }
  }
  """

  @spec update_status(Issue.t(), String.t(), map()) :: :ok | {:error, term()}
  def update_status(%Issue{} = issue, status, tracker_settings) when is_binary(status) do
    with {:ok, context} <- project_context(issue, tracker_settings),
         {:ok, option} <- find_option(context.status_field, status) do
      update_project_item_status(context, option, tracker_settings)
    end
  end

  @spec status(Issue.t(), map(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def status(%Issue{} = issue, tracker_settings, opts \\ []) when is_list(opts) do
    with {:ok, context} <- project_context(issue, tracker_settings, opts),
         value when is_binary(value) <- get_in(context.item, ["fieldValueByName", "name"]) do
      {:ok, value}
    else
      nil -> {:error, :github_project_status_unset}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :github_project_status_unset}
    end
  end

  @spec assign_issue(Issue.t(), String.t(), map()) :: :ok | {:error, term()}
  def assign_issue(%Issue{id: issue_id}, username, tracker_settings)
      when is_binary(issue_id) and is_binary(username) do
    with {:ok, {owner, repo}} <- repository(tracker_settings),
         {:ok, issue_number} <- parse_issue_number(issue_id),
         {:ok, %{status: status}} <-
           Client.request(
             "POST",
             "/repos/#{owner}/#{repo}/issues/#{issue_number}/assignees",
             %{},
             %{"assignees" => [username]},
             tracker_settings: tracker_settings
           ),
         true <- status in 200..299 do
      :ok
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :github_issue_assignment_failed}
    end
  end

  defp project_context(issue, tracker_settings, opts \\ [])

  defp project_context(%Issue{id: issue_id}, tracker_settings, opts) do
    with {:ok, {owner, repo}} <- repository(tracker_settings),
         {:ok, issue_number} <- parse_issue_number(issue_id),
         {:ok, data} <-
           graphql(@project_query, %{owner: owner, repo: repo, number: issue_number}, tracker_settings, opts),
         {:ok, project} <- find_project(data, project_name(tracker_settings)),
         {:ok, status_field} <- find_status_field(project),
         {:ok, issue} <- find_project_issue(data),
         {:ok, item} <- find_project_item(issue, project) do
      {:ok,
       %{
         project_id: project.id,
         item_id: item["id"],
         item: item,
         status_field: status_field
       }}
    end
  end

  defp update_project_item_status(context, option, tracker_settings) do
    variables = %{
      projectId: context.project_id,
      itemId: context.item_id,
      fieldId: context.status_field.id,
      optionId: option.id
    }

    with {:ok, _data} <- graphql(@update_status_mutation, variables, tracker_settings) do
      :ok
    end
  end

  defp graphql(query, variables, tracker_settings, opts \\ []) do
    case Client.request(
           "POST",
           "/graphql",
           %{},
           %{"query" => query, "variables" => variables},
           Keyword.put(opts, :tracker_settings, tracker_settings)
         ) do
      {:ok, %{status: status, body: %{"data" => data} = body}} when status in 200..299 ->
        case Map.get(body, "errors") do
          errors when is_list(errors) and errors != [] -> {:error, {:github_graphql_errors, errors}}
          _ -> {:ok, data}
        end

      {:ok, %{status: status}} when is_integer(status) ->
        {:error, {:github_graphql_status, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp find_project(%{"organization" => %{"projectsV2" => %{"nodes" => projects}}}, title)
       when is_list(projects) and is_binary(title) do
    case Enum.find(projects, &(normalize(&1["title"]) == normalize(title))) do
      nil -> {:error, {:github_project_not_found, title}}
      project -> {:ok, atomize_project(project)}
    end
  end

  defp find_project(_data, title), do: {:error, {:github_project_not_found, title}}

  defp find_status_field(%{fields: fields}) do
    case Enum.find(fields, &(normalize(&1["name"]) == "status")) do
      nil -> {:error, :github_project_status_field_not_found}
      field -> {:ok, atomize_field(field)}
    end
  end

  defp find_project_issue(%{"repository" => %{"issue" => %{"projectItems" => %{"nodes" => items}}}})
       when is_list(items), do: {:ok, items}

  defp find_project_issue(_data), do: {:error, :github_project_issue_not_found}

  defp find_project_item(items, project) do
    case Enum.find(items, &(get_in(&1, ["project", "id"]) == project.id)) do
      nil -> {:error, {:github_issue_not_in_project, project.title}}
      item -> {:ok, item}
    end
  end

  defp find_option(status_field, status) do
    case Enum.find(status_field.options, &(normalize(&1.name) == normalize(status))) do
      nil -> {:error, {:github_project_status_not_found, status}}
      option -> {:ok, option}
    end
  end

  defp atomize_project(project) do
    %{
      id: project["id"],
      title: project["title"],
      fields: get_in(project, ["fields", "nodes"]) || []
    }
  end

  defp atomize_field(field) do
    %{
      id: field["id"],
      name: field["name"],
      options: Enum.map(field["options"] || [], &%{id: &1["id"], name: &1["name"]})
    }
  end

  defp project_name(tracker_settings) do
    tracker_settings
    |> provider_settings()
    |> Map.get("project")
  end

  defp repository(tracker_settings) do
    case tracker_settings |> provider_settings() |> Map.get("repo") do
      repo when is_binary(repo) ->
        case String.split(repo, "/", parts: 2) do
          [owner, name] when owner != "" and name != "" -> {:ok, {owner, name}}
          _ -> {:error, :invalid_github_repo}
        end

      _ ->
        {:error, :missing_github_repo}
    end
  end

  defp provider_settings(%{provider: provider}) when is_map(provider), do: provider
  defp provider_settings(_tracker_settings), do: %{}

  defp parse_issue_number(issue_id) when is_binary(issue_id) do
    case Integer.parse(issue_id) do
      {number, ""} when number > 0 -> {:ok, number}
      _ -> {:error, :invalid_github_issue_number}
    end
  end

  defp parse_issue_number(_issue_id), do: {:error, :invalid_github_issue_number}

  defp normalize(value) when is_binary(value), do: value |> String.trim() |> String.downcase()
  defp normalize(_value), do: ""
end
