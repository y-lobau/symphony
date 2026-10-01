defmodule SymphonyElixirWeb.HistoryLive do
  @moduledoc """
  Issue-centered history with run metrics and an observed event timeline.
  """

  use Phoenix.LiveView, layout: {SymphonyElixirWeb.Layouts, :app}

  alias SymphonyElixir.History
  alias SymphonyElixirWeb.{Endpoint, ObservabilityPubSub, Presenter}

  @page_size 50

  @impl true
  def mount(params, _session, socket) do
    if connected?(socket), do: ObservabilityPubSub.subscribe()

    identifier = Map.get(params, "issue_identifier")
    page = parse_page(Map.get(params, "page"))

    {:ok,
     socket
     |> assign(:identifier, identifier)
     |> assign(:page, page)
     |> assign(:history, load_history(identifier, page))}
  end

  @impl true
  def handle_info(:observability_updated, socket) do
    {:noreply, assign(socket, :history, load_history(socket.assigns.identifier, socket.assigns.page))}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section class="dashboard-shell history-shell">
      <header class="hero-card">
        <p class="eyebrow">Symphony Observability</p>
        <h1 class="hero-title"><%= if @identifier, do: "Issue history", else: "Session history" %></h1>
        <p class="hero-copy">
          Runs and observable events from the time history recording was enabled.
        </p>
        <nav class="history-nav" aria-label="Dashboard navigation">
          <a href="/">Live dashboard</a>
          <a href="/history" aria-current={if @identifier, do: nil, else: "page"}>Issue history</a>
        </nav>
      </header>

      <%= case @history do %>
        <% {:error, reason} -> %>
          <section class="error-card history-error">
            <h2>History unavailable</h2>
            <p><%= error_message(reason) %></p>
          </section>
        <% %{issues: issues, total: total} -> %>
          <section class="section-card">
            <div class="section-header">
              <div>
                <h2 class="section-title">Issues</h2>
                <p class="section-copy"><%= total %> issue<%= if total == 1, do: "", else: "s" %> recorded</p>
              </div>
            </div>
            <%= if issues == [] do %>
              <p class="empty-state">No runs have been recorded yet.</p>
            <% else %>
              <div class="history-issue-list">
                <a :for={issue <- issues} class="history-issue-card" href={"/history/#{URI.encode(issue.identifier)}"}>
                  <div class="history-issue-heading">
                    <strong class="mono"><%= issue.identifier %></strong>
                    <span class="history-outcome"><%= issue.outcome || "unknown" %></span>
                  </div>
                  <h3><%= issue.title %></h3>
                  <p class="muted"><%= if issue.runtime_status, do: "Runtime: #{String.capitalize(issue.runtime_status)} · ", else: "" %>Tracker status: <%= issue.status || "unknown" %> · observed <%= issue.status_observed_at || "unknown" %></p>
                  <div class="history-issue-metrics numeric">
                    <span><strong><%= format_int(issue.total_tokens) %></strong> tokens</span>
                    <span><strong><%= format_duration(issue.duration_seconds) %></strong> runtime</span>
                    <span><strong><%= issue.message_count %></strong> messages</span>
                    <span><strong><%= issue.human_handoffs %></strong> human handoffs</span>
                  </div>
                </a>
              </div>
              <nav class="history-pagination" aria-label="History pages">
                <a :if={@page > 1} href={"/history?page=#{@page - 1}"}>← Newer issues</a>
                <span>Page <%= @page %> of <%= max(1, ceil(total / @history.limit)) %></span>
                <a :if={@page * @history.limit < total} href={"/history?page=#{@page + 1}"}>Older issues →</a>
              </nav>
            <% end %>
          </section>
        <% %{summary: summary, runs: runs} -> %>
          <section class="section-card history-issue-header">
            <div class="history-issue-heading">
              <a href="/history">← All issues</a>
              <span class="history-outcome"><%= summary.outcome || "unknown" %></span>
            </div>
            <h2><%= summary.identifier %> · <%= summary.title %></h2>
            <p class="muted"><%= if summary.runtime_status, do: "Runtime: #{String.capitalize(summary.runtime_status)} · ", else: "" %>Tracker status: <strong><%= summary.status || "unknown" %></strong> · observed <%= summary.status_observed_at || "unknown" %></p>
            <div class="history-links">
              <a :if={summary.url} href={summary.url} target="_blank" rel="noopener noreferrer">Open issue ↗</a>
              <a :for={url <- summary.pull_requests} href={url} target="_blank" rel="noopener noreferrer">Pull request <%= pull_number(url) %> ↗</a>
            </div>
          </section>

          <section class="metric-grid" aria-label="Issue totals">
            <article class="metric-card"><p class="metric-label">Total tokens</p><p class="metric-value numeric"><%= format_int(summary.total_tokens) %></p><p class="metric-detail numeric">In <%= format_int(summary.input_tokens) %> / Out <%= format_int(summary.output_tokens) %></p></article>
            <article class="metric-card"><p class="metric-label">Active runtime</p><p class="metric-value numeric"><%= format_duration(summary.duration_seconds) %></p><p class="metric-detail">Across <%= summary.run_count %> runs</p></article>
            <article class="metric-card"><p class="metric-label">Codex messages</p><p class="metric-value numeric"><%= summary.message_count %></p><p class="metric-detail">Completed progress and final messages</p></article>
            <article class="metric-card"><p class="metric-label">Human handoffs</p><p class="metric-value numeric"><%= summary.human_handoffs %></p><p class="metric-detail">Runs stopped for human input</p></article>
          </section>

          <section class="section-card">
            <div class="section-header"><div><h2 class="section-title">Timeline</h2><p class="section-copy">Observed runs and events, oldest first</p></div></div>
            <div class="history-timeline">
              <article :for={{run, index} <- Enum.with_index(runs, 1)} class="history-run">
                <div class="history-rail" aria-hidden="true"><span class="history-run-dot"></span><span class="history-rail-line"></span></div>
                <div class="history-run-content">
                  <div class="history-run-heading">
                    <div><span class="eyebrow">Run <%= index %></span><h3><%= outcome_label(run.outcome) %></h3></div>
                    <time class="mono" datetime={run.started_at}><%= run.started_at %></time>
                  </div>
                  <div class="history-run-metrics numeric">
                    <span><%= format_int(run.tokens.total_tokens) %> tokens</span>
                    <span><%= format_duration(run.duration_seconds) %></span>
                    <span><%= run.message_count %> messages</span>
                    <span><%= run.turn_count %> turns</span>
                  </div>
                  <p class="history-run-context muted">Workflow <%= run.workflow_revision || "unknown" %> · Model <%= run.model || "unknown" %> · Reasoning <%= run.reasoning_effort || "unknown" %></p>
                  <div class="history-events">
                    <div :for={event <- run.events} class="history-event">
                      <time class="history-event-time mono" datetime={event.at}><%= event.at %></time>
                      <span class="history-event-marker" aria-hidden="true"></span>
                      <div class="history-event-content">
                        <strong><%= event.label %></strong>
                        <p :if={event.detail}><%= event.detail %></p>
                        <a :if={event.url} href={event.url} target="_blank" rel="noopener noreferrer">Open pull request ↗</a>
                      </div>
                    </div>
                  </div>
                </div>
              </article>
            </div>
          </section>
      <% end %>
    </section>
    """
  end

  defp load_history(nil, page), do: Presenter.history_list_payload(history_server(), orchestrator(), snapshot_timeout_ms(), @page_size, (page - 1) * @page_size)

  defp load_history(identifier, _page) do
    case Presenter.history_issue_payload(identifier, history_server(), orchestrator(), snapshot_timeout_ms()) do
      {:ok, detail} -> detail
      error -> error
    end
  end

  defp parse_page(value) when is_binary(value) do
    case Integer.parse(value) do
      {page, ""} when page > 0 -> page
      _ -> 1
    end
  end

  defp parse_page(_), do: 1
  defp history_server, do: Endpoint.config(:history) || History
  defp orchestrator, do: Endpoint.config(:orchestrator) || SymphonyElixir.Orchestrator
  defp snapshot_timeout_ms, do: Endpoint.config(:snapshot_timeout_ms) || 15_000

  defp format_int(value) when is_integer(value), do: Integer.to_string(value) |> String.replace(~r/(?<=\d)(?=(\d{3})+$)/, ",")
  defp format_duration(seconds) when is_integer(seconds), do: "#{div(seconds, 60)}m #{rem(seconds, 60)}s"
  defp pull_number(url), do: url |> String.split("/") |> List.last()
  defp outcome_label("running"), do: "Running"
  defp outcome_label("completed"), do: "Completed"
  defp outcome_label("human_input"), do: "Waiting for human input"
  defp outcome_label("failed"), do: "Failed"
  defp outcome_label("cancelled"), do: "Cancelled"
  defp outcome_label("interrupted"), do: "Interrupted"
  defp outcome_label(_), do: "Unknown outcome"
  defp error_message(:issue_not_found), do: "This issue has no recorded runs."
  defp error_message(_), do: "The history store could not be read."
end
