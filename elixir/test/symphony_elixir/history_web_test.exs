defmodule SymphonyElixir.HistoryWebTest do
  use SymphonyElixir.TestSupport

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias SymphonyElixir.History

  @endpoint SymphonyElixirWeb.Endpoint

  defmodule SnapshotOrchestrator do
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, Keyword.fetch!(opts, :snapshot), name: Keyword.fetch!(opts, :name))
    def init(snapshot), do: {:ok, snapshot}
    def handle_call(:snapshot, _from, snapshot), do: {:reply, snapshot, snapshot}
  end

  test "history API and dashboard show issue totals and an event timeline without message bodies" do
    history = String.to_atom("history_web_#{System.unique_integer([:positive])}")
    table = String.to_atom("history_web_table_#{System.unique_integer([:positive])}")
    path = Path.join(System.tmp_dir!(), "symphony-history-web-#{System.unique_integer([:positive])}.dets")
    {:ok, pid} = History.start_link(path: path, name: history, table: table)
    endpoint_config = Application.get_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, [])

    Application.put_env(
      :symphony_elixir,
      SymphonyElixirWeb.Endpoint,
      endpoint_config
      |> Keyword.merge(server: false, secret_key_base: String.duplicate("s", 64))
      |> Keyword.put(:history, history)
    )

    start_supervised!({SymphonyElixirWeb.Endpoint, []})

    on_exit(fn ->
      if Process.alive?(pid), do: GenServer.stop(pid)
      File.rm(path)
      Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, endpoint_config)
    end)

    issue = %{id: "issue-301", identifier: "GH-301", title: "Improve dictation", state: "open", project_status: "In progress", url: "https://github.com/kolas-code/plyn/issues/301"}
    assert {:ok, run_id} = History.start_run(issue, %{workflow_revision: "rev-1", model: "gpt-6-sol", reasoning_effort: "high"}, history)
    completed_tokens = %{input_tokens: 100, cached_input_tokens: 80, output_tokens: 3, total_tokens: 103}

    assert :ok =
             History.record_update(
               run_id,
               %{
                 event: :notification,
                 timestamp: DateTime.utc_now(),
                 payload: %{"method" => "item/completed", "params" => %{"item" => %{"type" => "agentMessage", "text" => "private message body"}}}
               },
               completed_tokens,
               history
             )

    assert :ok =
             History.record_update(
               run_id,
               %{
                 event: :notification,
                 timestamp: DateTime.utc_now(),
                 payload: %{"method" => "item/completed", "params" => %{"item" => %{"id" => "compact-301", "type" => "contextCompaction"}}}
               },
               completed_tokens,
               history
             )

    assert :ok =
             History.finish_run(
               run_id,
               :completed,
               %{ended_at: DateTime.utc_now(), tokens: completed_tokens},
               history
             )

    list = get(build_conn(), "/api/v1/history?limit=10&offset=0") |> json_response(200)
    assert list["total"] == 1
    assert hd(list["issues"])["identifier"] == "GH-301"
    assert hd(list["issues"])["cached_input_tokens"] == 80
    assert hd(list["issues"])["compaction_count"] == 1

    detail = get(build_conn(), "/api/v1/history/GH-301") |> json_response(200)
    assert detail["summary"]["total_tokens"] == 103
    assert detail["summary"]["cached_input_tokens"] == 80
    assert detail["summary"]["uncached_input_tokens"] == 20
    assert detail["summary"]["compaction_count"] == 1
    assert hd(detail["runs"])["tokens"]["cached_input_tokens"] == 80
    assert hd(detail["runs"])["tokens"]["uncached_input_tokens"] == 20
    assert hd(detail["runs"])["compaction_count"] == 1
    assert length(detail["runs"]) == 1
    refute inspect(detail) =~ "private message body"

    {:ok, _view, html} = live(build_conn(), "/history/GH-301")
    assert html =~ "Improve dictation"
    assert html =~ "Timeline"
    assert html =~ "Cached input"
    assert html =~ "Non-cached input"
    assert html =~ "Total processed tokens"
    assert html =~ "Context compactions"
    assert html =~ "Context compacted"
    assert html =~ "Cached input is included in the total."
    assert html =~ "103"
    refute html =~ "private message body"

    assert {:ok, older_run} = History.start_run(issue, %{}, history)
    older_tokens = %{input_tokens: 40, output_tokens: 2, total_tokens: 42}
    assert :ok = History.finish_run(older_run, :completed, %{tokens: older_tokens}, history)
    mixed = get(build_conn(), "/api/v1/history/GH-301") |> json_response(200)
    assert mixed["summary"]["cached_input_tokens"] == nil
    assert mixed["summary"]["uncached_input_tokens"] == nil
    assert mixed["summary"]["compaction_count"] == 1
    {:ok, _view, mixed_html} = live(build_conn(), "/history/GH-301")
    assert mixed_html =~ "Cached input Unknown"
    assert mixed_html =~ "Non-cached input Unknown"
  end

  test "current runtime state is visible on a recorded issue without replacing its tracker status" do
    history = String.to_atom("history_live_#{System.unique_integer([:positive])}")
    table = String.to_atom("history_live_table_#{System.unique_integer([:positive])}")
    path = Path.join(System.tmp_dir!(), "symphony-history-live-#{System.unique_integer([:positive])}.dets")
    {:ok, history_pid} = History.start_link(path: path, name: history, table: table)
    issue = %{id: "issue-302", identifier: "GH-302", title: "Live issue", state: "open", project_status: "In progress", url: "https://github.com/kolas-code/plyn/issues/302"}
    assert {:ok, _} = History.start_run(issue, %{}, history)

    orchestrator = String.to_atom("history_snapshot_#{System.unique_integer([:positive])}")
    snapshot = %{running: [], retrying: [%{issue_id: issue.id, identifier: issue.identifier}], blocked: [], codex_totals: %{}, rate_limits: nil}
    {:ok, orchestrator_pid} = SnapshotOrchestrator.start_link(name: orchestrator, snapshot: snapshot)

    config = Application.get_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, [])

    Application.put_env(
      :symphony_elixir,
      SymphonyElixirWeb.Endpoint,
      config |> Keyword.merge(server: false, secret_key_base: String.duplicate("s", 64)) |> Keyword.put(:history, history) |> Keyword.put(:orchestrator, orchestrator)
    )

    start_supervised!({SymphonyElixirWeb.Endpoint, []})

    on_exit(fn ->
      if Process.alive?(orchestrator_pid), do: GenServer.stop(orchestrator_pid)
      if Process.alive?(history_pid), do: GenServer.stop(history_pid)
      File.rm(path)
      Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, config)
    end)

    detail = get(build_conn(), "/api/v1/history/GH-302") |> json_response(200)
    assert detail["summary"]["status"] == "In progress"
    assert detail["summary"]["runtime_status"] == "retrying"

    {:ok, _view, html} = live(build_conn(), "/history/GH-302")
    assert html =~ "Retrying"
  end

  test "the history list reaches older issues with page links" do
    history = String.to_atom("history_pages_#{System.unique_integer([:positive])}")
    table = String.to_atom("history_pages_table_#{System.unique_integer([:positive])}")
    path = Path.join(System.tmp_dir!(), "symphony-history-pages-#{System.unique_integer([:positive])}.dets")
    {:ok, pid} = History.start_link(path: path, name: history, table: table)
    config = Application.get_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, [])
    Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, config |> Keyword.merge(server: false, secret_key_base: String.duplicate("s", 64)) |> Keyword.put(:history, history))
    start_supervised!({SymphonyElixirWeb.Endpoint, []})

    on_exit(fn ->
      if Process.alive?(pid), do: GenServer.stop(pid)
      File.rm(path)
      Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, config)
    end)

    for number <- 1..51 do
      issue = %{id: "issue-#{number}", identifier: "GH-#{number}", title: "Issue #{number}", state: "open", url: "https://github.com/team/repo/issues/#{number}"}
      assert {:ok, _} = History.start_run(issue, %{}, history)
    end

    {:ok, _view, first_page} = live(build_conn(), "/history")
    assert first_page =~ "href=\"/history?page=2\""

    {:ok, _view, second_page} = live(build_conn(), "/history?page=2")
    assert second_page =~ "href=\"/history?page=1\""
    assert second_page =~ "GH-1"
  end
end
