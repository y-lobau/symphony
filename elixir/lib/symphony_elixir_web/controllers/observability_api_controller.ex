defmodule SymphonyElixirWeb.ObservabilityApiController do
  @moduledoc """
  JSON API for Symphony observability data.
  """

  use Phoenix.Controller, formats: [:json]

  alias Plug.Conn
  alias SymphonyElixir.History
  alias SymphonyElixirWeb.{Endpoint, Presenter}

  @spec state(Conn.t(), map()) :: Conn.t()
  def state(conn, _params) do
    json(conn, Presenter.state_payload(orchestrator(), snapshot_timeout_ms()))
  end

  @spec history(Conn.t(), map()) :: Conn.t()
  def history(conn, params) do
    limit = parse_integer(params["limit"], 20)
    offset = parse_integer(params["offset"], 0)

    case Presenter.history_list_payload(history_server(), orchestrator(), snapshot_timeout_ms(), limit, offset) do
      %{issues: _} = payload -> json(conn, payload)
      {:error, _} -> error_response(conn, 503, "history_unavailable", "History unavailable")
    end
  end

  @spec history_issue(Conn.t(), map()) :: Conn.t()
  def history_issue(conn, %{"issue_identifier" => identifier}) do
    case Presenter.history_issue_payload(identifier, history_server(), orchestrator(), snapshot_timeout_ms()) do
      {:ok, detail} -> json(conn, detail)
      {:error, :issue_not_found} -> error_response(conn, 404, "issue_not_found", "Issue not found")
      {:error, _} -> error_response(conn, 503, "history_unavailable", "History unavailable")
    end
  end

  @spec issue(Conn.t(), map()) :: Conn.t()
  def issue(conn, %{"issue_identifier" => issue_identifier}) do
    case Presenter.issue_payload(issue_identifier, orchestrator(), snapshot_timeout_ms()) do
      {:ok, payload} ->
        json(conn, payload)

      {:error, :issue_not_found} ->
        error_response(conn, 404, "issue_not_found", "Issue not found")
    end
  end

  @spec refresh(Conn.t(), map()) :: Conn.t()
  def refresh(conn, _params) do
    case Presenter.refresh_payload(orchestrator()) do
      {:ok, payload} ->
        conn
        |> put_status(202)
        |> json(payload)

      {:error, :unavailable} ->
        error_response(conn, 503, "orchestrator_unavailable", "Orchestrator is unavailable")
    end
  end

  @spec method_not_allowed(Conn.t(), map()) :: Conn.t()
  def method_not_allowed(conn, _params) do
    error_response(conn, 405, "method_not_allowed", "Method not allowed")
  end

  @spec not_found(Conn.t(), map()) :: Conn.t()
  def not_found(conn, _params) do
    error_response(conn, 404, "not_found", "Route not found")
  end

  defp error_response(conn, status, code, message) do
    conn
    |> put_status(status)
    |> json(%{error: %{code: code, message: message}})
  end

  defp orchestrator do
    Endpoint.config(:orchestrator) || SymphonyElixir.Orchestrator
  end

  defp snapshot_timeout_ms do
    Endpoint.config(:snapshot_timeout_ms) || 15_000
  end

  defp history_server, do: Endpoint.config(:history) || History

  defp parse_integer(value, fallback) when is_binary(value) do
    case Integer.parse(value) do
      {number, ""} when number >= 0 -> number
      _ -> fallback
    end
  end

  defp parse_integer(_value, fallback), do: fallback
end
