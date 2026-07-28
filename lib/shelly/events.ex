defmodule Shelly.Events do
  @moduledoc """
  Real-time events socket for an OAuth-connected account
  (`wss://<server>:6113/shelly/wss/hk_sock?t=<token>`).

  Start one per account with a handler; the handler receives normalized
  events in its own right — persistence, PubSub, whatever — while this
  process owns the connection and reconnects with backoff:

      Shelly.Events.start_link(
        server: account.user_api_url,
        token: account.access_token,
        handler: fn
          {:status, device_id, status} -> MyApp.handle_status(device_id, status)
          {:online, device_id, online?} -> MyApp.handle_online(device_id, online?)
          {:other, _message} -> :ok
        end
      )

  `device_id` is normalized to lowercase hex (integer ids arrive on
  some generations and are hex-converted; string ids pass through).
  `status` is the raw payload for `Shelly.Status.parse/4` — **guard
  before parsing**: events may be partial deltas (only `sys`, an input
  or battery changed), and parsing those as a full status reports a
  false "off". Check `Shelly.Status.has_component?/2`, and when you
  know the device's component, prefer comparing
  `Shelly.Status.component_of/2` against it.

  Reconnection uses in-process exponential backoff with jitter (a
  WebSockex constraint — the process is unresponsive while it waits)
  and gives up after #{10} consecutive failures, letting your
  supervisor's restart policy take over. Note the access token rides
  the websocket URL (Shelly's protocol); this module never logs the
  URL and redacts disconnect reasons.
  """

  use WebSockex

  require Logger

  def start_link(opts) do
    server = Keyword.fetch!(opts, :server)
    token = Keyword.fetch!(opts, :token)
    handler = Keyword.fetch!(opts, :handler)

    host = URI.parse(server).host || server
    url = "wss://#{host}:6113/shelly/wss/hk_sock?t=#{token}"

    state = %{handler: handler, label: host, attempt: 0}

    WebSockex.start_link(
      url,
      __MODULE__,
      state,
      Keyword.take(opts, [:name]) ++ [handle_initial_conn_failure: true]
    )
  end

  @impl true
  def handle_connect(_conn, state) do
    Logger.info("Shelly.Events: connected (#{state.label})")
    {:ok, %{state | attempt: 0}}
  end

  @impl true
  def handle_frame({:text, text}, state) do
    case Jason.decode(text) do
      {:ok, message} -> dispatch(message, state)
      _ -> :ok
    end

    {:ok, state}
  end

  def handle_frame(_frame, state), do: {:ok, state}

  @max_attempts 10

  @impl true
  def handle_disconnect(%{reason: reason}, state) do
    attempt = state.attempt + 1

    if attempt > @max_attempts do
      Logger.error(
        "Shelly.Events: giving up after #{@max_attempts} failed reconnects (#{state.label}, #{redact_reason(reason)})"
      )

      {:ok, state}
    else
      backoff = jittered_backoff(attempt)

      Logger.warning(
        "Shelly.Events: disconnected (#{state.label}, #{redact_reason(reason)}) — retry #{attempt}/#{@max_attempts} in #{backoff}ms"
      )

      # WebSockex offers no timer-based reconnect; this blocks only this
      # socket process. Capped, exponential, jittered.
      Process.sleep(backoff)
      {:reconnect, %{state | attempt: attempt}}
    end
  end

  # Never log raw disconnect reasons — WebSockex errors can embed the
  # connection URL, which carries the access token.
  defp redact_reason(%{__struct__: mod, code: code}), do: "#{inspect(mod)} code=#{inspect(code)}"
  defp redact_reason(%{__struct__: mod}), do: inspect(mod)
  defp redact_reason(reason) when is_atom(reason), do: inspect(reason)
  defp redact_reason(_), do: "connection_error"

  defp jittered_backoff(attempt) do
    base = min(1_000 * Integer.pow(2, attempt - 1), 30_000)
    base + :rand.uniform(div(base, 4) + 1)
  end

  ## Event routing

  defp dispatch(%{"event" => "Shelly:StatusOnChange"} = message, state) do
    with id when is_binary(id) <- device_id(message),
         %{} = status <- message["status"] do
      safe_call(state.handler, {:status, id, status})
    else
      _ -> :ok
    end
  end

  defp dispatch(%{"event" => "Shelly:Online"} = message, state) do
    with id when is_binary(id) <- device_id(message) do
      online =
        message["online"] in [1, true] or get_in(message, ["device", "online"]) in [1, true]

      safe_call(state.handler, {:online, id, online})
    else
      _ -> :ok
    end
  end

  defp dispatch(message, state), do: safe_call(state.handler, {:other, message})

  defp safe_call(handler, event) do
    handler.(event)
  rescue
    e ->
      Logger.error(
        "Shelly.Events handler crashed: " <> Exception.format(:error, e, __STACKTRACE__)
      )
  end

  @doc "Normalize a device id to lowercase hex (events arrive hex or decimal)."
  def normalize_device_id(id) when is_binary(id), do: String.downcase(id)

  def normalize_device_id(id) when is_integer(id) do
    id |> Integer.to_string(16) |> String.downcase() |> String.pad_leading(12, "0")
  end

  def normalize_device_id(_), do: nil

  defp device_id(message) do
    normalize_device_id(
      get_in(message, ["device", "id"]) || message["deviceId"] || message["device_id"]
    )
  end
end
