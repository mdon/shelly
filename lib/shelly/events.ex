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
        end
      )

  `device_id` is normalized to lowercase hex (events arrive hex or
  decimal depending on generation). `status` is the raw payload for
  `Shelly.Status.parse/4` — **check `Shelly.Status.has_component?/2`
  before parsing**: events may be partial deltas (only `sys` or an
  input changed) and parsing those as full status reports a false
  "off".
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

  @impl true
  def handle_disconnect(%{reason: reason}, state) do
    attempt = state.attempt + 1
    backoff = min(attempt * 2_000, 30_000)

    Logger.warning(
      "Shelly.Events: disconnected (#{state.label}, #{inspect(reason)}) — retry in #{backoff}ms"
    )

    Process.sleep(backoff)
    {:reconnect, %{state | attempt: attempt}}
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
    e -> Logger.error("Shelly.Events handler crashed: #{inspect(e)}")
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
