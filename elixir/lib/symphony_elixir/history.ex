defmodule SymphonyElixir.History do
  @moduledoc """
  Durable, content-free issue and worker-run history for observability.
  """

  use GenServer
  require Logger

  @default_table :symphony_issue_history
  @max_reason_length 500
  @observed_errors [
    :turn_failed,
    :turn_cancelled,
    :turn_input_required,
    :approval_required,
    :turn_ended_with_error,
    :startup_failed
  ]

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @spec start_run(map(), map(), GenServer.server()) :: {:ok, String.t()} | {:error, term()}
  def start_run(issue, context, server \\ __MODULE__) do
    call(server, {:start_run, issue, context})
  end

  @spec record_update(String.t(), map(), map(), GenServer.server()) :: :ok | {:error, term()}
  def record_update(run_id, update, tokens, server \\ __MODULE__) do
    call(server, {:record_update, run_id, update, tokens})
  end

  @spec finish_run(String.t(), atom(), map(), GenServer.server()) :: :ok | {:error, term()}
  def finish_run(run_id, outcome, details, server \\ __MODULE__) do
    call(server, {:finish_run, run_id, outcome, details})
  end

  @spec record_pull_request(String.t(), String.t(), DateTime.t(), GenServer.server()) :: :ok | {:error, term()}
  def record_pull_request(run_id, url, timestamp, server \\ __MODULE__) do
    call(server, {:record_pull_request, run_id, url, timestamp})
  end

  @spec record_retry(String.t(), String.t(), DateTime.t(), GenServer.server()) :: :ok | {:error, term()}
  def record_retry(run_id, reason, timestamp, server \\ __MODULE__) do
    call(server, {:record_retry, run_id, reason, timestamp})
  end

  @spec observe_issue(map(), DateTime.t(), GenServer.server()) :: :ok | {:error, term()}
  def observe_issue(issue, timestamp \\ DateTime.utc_now(), server \\ __MODULE__) do
    call(server, {:observe_issue, issue, timestamp})
  end

  @spec list_issues(pos_integer(), non_neg_integer(), GenServer.server()) :: map() | {:error, term()}
  def list_issues(limit \\ 20, offset \\ 0, server \\ __MODULE__) do
    call(server, {:list_issues, limit, offset})
  end

  @spec get_issue(String.t(), GenServer.server()) :: {:ok, map()} | {:error, term()}
  def get_issue(identifier, server \\ __MODULE__) do
    call(server, {:get_issue, identifier})
  end

  @impl true
  def init(opts) do
    path = Keyword.get_lazy(opts, :path, &default_path/0)
    table = Keyword.get(opts, :table, @default_table)

    with :ok <- File.mkdir_p(Path.dirname(path)),
         {:ok, ^table} <- :dets.open_file(table, file: String.to_charlist(path), type: :set, repair: true) do
      recover_open_runs(table)
      {:ok, %{table: table, path: path}}
    else
      error ->
        Logger.error("Issue history storage unavailable path=#{path} reason=#{inspect(error)}")
        {:ok, %{table: nil, path: path}}
    end
  end

  @impl true
  def terminate(_reason, %{table: table}) when is_atom(table) do
    :dets.close(table)
  end

  def terminate(_reason, _state), do: :ok

  @impl true
  def handle_call(_request, _from, %{table: nil} = state) do
    {:reply, {:error, :storage_unavailable}, state}
  end

  def handle_call({:start_run, issue, context}, _from, state) do
    now = DateTime.utc_now() |> DateTime.to_iso8601()
    issue_record = upsert_issue(state.table, issue, now)
    run_id = Ecto.UUID.generate()

    run = %{
      id: run_id,
      issue_id: issue_record.id,
      started_at: now,
      ended_at: nil,
      outcome: "running",
      duration_seconds: 0,
      tokens: zero_tokens(),
      message_count: 0,
      compaction_count: 0,
      turn_count: 0,
      session_ids: [],
      workflow_revision: value(context, :workflow_revision),
      model: value(context, :model),
      reasoning_effort: value(context, :reasoning_effort),
      worker_host: value(context, :worker_host),
      attempt: value(context, :attempt),
      stop: nil,
      events: [event(now, "run_started", "Run started")]
    }

    issue_record = %{issue_record | run_ids: issue_record.run_ids ++ [run_id]}

    case persist(state.table, [{:issue, issue_record.id, issue_record}, {:run, run_id, run}]) do
      :ok -> {:reply, {:ok, run_id}, state}
      error -> {:reply, error, state}
    end
  end

  def handle_call({:record_update, run_id, update, tokens}, _from, state) do
    case lookup_run(state.table, run_id) do
      {:ok, run} ->
        updated =
          run
          |> Map.put(:tokens, normalize_tokens(tokens, run.tokens))
          |> maybe_set_model(update)
          |> apply_update(update)

        result = if updated == run, do: :ok, else: persist(state.table, [{:run, run_id, updated}])
        {:reply, result, state}

      error ->
        {:reply, error, state}
    end
  end

  def handle_call({:finish_run, run_id, outcome, details}, _from, state) do
    case lookup_run(state.table, run_id) do
      {:ok, %{outcome: "running"} = run} ->
        ended_at = iso(value(details, :ended_at) || DateTime.utc_now())
        stop = sanitize_stop(value(details, :stop), ended_at) || failure_stop(run, outcome, ended_at)
        outcome = normalize_outcome(outcome)
        label = finish_label(outcome)

        updated = %{
          run
          | ended_at: ended_at,
            outcome: outcome,
            duration_seconds: elapsed_seconds(run.started_at, ended_at),
            tokens: normalize_tokens(value(details, :tokens), run.tokens),
            stop: stop,
            events: run.events ++ [event(ended_at, outcome, label, stop && stop.reason)]
        }

        {:reply, persist(state.table, [{:run, run_id, updated}]), state}

      {:ok, _run} ->
        {:reply, :ok, state}

      error ->
        {:reply, error, state}
    end
  end

  def handle_call({:record_pull_request, run_id, url, timestamp}, _from, state) do
    with {:ok, run} <- lookup_run(state.table, run_id),
         {:ok, issue} <- lookup_issue(state.table, run.issue_id),
         true <- valid_pull_request_url?(url, issue.url) or {:error, :invalid_pull_request_url} do
      if url in issue.pull_requests do
        {:reply, :ok, state}
      else
        at = iso(timestamp)
        updated_issue = %{issue | pull_requests: issue.pull_requests ++ [url]}
        updated_run = %{run | events: run.events ++ [event(at, "pull_request_created", "Pull request created", nil, url)]}

        {:reply,
         persist(state.table, [
           {:issue, issue.id, updated_issue},
           {:run, run_id, updated_run}
         ]), state}
      end
    else
      error -> {:reply, error, state}
    end
  end

  def handle_call({:record_retry, run_id, reason, timestamp}, _from, state) do
    case lookup_run(state.table, run_id) do
      {:ok, run} ->
        detail = if is_binary(reason), do: String.slice(reason, 0, @max_reason_length), else: nil
        updated = %{run | events: run.events ++ [event(iso(timestamp), "retry_scheduled", "Retry scheduled", detail)]}
        {:reply, persist(state.table, [{:run, run_id, updated}]), state}

      error ->
        {:reply, error, state}
    end
  end

  def handle_call({:observe_issue, issue, timestamp}, _from, state) do
    id = value(issue, :id)

    case lookup_issue(state.table, id) do
      {:ok, previous} ->
        at = iso(timestamp)
        updated = issue_record(issue, previous, at)
        records = observation_records(state.table, previous, updated, at)

        {:reply, persist(state.table, records), state}

      error ->
        {:reply, error, state}
    end
  end

  def handle_call({:list_issues, limit, offset}, _from, state) do
    limit = limit |> max(1) |> min(100)
    offset = max(offset, 0)

    issues =
      :dets.foldl(
        fn
          {{:issue, _id}, issue}, acc -> [issue | acc]
          _, acc -> acc
        end,
        [],
        state.table
      )
      |> Enum.sort_by(& &1.latest_at, :desc)

    page = issues |> Enum.slice(offset, limit) |> Enum.map(&summary(state.table, &1))
    {:reply, %{total: length(issues), issues: page, limit: limit, offset: offset}, state}
  end

  def handle_call({:get_issue, identifier}, _from, state) do
    issue =
      :dets.foldl(
        fn
          {{:issue, _id}, %{identifier: ^identifier} = found}, _acc -> found
          _, acc -> acc
        end,
        nil,
        state.table
      )

    case issue do
      nil ->
        {:reply, {:error, :issue_not_found}, state}

      issue ->
        runs =
          issue.run_ids
          |> Enum.map(&lookup_run(state.table, &1))
          |> Enum.flat_map(&unwrap_run/1)
          |> Enum.map(&with_current_duration/1)
          |> Enum.map(&with_token_breakdown/1)
          |> Enum.map(&with_compaction_count/1)

        {:reply, {:ok, %{summary: summary(state.table, issue), runs: runs}}, state}
    end
  end

  defp call(server, request) do
    GenServer.call(server, request, 15_000)
  catch
    :exit, reason -> {:error, {:history_unavailable, reason}}
  end

  defp observation_records(table, previous, updated, at) do
    issue_record = {:issue, updated.id, updated}

    if previous.status != updated.status and previous.run_ids != [] do
      latest_run_id = List.last(previous.run_ids)

      case lookup_run(table, latest_run_id) do
        {:ok, run} ->
          status_event = event(at, "status_changed", "Tracker status: #{updated.status || "unknown"}")
          [issue_record, {:run, latest_run_id, %{run | events: run.events ++ [status_event]}}]

        _ ->
          [issue_record]
      end
    else
      [issue_record]
    end
  end

  defp default_path do
    Application.get_env(:symphony_elixir, :history_path) ||
      Path.join(Path.dirname(SymphonyElixir.Workflow.workflow_file_path()), "var/history/history.dets")
  end

  defp recover_open_runs(table) do
    now = DateTime.utc_now() |> DateTime.to_iso8601()

    :dets.foldl(
      fn
        {{:run, id}, %{outcome: "running"} = run}, acc ->
          interrupted = %{
            run
            | outcome: "interrupted",
              ended_at: now,
              duration_seconds: elapsed_seconds(run.started_at, now),
              events: run.events ++ [event(now, "interrupted", "Service restarted during run")]
          }

          [{:run, id, interrupted} | acc]

        _, acc ->
          acc
      end,
      [],
      table
    )
    |> case do
      [] -> :ok
      records -> persist(table, records)
    end
  end

  defp upsert_issue(table, issue, at) do
    case lookup_issue(table, value(issue, :id)) do
      {:ok, previous} -> issue_record(issue, previous, at)
      _ -> issue_record(issue, nil, at)
    end
  end

  defp issue_record(issue, previous, at) do
    status = value(issue, :project_status) || value(issue, :state)

    %{
      id: value(issue, :id),
      identifier: value(issue, :identifier),
      title: value(issue, :title),
      url: value(issue, :url),
      status: status,
      status_observed_at: at,
      latest_at: at,
      pull_requests: if(previous, do: previous.pull_requests, else: []),
      run_ids: if(previous, do: previous.run_ids, else: [])
    }
  end

  defp lookup_issue(table, id) do
    case :dets.lookup(table, {:issue, id}) do
      [{{:issue, ^id}, issue}] -> {:ok, issue}
      _ -> {:error, :issue_not_found}
    end
  end

  defp lookup_run(table, id) do
    case :dets.lookup(table, {:run, id}) do
      [{{:run, ^id}, run}] -> {:ok, run}
      _ -> {:error, :run_not_found}
    end
  end

  defp unwrap_run({:ok, run}), do: [run]
  defp unwrap_run(_), do: []

  defp persist(table, records) do
    entries = Enum.map(records, fn {kind, id, record} -> {{kind, id}, record} end)

    case :dets.insert(table, entries) do
      :ok ->
        case :dets.sync(table) do
          :ok -> :ok
          error -> log_storage_error(error)
        end

      error ->
        log_storage_error(error)
    end
  end

  defp log_storage_error(error) do
    Logger.error("Issue history write failed: #{inspect(error)}")
    {:error, {:storage_failed, error}}
  end

  defp summary(table, issue) do
    runs = issue.run_ids |> Enum.map(&lookup_run(table, &1)) |> Enum.flat_map(&unwrap_run/1) |> Enum.map(&with_current_duration/1)
    latest = List.last(runs)
    input_tokens = Enum.sum(Enum.map(runs, & &1.tokens.input_tokens))
    cached_input_tokens = aggregate_cached_input(runs)

    %{
      id: issue.id,
      identifier: issue.identifier,
      title: issue.title,
      url: issue.url,
      status: issue.status,
      status_observed_at: issue.status_observed_at,
      latest_at: issue.latest_at,
      pull_requests: issue.pull_requests,
      run_count: length(runs),
      input_tokens: input_tokens,
      cached_input_tokens: cached_input_tokens,
      uncached_input_tokens: uncached_input(input_tokens, cached_input_tokens),
      output_tokens: Enum.sum(Enum.map(runs, & &1.tokens.output_tokens)),
      total_tokens: Enum.sum(Enum.map(runs, & &1.tokens.total_tokens)),
      duration_seconds: Enum.sum(Enum.map(runs, & &1.duration_seconds)),
      message_count: Enum.sum(Enum.map(runs, & &1.message_count)),
      compaction_count: aggregate_compactions(runs),
      human_handoffs: Enum.count(runs, &(&1.outcome == "human_input")),
      outcome: latest && latest.outcome
    }
  end

  defp apply_update(run, update) do
    at = iso(value(update, :timestamp) || DateTime.utc_now())
    session_id = value(update, :session_id)

    case value(update, :event) do
      :session_started ->
        start_turn(run, session_id, at)

      :turn_completed ->
        %{run | events: run.events ++ [event(at, "turn_completed", "Codex turn completed")]}

      event_name when event_name in @observed_errors ->
        %{run | events: run.events ++ [event(at, Atom.to_string(event_name), event_label(event_name), failure_detail(update))]}

      :notification ->
        run |> record_completed_message(update, at) |> record_completed_compaction(update, at)

      _ ->
        run
    end
  end

  defp start_turn(run, session_id, at) when is_binary(session_id) do
    if session_id in run.session_ids do
      run
    else
      %{run | turn_count: run.turn_count + 1, session_ids: run.session_ids ++ [session_id], events: run.events ++ [event(at, "turn_started", "Codex turn started")]}
    end
  end

  defp start_turn(run, _session_id, _at), do: run

  defp record_completed_message(run, update, at) do
    if completed_agent_message?(update) do
      %{run | message_count: run.message_count + 1, events: run.events ++ [event(at, "agent_message", "Codex message completed")]}
    else
      run
    end
  end

  defp completed_agent_message?(update) do
    payload = value(update, :payload) || value(value(update, :message), :payload)
    method = value(payload, :method)
    item = value(value(payload, :params), :item)
    method == "item/completed" and value(item, :type) in ["agentMessage", "agent_message"]
  end

  defp record_completed_compaction(run, update, at) do
    payload = value(update, :payload) || value(value(update, :message), :payload)
    item = value(value(payload, :params), :item)
    id = value(item, :id)

    if value(payload, :method) == "item/completed" and value(item, :type) == "contextCompaction" and
         is_binary(id) and not Enum.any?(run.events, &(Map.get(&1, :source_id) == id and &1.type == "context_compaction")) do
      marker = event(at, "context_compaction", "Context compacted") |> Map.put(:source_id, id)
      count = Map.get(run, :compaction_count)
      Map.merge(run, %{compaction_count: if(is_integer(count), do: count + 1, else: nil), events: run.events ++ [marker]})
    else
      run
    end
  end

  defp maybe_set_model(run, update) do
    %{
      run
      | model: value(update, :model) || run.model,
        reasoning_effort: value(update, :reasoning_effort) || run.reasoning_effort
    }
  end

  defp normalize_tokens(tokens, fallback) when is_map(tokens) do
    input_tokens = nonnegative(value(tokens, :input_tokens), fallback.input_tokens)

    %{
      input_tokens: input_tokens,
      cached_input_tokens: cached_input(value(tokens, :cached_input_tokens), Map.get(fallback, :cached_input_tokens), input_tokens),
      output_tokens: nonnegative(value(tokens, :output_tokens), fallback.output_tokens),
      total_tokens: nonnegative(value(tokens, :total_tokens), fallback.total_tokens)
    }
  end

  defp normalize_tokens(_tokens, fallback), do: fallback
  defp nonnegative(value, _fallback) when is_integer(value) and value >= 0, do: value
  defp nonnegative(_value, fallback), do: fallback
  defp zero_tokens, do: %{input_tokens: 0, cached_input_tokens: nil, output_tokens: 0, total_tokens: 0}

  defp cached_input(value, _fallback, input) when is_integer(value) and value >= 0 and value <= input, do: value
  defp cached_input(_value, fallback, input) when is_integer(fallback) and fallback <= input, do: fallback
  defp cached_input(_value, _fallback, _input), do: nil

  defp uncached_input(input, cached) when is_integer(cached), do: input - cached
  defp uncached_input(_input, _cached), do: nil

  defp with_token_breakdown(run) do
    cached = Map.get(run.tokens, :cached_input_tokens)
    %{run | tokens: run.tokens |> Map.put(:cached_input_tokens, cached) |> Map.put(:uncached_input_tokens, uncached_input(run.tokens.input_tokens, cached))}
  end

  defp with_compaction_count(run), do: Map.put_new(run, :compaction_count, nil)

  defp aggregate_compactions(runs) do
    if Enum.all?(runs, &is_integer(Map.get(&1, :compaction_count))) do
      Enum.sum(Enum.map(runs, & &1.compaction_count))
    end
  end

  defp aggregate_cached_input(runs) do
    if Enum.all?(runs, fn run -> run.tokens.input_tokens == 0 or is_integer(Map.get(run.tokens, :cached_input_tokens)) end) do
      Enum.sum(Enum.map(runs, &(Map.get(&1.tokens, :cached_input_tokens) || 0)))
    end
  end

  defp sanitize_stop(nil, _at), do: nil

  defp sanitize_stop(stop, at) when is_map(stop) do
    reason = value(stop, :reason)

    %{
      at: at,
      signal: value(stop, :signal) |> to_string(),
      reason: if(is_binary(reason), do: String.slice(reason, 0, @max_reason_length), else: nil)
    }
  end

  defp failure_stop(run, :failed, at) do
    run.events
    |> Enum.reverse()
    |> Enum.find(&(is_binary(&1.detail) and &1.type in ["startup_failed", "turn_failed", "turn_ended_with_error"]))
    |> case do
      nil -> nil
      failure -> %{at: at, signal: failure.type, reason: failure.detail}
    end
  end

  defp failure_stop(_run, _outcome, _at), do: nil

  defp failure_detail(update) do
    case value(update, :reason) do
      {:port_exit, 126} -> "Codex executable could not start (exit 126); check codex.command."
      {:port_exit, 127} -> "Codex executable was not found (exit 127); check codex.command."
      {:port_exit, code} when is_integer(code) -> "Codex process exited with code #{code}."
      :timeout -> "Codex startup timed out."
      _ -> nil
    end
  end

  defp normalize_outcome(outcome) when outcome in [:completed, :human_input, :failed, :cancelled, :interrupted], do: Atom.to_string(outcome)
  defp normalize_outcome(_), do: "failed"

  defp finish_label("completed"), do: "Run completed"
  defp finish_label("human_input"), do: "Waiting for human input"
  defp finish_label("cancelled"), do: "Run cancelled"
  defp finish_label("interrupted"), do: "Run interrupted"
  defp finish_label(_), do: "Run failed"

  defp event_label(:turn_failed), do: "Codex turn failed"
  defp event_label(:turn_cancelled), do: "Codex turn cancelled"
  defp event_label(:turn_input_required), do: "Codex requested human input"
  defp event_label(:approval_required), do: "Codex requested approval"
  defp event_label(:turn_ended_with_error), do: "Codex turn ended with error"
  defp event_label(:startup_failed), do: "Codex startup failed"

  defp event(at, type, label, detail \\ nil, url \\ nil), do: %{at: at, type: type, label: label, detail: detail, url: url}

  defp elapsed_seconds(start_at, end_at) do
    with {:ok, start_time, _} <- DateTime.from_iso8601(start_at),
         {:ok, end_time, _} <- DateTime.from_iso8601(end_at) do
      max(DateTime.diff(end_time, start_time, :second), 0)
    else
      _ -> 0
    end
  end

  defp with_current_duration(%{outcome: "running"} = run) do
    %{run | duration_seconds: elapsed_seconds(run.started_at, DateTime.utc_now() |> DateTime.to_iso8601())}
  end

  defp with_current_duration(run), do: run

  defp valid_pull_request_url?(url, issue_url) when is_binary(url) and is_binary(issue_url) do
    case {URI.parse(url), URI.parse(issue_url)} do
      {%URI{scheme: "https", host: host, path: path}, %URI{scheme: "https", host: host, path: issue_path}}
      when is_binary(host) and is_binary(path) and is_binary(issue_path) ->
        case Regex.run(~r{^/([^/]+)/([^/]+)/issues/\d+$}, issue_path) do
          [_, owner, repo] -> String.match?(path, ~r{^/#{Regex.escape(owner)}/#{Regex.escape(repo)}/pull/\d+$})
          _ -> false
        end

      _ ->
        false
    end
  end

  defp valid_pull_request_url?(_, _), do: false
  defp iso(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)
  defp iso(value) when is_binary(value), do: value
  defp value(map, key) when is_map(map), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))
  defp value(_map, _key), do: nil
end
