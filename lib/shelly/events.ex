defmodule Shelly.Events do
  @moduledoc """
  Real-time events socket for an OAuth-connected account
  (`wss://<server>:6113/shelly/wss/hk_sock?t=<token>`).

  Start one per account with a handler; the handler receives normalized
  events in its own right — persistence, PubSub, whatever — while this
  process owns the connection and reconnects with backoff:

      Shelly.Events.start_link(client,
        handler: fn
          {:status, device_id, status} -> MyApp.handle_status(device_id, status)
          {:online, device_id, online?} -> MyApp.handle_online(device_id, online?)
          {:other, _message} -> :ok
        end
      )

  `device_id` is normalized to lowercase hex — ids arrive as hex, as
  integers, or as decimal strings, and all three resolve to one form
  (see `normalize_device_id/1`).
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

  @doc """
  Open the realtime socket for a client.

  Requires an OAuth token — the websocket has no auth-key equivalent.

  Options:

    * `:handler` — required, arity-1, receives normalized events
    * `:name` — optional process name
    * `:known_ids` — optional; the device ids you already know. Pass them
      and ambiguous ids resolve by lookup (see `normalize_device_id/2`),
      which is the difference between a Gen1 device's events landing under
      the right key or being silently unmatchable.
  """
  @spec start_link(Shelly.Client.t(), keyword()) ::
          {:ok, pid()} | {:error, :no_token | :invalid_server_url | term()}
  def start_link(client, opts \\ [])

  def start_link(%Shelly.Client{} = client, opts) do
    if Shelly.Client.oauth?(client), do: open_socket(client, opts), else: {:error, :no_token}
  end

  defp open_socket(%Shelly.Client{token: token} = client, opts) do
    handler = Keyword.fetch!(opts, :handler)

    host = URI.parse(client.server).host || client.server
    url = "wss://#{host}:6113/shelly/wss/hk_sock?t=#{token}"

    state = %{
      handler: handler,
      label: host,
      attempt: 0,
      connected_at: nil,
      known_ids: known_ids(opts)
    }

    url
    |> WebSockex.start_link(
      __MODULE__,
      state,
      Keyword.take(opts, [:name]) ++ [handle_initial_conn_failure: true]
    )
    |> sanitize_start_error()
  end

  # The connection URL carries the access token (Shelly's protocol), and
  # WebSockex.URLError embeds the URL it was given. Returning that
  # verbatim puts a live token into whatever the caller logs.
  defp sanitize_start_error({:error, %WebSockex.URLError{}}), do: {:error, :invalid_server_url}
  defp sanitize_start_error(result), do: result

  @impl true
  def handle_connect(_conn, state) do
    Logger.info("Shelly.Events: connected (#{state.label})")
    # Don't zero the attempt counter here: an expired token still
    # completes the websocket handshake and is dropped moments later,
    # so resetting on connect turns "give up after 10 tries" into an
    # endless connect/disconnect loop. The counter is cleared in
    # handle_disconnect/2, but only for sessions that actually held.
    {:ok, %{state | connected_at: System.monotonic_time(:millisecond)}}
  end

  @impl true
  def handle_frame({:text, text}, state) do
    case Jason.decode(text) do
      {:ok, message} ->
        dispatch(message, state)

      _ ->
        Logger.debug(fn ->
          "Shelly.Events: dropped an undecodable text frame (#{state.label}, #{byte_size(text)} bytes)"
        end)
    end

    {:ok, state}
  end

  def handle_frame(frame, state) do
    Logger.debug(fn ->
      "Shelly.Events: ignored a #{elem(frame, 0)} frame (#{state.label})"
    end)

    {:ok, state}
  end

  @max_attempts 10

  # A session that lasted this long counts as genuinely established, so
  # the next drop starts counting from scratch. Shorter than this and the
  # connection was refused in all but name (expired token, revoked
  # account) — those keep incrementing until the cap stops them.
  @stable_session_ms 60_000

  @impl true
  def handle_disconnect(%{reason: reason}, state) do
    attempt = if stable_session?(state), do: 1, else: state.attempt + 1

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
      {:reconnect, %{state | attempt: attempt, connected_at: nil}}
    end
  end

  defp stable_session?(%{connected_at: nil}), do: false

  defp stable_session?(%{connected_at: connected_at}) do
    System.monotonic_time(:millisecond) - connected_at >= @stable_session_ms
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
    with id when is_binary(id) <- device_id(message, state),
         %{} = status <- message["status"] do
      safe_call(state.handler, {:status, id, status})
    else
      _ -> dropped("StatusOnChange", message, state)
    end
  end

  defp dispatch(%{"event" => "Shelly:Online"} = message, state) do
    with id when is_binary(id) <- device_id(message, state),
         online when is_boolean(online) <- online_flag(message) do
      safe_call(state.handler, {:online, id, online})
    else
      _ -> dropped("Online", message, state)
    end
  end

  defp dispatch(message, state), do: safe_call(state.handler, {:other, message})

  # An Online event with no readable flag used to be reported as
  # offline — a missing field is not evidence that a device is down.
  defp online_flag(message) do
    # `get_in(message, ["device", ...])` raises when "device" is a scalar,
    # and this runs outside safe_call's rescue — it would take the socket
    # down. raw_device_id/1 was hardened for the same payload; this call
    # site was missed.
    nested = nested_online(message["device"])

    cond do
      message["online"] in [1, true] -> true
      message["online"] in [0, false] -> false
      nested in [1, true] -> true
      nested in [0, false] -> false
      true -> nil
    end
  end

  defp nested_online(%{"online" => online}), do: online
  defp nested_online(_device), do: nil

  # Anything unhandled leaves a trace. Silence here is what let a
  # mis-shaped device id disable realtime without a single log line.
  defp dropped(kind, message, state) do
    Logger.debug(fn ->
      "Shelly.Events: dropped #{kind} (#{state.label}) — " <>
        "id=#{inspect(raw_device_id(message))} keys=#{inspect(Map.keys(message))}"
    end)

    :ok
  end

  # Resolve against the caller's device list when they gave us one: that
  # is the only way to settle an id whose decimal rendering is itself a
  # valid hex id (~5% of Gen1 devices).
  defp device_id(message, %{known_ids: known}) when known != nil,
    do: normalize_device_id(raw_device_id(message), known)

  defp device_id(message, _state), do: normalize_device_id(raw_device_id(message))

  defp known_ids(opts) do
    case Keyword.get(opts, :known_ids) do
      nil -> nil
      ids -> MapSet.new(ids, &to_string/1)
    end
  end

  # A scalar "device" value used to raise inside get_in/2 — outside
  # safe_call's rescue, so it killed the socket process.
  defp raw_device_id(message) do
    from_device =
      case message["device"] do
        %{"id" => id} -> id
        _ -> nil
      end

    from_device || message["deviceId"] || message["device_id"]
  end

  defp safe_call(handler, event) do
    handler.(event)
  rescue
    e ->
      Logger.error(
        "Shelly.Events handler crashed: " <> Exception.format(:error, e, __STACKTRACE__)
      )
  end

  @doc """
  Normalize a device id to the lowercase hex form devices are addressed
  by, whatever shape the event carried.

  Shelly sends the same id three ways: as hex (`"485519999340"`), as an
  integer, and — on the live websocket — as the *decimal* rendering of
  that number in a string (`"79530338915136"`). The decimal string is
  the trap: it looks like an id, so a consumer matching it against its
  device list finds nothing, every event is dropped, and realtime
  silently degrades to whatever polling exists.

  Shelly's spec pins the hex form to **6 characters (Gen1) or 12**,
  zero-padded. That is what disambiguates: an all-digit string of any
  other length cannot be a valid hex id, so it is decimal. `"12133370"`
  (8 digits) is decimal for the Gen1 id `"b923fa"`, while the 12-digit
  `"485519999340"` is itself hex and passes through.

  Converted ids are padded back to the same 6-or-12 width, so an event
  carrying the integer and one carrying the string resolve to one key.
  Ids that aren't hex at all (the `X`-prefixed BLE/Z-Wave form) are
  downcased and returned as-is.

  ## The one case length cannot settle

  A decimal rendering that happens to be exactly 6 or 12 digits is
  indistinguishable from a hex id, because such a string is both. This
  reaches roughly 5% of Gen1 ids — those whose hex form has a leading
  zero, e.g. `0x062fa0`, which renders as `"405408"`. Gen2+ ids are
  unaffected: no Shelly OUI produces a 12-digit decimal.

  When you have the device list — and a consumer matching events against
  its own devices always does — pass it and the ambiguity resolves by
  lookup:

      Shelly.Events.normalize_device_id("405408", known_ids)
      #=> "062fa0"   (when "062fa0" is in known_ids and "405408" is not)
  """
  @hex_id_widths [6, 12]

  @spec normalize_device_id(String.t() | integer() | term()) :: String.t() | nil
  def normalize_device_id(id) when is_binary(id) do
    id = String.trim(id)

    cond do
      id == "" ->
        nil

      decimal_form?(id) ->
        id |> String.to_integer() |> normalize_device_id()

      true ->
        String.downcase(id)
    end
  end

  def normalize_device_id(id) when is_integer(id) and id >= 0 do
    hex = id |> Integer.to_string(16) |> String.downcase()

    case Enum.find(@hex_id_widths, &(String.length(hex) <= &1)) do
      nil -> hex
      width -> String.pad_leading(hex, width, "0")
    end
  end

  def normalize_device_id(_), do: nil

  @doc """
  Normalize against a set of ids you already know.

  Resolves the one case `normalize_device_id/1` cannot: when a digits-only
  string is both a valid hex id and a valid decimal rendering, the
  interpretation present in `known_ids` wins. Falls back to
  `normalize_device_id/1` when neither or both are known.
  """
  @spec normalize_device_id(String.t() | integer() | term(), Enumerable.t()) :: String.t() | nil
  def normalize_device_id(id, known_ids) do
    # Accepts anything enumerable, including the map `Shelly.Account`
    # returns — its keys are the ids.
    known =
      known_ids
      |> normalize_known()
      |> MapSet.new()

    case candidates(id) do
      [primary] ->
        primary

      [primary, alternate] ->
        cond do
          MapSet.member?(known, primary) -> primary
          MapSet.member?(known, alternate) -> alternate
          true -> primary
        end
    end
  end

  defp normalize_known(%{} = ids) when not is_struct(ids), do: normalize_known(Map.keys(ids))

  defp normalize_known(ids) do
    ids
    |> Enum.map(fn
      id when is_binary(id) -> String.downcase(id)
      id -> id |> to_string() |> String.downcase()
    end)
  end

  # Both readings of an ambiguous id, likeliest first; one reading
  # otherwise.
  defp candidates(id) when is_binary(id) do
    trimmed = String.trim(id)
    primary = normalize_device_id(trimmed)

    if String.match?(trimmed, ~r/^\d+$/) and String.length(trimmed) in @hex_id_widths do
      [primary, trimmed |> String.to_integer() |> normalize_device_id()]
    else
      [primary]
    end
  end

  defp candidates(id), do: [normalize_device_id(id)]

  # All digits, but not a length a hex id is allowed to have.
  defp decimal_form?(id) do
    String.match?(id, ~r/^\d+$/) and String.length(id) not in @hex_id_widths
  end
end
