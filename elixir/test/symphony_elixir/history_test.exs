defmodule SymphonyElixir.HistoryTest do
  use ExUnit.Case

  alias SymphonyElixir.History

  setup do
    root = Path.join(System.tmp_dir!(), "symphony-history-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    path = Path.join(root, "history.dets")
    name = String.to_atom("history_test_#{System.unique_integer([:positive])}")
    table = String.to_atom("history_table_#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm_rf(root) end)
    %{path: path, name: name, table: table}
  end

  test "records issue runs, turns, metrics, stop information, and PR links across restart", ctx do
    {:ok, pid} = History.start_link(path: ctx.path, name: ctx.name, table: ctx.table)
    issue = issue("GH-101")

    assert {:ok, run_id} =
             History.start_run(issue, %{workflow_revision: "revision-a", model: nil, reasoning_effort: nil}, ctx.name)

    assert :ok =
             History.record_update(
               run_id,
               %{event: :session_started, timestamp: time(1), session_id: "thread-1-turn-1", model: "gpt-6-sol", reasoning_effort: "high"},
               tokens(0, 0, 0),
               ctx.name
             )

    assert :ok =
             History.record_update(
               run_id,
               %{event: :notification, timestamp: time(2), payload: %{"method" => "item/agentMessage/delta"}},
               tokens(3, 1, 4),
               ctx.name
             )

    assert :ok =
             History.record_update(
               run_id,
               %{event: :notification, timestamp: time(3), payload: %{"method" => "item/completed", "params" => %{"item" => %{"type" => "reasoning", "text" => "secret reasoning"}}}},
               tokens(3, 2, 5),
               ctx.name
             )

    assert :ok =
             History.record_update(
               run_id,
               %{
                 event: :notification,
                 timestamp: time(4),
                 payload: %{"method" => "item/completed", "params" => %{"item" => %{"type" => "agentMessage", "text" => "Latest progress update", "debug" => "secret payload"}}}
               },
               tokens(9, 4, 13),
               ctx.name
             )

    assert :ok = History.record_update(run_id, %{event: :tool_call_completed, timestamp: time(5)}, tokens(9, 4, 13), ctx.name)
    assert :ok = History.record_pull_request(run_id, "https://github.com/kolas-code/plyn/pull/17", time(6), ctx.name)
    assert :ok = History.record_pull_request(run_id, "https://github.com/kolas-code/plyn/pull/17", time(7), ctx.name)

    assert :ok =
             History.finish_run(
               run_id,
               :human_input,
               %{tokens: tokens(9, 4, 13), ended_at: time(8), stop: %{signal: "turn_input_required", reason: "Permission needed"}},
               ctx.name
             )

    assert {:ok, detail} = History.get_issue("GH-101", ctx.name)
    assert detail.summary.total_tokens == 13
    assert detail.summary.message_count == 1
    assert detail.summary.human_handoffs == 1
    assert detail.summary.pull_requests == ["https://github.com/kolas-code/plyn/pull/17"]
    assert [run] = detail.runs
    assert run.id == run_id
    assert run.outcome == "human_input"
    assert run.model == "gpt-6-sol"
    assert run.reasoning_effort == "high"
    assert run.workflow_revision == "revision-a"
    assert run.stop.reason == "Permission needed"
    assert run.last_output == %{text: "Latest progress update", at: DateTime.to_iso8601(time(4))}
    assert Enum.any?(run.events, &(&1.type == "agent_message"))
    assert Enum.any?(run.events, &(&1.type == "pull_request_created"))
    refute inspect(detail) =~ "secret reasoning"
    refute inspect(detail) =~ "secret payload"

    GenServer.stop(pid)
    {:ok, restarted} = History.start_link(path: ctx.path, name: ctx.name, table: ctx.table)
    assert {:ok, persisted} = History.get_issue("GH-101", ctx.name)
    assert persisted.summary.total_tokens == 13
    assert persisted.summary.human_handoffs == 1
    assert hd(persisted.runs).last_output == run.last_output
    GenServer.stop(restarted)
  end

  test "interrupts an unfinished run on restart and groups a later run under the same issue", ctx do
    {:ok, pid} = History.start_link(path: ctx.path, name: ctx.name, table: ctx.table)
    assert {:ok, first_id} = History.start_run(issue("GH-102"), %{workflow_revision: "revision-a"}, ctx.name)
    GenServer.stop(pid)

    {:ok, restarted} = History.start_link(path: ctx.path, name: ctx.name, table: ctx.table)
    assert {:ok, second_id} = History.start_run(issue("GH-102"), %{workflow_revision: "revision-b"}, ctx.name)
    assert first_id != second_id
    assert {:ok, detail} = History.get_issue("GH-102", ctx.name)
    assert Enum.map(detail.runs, & &1.outcome) == ["interrupted", "running"]
    assert length(detail.runs) == 2
    GenServer.stop(restarted)
  end

  test "updates last observed status and pages issue summaries", ctx do
    {:ok, pid} = History.start_link(path: ctx.path, name: ctx.name, table: ctx.table)
    assert {:ok, _} = History.start_run(issue("GH-201"), %{}, ctx.name)
    assert {:ok, _} = History.start_run(issue("GH-202"), %{}, ctx.name)
    assert :ok = History.observe_issue(%{issue("GH-201") | project_status: "In review"}, time(9), ctx.name)

    assert %{total: 2, issues: [_one], limit: 1, offset: 0} = History.list_issues(1, 0, ctx.name)
    assert {:ok, detail} = History.get_issue("GH-201", ctx.name)
    assert detail.summary.status == "In review"
    assert detail.summary.status_observed_at == DateTime.to_iso8601(time(9))
    GenServer.stop(pid)
  end

  test "adds retry markers without exposing raw errors or messages", ctx do
    {:ok, pid} = History.start_link(path: ctx.path, name: ctx.name, table: ctx.table)
    assert {:ok, run_id} = History.start_run(issue("GH-203"), %{}, ctx.name)
    assert :ok = History.record_retry(run_id, "worker stopped", time(10), ctx.name)
    assert {:ok, detail} = History.get_issue("GH-203", ctx.name)
    assert Enum.any?(hd(detail.runs).events, &(&1.type == "retry_scheduled"))
    GenServer.stop(pid)
  end

  test "an open run includes elapsed runtime in its detail and issue total", ctx do
    {:ok, pid} = History.start_link(path: ctx.path, name: ctx.name, table: ctx.table)
    assert {:ok, run_id} = History.start_run(issue("GH-204"), %{}, ctx.name)
    Process.sleep(1100)
    assert {:ok, detail} = History.get_issue("GH-204", ctx.name)
    assert [%{id: ^run_id, duration_seconds: duration}] = detail.runs
    assert duration >= 1
    assert detail.summary.duration_seconds == duration
    GenServer.stop(pid)
  end

  test "accepts a PR on the issue host and rejects a foreign host", ctx do
    {:ok, pid} = History.start_link(path: ctx.path, name: ctx.name, table: ctx.table)
    enterprise_issue = %{issue("GH-205") | url: "https://github.example.com/team/repo/issues/205"}
    assert {:ok, run_id} = History.start_run(enterprise_issue, %{}, ctx.name)

    assert {:error, :invalid_pull_request_url} =
             History.record_pull_request(run_id, "https://evil.example.com/team/repo/pull/205", time(1), ctx.name)

    assert :ok =
             History.record_pull_request(run_id, "https://github.example.com/team/repo/pull/205", time(2), ctx.name)

    assert {:ok, detail} = History.get_issue("GH-205", ctx.name)
    assert detail.summary.pull_requests == ["https://github.example.com/team/repo/pull/205"]
    GenServer.stop(pid)
  end

  test "records a safe startup failure cause without persisting raw output", ctx do
    {:ok, pid} = History.start_link(path: ctx.path, name: ctx.name, table: ctx.table)
    assert {:ok, run_id} = History.start_run(issue("GH-206"), %{}, ctx.name)

    assert :ok =
             History.record_update(
               run_id,
               %{event: :startup_failed, timestamp: time(1), reason: {:port_exit, 126}, raw: "private command output"},
               tokens(0, 0, 0),
               ctx.name
             )

    assert :ok = History.finish_run(run_id, :failed, %{ended_at: time(2)}, ctx.name)
    assert {:ok, %{runs: [run]}} = History.get_issue("GH-206", ctx.name)
    assert run.stop.reason =~ "Codex executable"
    assert Enum.any?(run.events, &(&1.type == "startup_failed" and &1.detail =~ "Codex executable"))
    refute inspect(run) =~ "private command output"
    GenServer.stop(pid)
  end

  test "cached input is a subset of input and missing cache data stays unknown", ctx do
    {:ok, _pid} = History.start_link(path: ctx.path, name: ctx.name, table: ctx.table)
    issue = issue("GH-203")
    assert {:ok, first_id} = History.start_run(issue, %{}, ctx.name)

    assert :ok =
             History.finish_run(
               first_id,
               :completed,
               %{
                 tokens: %{input_tokens: 100, cached_input_tokens: 80, output_tokens: 5, total_tokens: 105}
               },
               ctx.name
             )

    assert {:ok, detail} = History.get_issue(issue.identifier, ctx.name)
    assert detail.summary.cached_input_tokens == 80
    assert detail.summary.uncached_input_tokens == 20
    assert hd(detail.runs).tokens.cached_input_tokens == 80
    assert hd(detail.runs).tokens.uncached_input_tokens == 20

    assert {:ok, second_id} = History.start_run(issue, %{}, ctx.name)
    assert :ok = History.finish_run(second_id, :completed, %{tokens: tokens(40, 2, 42)}, ctx.name)

    assert {:ok, mixed} = History.get_issue(issue.identifier, ctx.name)
    assert mixed.summary.input_tokens == 140
    assert mixed.summary.cached_input_tokens == nil
    assert mixed.summary.uncached_input_tokens == nil
    assert List.last(mixed.runs).tokens.cached_input_tokens == nil
    assert List.last(mixed.runs).tokens.uncached_input_tokens == nil
  end

  test "counts completed context compactions once and records timeline markers", ctx do
    {:ok, _pid} = History.start_link(path: ctx.path, name: ctx.name, table: ctx.table)
    assert {:ok, first_id} = History.start_run(issue("GH-207"), %{}, ctx.name)

    started = %{event: :notification, timestamp: time(1), payload: %{"method" => "item/started", "params" => %{"item" => %{"id" => "compact-1", "type" => "contextCompaction"}}}}

    completed = %{
      event: :notification,
      timestamp: time(2),
      payload: %{"method" => "item/completed", "params" => %{"item" => %{"id" => "compact-1", "type" => "contextCompaction", "text" => "private context"}}}
    }

    assert :ok = History.record_update(first_id, started, tokens(10, 1, 11), ctx.name)
    assert :ok = History.record_update(first_id, completed, tokens(10, 1, 11), ctx.name)
    assert :ok = History.record_update(first_id, completed, tokens(10, 1, 11), ctx.name)

    assert {:ok, first} = History.get_issue("GH-207", ctx.name)
    assert first.summary.compaction_count == 1
    assert hd(first.runs).compaction_count == 1
    assert hd(first.runs).message_count == 0
    assert Enum.count(hd(first.runs).events, &(&1.type == "context_compaction")) == 1
    refute inspect(first) =~ "private context"

    assert {:ok, second_id} = History.start_run(issue("GH-207"), %{}, ctx.name)

    assert :ok =
             History.record_update(
               second_id,
               %{completed | timestamp: time(3), payload: %{"method" => "item/completed", "params" => %{"item" => %{"id" => "compact-2", "type" => "contextCompaction"}}}},
               tokens(20, 1, 21),
               ctx.name
             )

    assert {:ok, both} = History.get_issue("GH-207", ctx.name)
    assert both.summary.compaction_count == 2
    assert Enum.map(both.runs, & &1.compaction_count) == [1, 1]
  end

  test "legacy runs without compaction tracking remain unknown", ctx do
    {:ok, pid} = History.start_link(path: ctx.path, name: ctx.name, table: ctx.table)
    assert {:ok, first_id} = History.start_run(issue("GH-208"), %{}, ctx.name)
    GenServer.stop(pid)

    {:ok, table} = :dets.open_file(ctx.table, file: String.to_charlist(ctx.path), type: :set)
    [{{:run, ^first_id}, run}] = :dets.lookup(table, {:run, first_id})
    :ok = :dets.insert(table, {{:run, first_id}, Map.delete(run, :compaction_count)})
    :ok = :dets.close(table)

    {:ok, _pid} = History.start_link(path: ctx.path, name: ctx.name, table: ctx.table)

    assert :ok =
             History.record_update(
               first_id,
               %{event: :notification, timestamp: time(2), payload: %{"method" => "item/completed", "params" => %{"item" => %{"id" => "late-compaction", "type" => "contextCompaction"}}}},
               tokens(0, 0, 0),
               ctx.name
             )

    assert {:ok, second_id} = History.start_run(issue("GH-208"), %{}, ctx.name)
    assert {:ok, detail} = History.get_issue("GH-208", ctx.name)
    assert Enum.map(detail.runs, & &1.compaction_count) == [nil, 0]
    assert detail.summary.compaction_count == nil
    assert second_id != first_id
  end

  test "latest agent output replaces the prior excerpt while other updates leave it intact", ctx do
    {:ok, _pid} = History.start_link(path: ctx.path, name: ctx.name, table: ctx.table)
    assert {:ok, run_id} = History.start_run(issue("GH-209"), %{}, ctx.name)

    first = item_notification("agentMessage", "Old output", 1)
    latest_text = "\e[31m" <> String.duplicate("a", 510) <> "\nmore"
    latest = item_notification("agentMessage", latest_text, 2)
    tool = item_notification("commandExecution", "secret tool output", 3)

    stream = %{
      event: :notification,
      timestamp: time(4),
      payload: %{"method" => "item/agentMessage/delta", "params" => %{"delta" => "partial output"}}
    }

    reasoning = item_notification("reasoning", "secret reasoning", 5)

    assert :ok = History.record_update(run_id, first, tokens(1, 1, 2), ctx.name)
    assert :ok = History.record_update(run_id, latest, tokens(2, 1, 3), ctx.name)
    assert :ok = History.record_update(run_id, tool, tokens(3, 1, 4), ctx.name)
    assert :ok = History.record_update(run_id, stream, tokens(3, 1, 4), ctx.name)
    assert :ok = History.record_update(run_id, reasoning, tokens(3, 1, 4), ctx.name)
    assert {:ok, detail} = History.get_issue("GH-209", ctx.name)
    assert [run] = detail.runs
    assert run.last_output == %{text: String.duplicate("a", 500), at: DateTime.to_iso8601(time(2))}
    assert run.message_count == 2
    refute inspect(detail) =~ "Old output"
    refute inspect(detail) =~ "secret tool output"
    refute inspect(detail) =~ "secret reasoning"
  end

  test "a pre-existing run without a retained output reports it unavailable", ctx do
    {:ok, pid} = History.start_link(path: ctx.path, name: ctx.name, table: ctx.table)
    assert {:ok, run_id} = History.start_run(issue("GH-210"), %{}, ctx.name)
    GenServer.stop(pid)

    {:ok, table} = :dets.open_file(ctx.table, file: String.to_charlist(ctx.path), type: :set)
    [{{:run, ^run_id}, run}] = :dets.lookup(table, {:run, run_id})
    :ok = :dets.insert(table, {{:run, run_id}, Map.delete(run, :last_output)})
    :ok = :dets.close(table)

    {:ok, _pid} = History.start_link(path: ctx.path, name: ctx.name, table: ctx.table)
    assert {:ok, %{runs: [legacy]}} = History.get_issue("GH-210", ctx.name)
    assert legacy.last_output == nil
  end

  defp issue(identifier) do
    %{
      id: identifier,
      identifier: identifier,
      title: "Issue #{identifier}",
      state: "open",
      project_status: "In progress",
      url: "https://github.com/kolas-code/plyn/issues/#{String.replace(identifier, "GH-", "")}"
    }
  end

  defp time(seconds), do: DateTime.add(~U[2026-10-01 10:00:00Z], seconds, :second)
  defp tokens(input, output, total), do: %{input_tokens: input, output_tokens: output, total_tokens: total}

  defp item_notification(type, text, seconds) do
    %{
      event: :notification,
      timestamp: time(seconds),
      payload: %{"method" => "item/completed", "params" => %{"item" => %{"type" => type, "text" => text}}}
    }
  end
end

defmodule SymphonyElixir.HistoryOrchestratorTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.History
  alias SymphonyElixir.Orchestrator.State

  test "orchestrator records agent metrics and completed worker outcome" do
    root = Path.join(System.tmp_dir!(), "symphony-history-orchestrator-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    name = String.to_atom("history_orchestrator_#{System.unique_integer([:positive])}")
    table = String.to_atom("history_orchestrator_table_#{System.unique_integer([:positive])}")
    {:ok, history_pid} = History.start_link(path: Path.join(root, "history.dets"), name: name, table: table)

    on_exit(fn ->
      if Process.alive?(history_pid), do: GenServer.stop(history_pid)
      File.rm_rf(root)
    end)

    issue = %Issue{id: "issue-501", identifier: "GH-501", title: "Track history", state: "In Progress", url: "https://github.com/kolas-code/plyn/issues/501", labels: [], dispatchable: true}
    assert {:ok, run_id} = History.start_run(issue, %{workflow_revision: "rev-501"}, name)
    ref = make_ref()
    now = DateTime.utc_now()

    entry = %{
      pid: self(),
      ref: ref,
      identifier: issue.identifier,
      issue: issue,
      history_run_id: run_id,
      session_id: nil,
      started_at: now,
      last_codex_event: nil,
      last_codex_message: nil,
      last_codex_timestamp: nil,
      codex_app_server_pid: nil,
      codex_input_tokens: 0,
      codex_output_tokens: 0,
      codex_total_tokens: 0,
      codex_last_reported_input_tokens: 0,
      codex_last_reported_output_tokens: 0,
      codex_last_reported_total_tokens: 0,
      turn_count: 0,
      retry_attempt: nil
    }

    state = %State{
      running: %{issue.id => entry},
      history_server: name,
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0}
    }

    update = %{event: :session_started, timestamp: now, session_id: "thread-501-turn-1", model: "gpt-6-sol", reasoning_effort: "high"}
    assert {:noreply, state} = Orchestrator.handle_info({:codex_worker_update, issue.id, update}, state)

    message = %{event: :notification, timestamp: now, payload: %{"method" => "item/completed", "params" => %{"item" => %{"type" => "agentMessage"}}}}
    assert {:noreply, state} = Orchestrator.handle_info({:codex_worker_update, issue.id, message}, state)

    usage = %{
      event: :notification,
      timestamp: now,
      payload: %{
        "method" => "thread/tokenUsage/updated",
        "params" => %{"tokenUsage" => %{"total" => %{"input_tokens" => 100, "cached_input_tokens" => 80, "output_tokens" => 5, "total_tokens" => 105}}}
      }
    }

    assert {:noreply, state} = Orchestrator.handle_info({:codex_worker_update, issue.id, usage}, state)
    assert {:noreply, state} = Orchestrator.handle_info({:codex_worker_update, issue.id, usage}, state)
    assert state.running[issue.id].codex_cached_input_tokens == 80
    assert {:noreply, _state} = Orchestrator.handle_info({:DOWN, ref, :process, self(), :normal}, state)

    assert {:ok, detail} = History.get_issue("GH-501", name)
    assert [run] = detail.runs
    assert run.outcome == "completed"
    assert run.message_count == 1
    assert run.model == "gpt-6-sol"
    assert run.turn_count == 1
    assert run.tokens.input_tokens == 100
    assert run.tokens.cached_input_tokens == 80
    assert run.tokens.uncached_input_tokens == 20
  end
end

defmodule SymphonyElixir.HistoryDispatchTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.History

  test "a dispatched worker creates a durable run with its effective Codex context" do
    root = Path.join(System.tmp_dir!(), "symphony-history-dispatch-#{System.unique_integer([:positive])}")
    workspace_root = Path.join(root, "workspaces")
    codex_binary = Path.join(root, "fake-codex")
    File.mkdir_p!(workspace_root)
    on_exit(fn -> File.rm_rf(root) end)

    File.write!(codex_binary, """
    #!/bin/sh
    count=0
    while IFS= read -r _line; do
      count=$((count + 1))
      case "$count" in
        1) printf '%s\n' '{"id":1,"result":{}}' ;;
        2) ;;
        3) printf '%s\n' '{"id":2,"result":{"thread":{"id":"thread-601"},"model":"gpt-6-sol","reasoningEffort":"high"}}' ;;
        4)
          printf '%s\n' '{"id":3,"result":{"turn":{"id":"turn-601"}}}'
          printf '%s\n' '{"method":"item/completed","params":{"item":{"type":"agentMessage","text":"private"}}}'
          printf '%s\n' '{"method":"turn/completed"}'
          exit 0
          ;;
      esac
    done
    """)

    File.chmod!(codex_binary, 0o755)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: workspace_root,
      codex_command: "#{codex_binary} app-server",
      max_turns: 1,
      poll_interval_ms: 60_000
    )

    issue = %Issue{id: "issue-601", identifier: "GH-601", title: "Real dispatch", state: "In Progress", url: "https://github.com/kolas-code/plyn/issues/601", dispatchable: true}
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])

    history_name = String.to_atom("history_dispatch_#{System.unique_integer([:positive])}")
    history_table = String.to_atom("history_dispatch_table_#{System.unique_integer([:positive])}")
    {:ok, history_pid} = History.start_link(path: Path.join(root, "history.dets"), name: history_name, table: history_table)
    {:ok, task_supervisor} = Task.Supervisor.start_link()
    orchestrator_name = String.to_atom("orchestrator_history_#{System.unique_integer([:positive])}")

    {:ok, orchestrator} =
      Orchestrator.start_link(
        name: orchestrator_name,
        task_supervisor: task_supervisor,
        history_server: history_name
      )

    on_exit(fn ->
      Enum.each([orchestrator, task_supervisor, history_pid], &safe_stop/1)
    end)

    assert_eventually(fn ->
      case History.get_issue("GH-601", history_name) do
        {:ok, %{runs: [%{outcome: "completed", message_count: 1, model: "gpt-6-sol", reasoning_effort: "high"}]}} -> true
        _ -> false
      end
    end)

    assert {:ok, %{runs: [run]}} = History.get_issue("GH-601", history_name)
    assert is_binary(run.workflow_revision)
    assert run.last_output.text == "private"
    refute inspect(run.events) =~ "private"
  end

  test "an immediately failing worker retains its startup event and reason" do
    root = Path.join(System.tmp_dir!(), "symphony-history-fast-failure-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)

    missing_codex = Path.join(root, "missing-codex")

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: Path.join(root, "workspaces"),
      codex_command: "#{missing_codex} app-server",
      poll_interval_ms: 60_000
    )

    issue = %Issue{id: "issue-602", identifier: "GH-602", title: "Fast failure", state: "In Progress", url: "https://github.com/kolas-code/plyn/issues/602", dispatchable: true}
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])

    history_name = String.to_atom("history_failure_#{System.unique_integer([:positive])}")
    history_table = String.to_atom("history_failure_table_#{System.unique_integer([:positive])}")
    {:ok, history_pid} = History.start_link(path: Path.join(root, "history.dets"), name: history_name, table: history_table)
    {:ok, task_supervisor} = Task.Supervisor.start_link()
    orchestrator_name = String.to_atom("orchestrator_failure_#{System.unique_integer([:positive])}")

    {:ok, orchestrator} =
      Orchestrator.start_link(
        name: orchestrator_name,
        task_supervisor: task_supervisor,
        history_server: history_name
      )

    on_exit(fn -> Enum.each([orchestrator, task_supervisor, history_pid], &safe_stop/1) end)

    assert_eventually(fn ->
      case History.get_issue("GH-602", history_name) do
        {:ok, %{runs: [%{outcome: "failed"} = run]}} ->
          run.stop && run.stop.reason =~ "Codex executable" && Enum.any?(run.events, &(&1.type == "startup_failed"))

        _ ->
          false
      end
    end)
  end

  defp assert_eventually(fun, attempts \\ 60)
  defp assert_eventually(_fun, 0), do: flunk("history run did not complete")

  defp assert_eventually(fun, attempts) do
    if fun.() do
      :ok
    else
      Process.sleep(25)
      assert_eventually(fun, attempts - 1)
    end
  end

  defp safe_stop(pid) do
    if Process.alive?(pid) do
      try do
        GenServer.stop(pid)
      catch
        :exit, _ -> :ok
      end
    end
  end
end

defmodule SymphonyElixir.HistoryAppServerTest do
  use SymphonyElixir.TestSupport

  test "app-server exposes effective model, reasoning level, and successful PR creation without tool payload" do
    root = Path.join(System.tmp_dir!(), "symphony-history-appserver-#{System.unique_integer([:positive])}")
    workspace_root = Path.join(root, "workspaces")
    workspace = Path.join(workspace_root, "GH-401")
    codex_binary = Path.join(root, "fake-codex")
    File.mkdir_p!(workspace)
    on_exit(fn -> File.rm_rf(root) end)

    File.write!(codex_binary, """
    #!/bin/sh
    count=0
    while IFS= read -r _line; do
      count=$((count + 1))
      case "$count" in
        1) printf '%s\n' '{"id":1,"result":{}}' ;;
        2) ;;
        3) printf '%s\n' '{"id":2,"result":{"thread":{"id":"thread-401"},"model":"gpt-6-sol","reasoningEffort":"high"}}' ;;
        4)
          printf '%s\n' '{"id":3,"result":{"turn":{"id":"turn-401"}}}'
          printf '%s\n' '{"id":7,"method":"item/tool/call","params":{"tool":"github_api","arguments":{"method":"POST","path":"/repos/kolas-code/plyn/pulls"}}}'
          ;;
        5) printf '%s\n' '{"method":"turn/completed"}'; exit 0 ;;
      esac
    done
    """)

    File.chmod!(codex_binary, 0o755)
    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root, codex_command: "#{codex_binary} app-server")

    issue = %Issue{id: "issue-401", identifier: "GH-401", title: "History event", state: "In Progress", url: "https://github.com/kolas-code/plyn/issues/401", labels: []}
    parent = self()

    assert {:ok, _} =
             AppServer.run(workspace, "Work on issue", issue,
               on_message: fn update -> send(parent, {:codex_update, update}) end,
               tool_executor: fn _tool, _arguments ->
                 %{"success" => true, "output" => Jason.encode!(%{"status" => 201, "body" => %{"html_url" => "https://github.com/kolas-code/plyn/pull/401", "body" => "private PR body"}})}
               end
             )

    assert_received {:codex_update, %{event: :session_started, model: "gpt-6-sol", reasoning_effort: "high"}}
    assert_received {:codex_update, %{event: :pull_request_created, url: "https://github.com/kolas-code/plyn/pull/401"} = pr_update}
    refute inspect(pr_update) =~ "private PR body"
  end
end
