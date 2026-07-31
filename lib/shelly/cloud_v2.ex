defmodule Shelly.CloudV2 do
  @moduledoc """
  Shelly Cloud **v2** API, authorized by a per-account auth key
  (Shelly app → Settings → User Settings → Access And Permissions →
  "Get key" — the key and the server URI are shown together).

  Takes a `Shelly.Client` holding an `:auth_key` (Shelly app → Settings →
  User Settings → Access And Permissions → "Get key").

  Rate limit: ~1 request/second/account (paced via `Shelly.RateGate`
  when running). Status supports up to 10 devices per call.

  Note: the v2 API takes the auth key as a query parameter (Shelly's
  design) — be aware that intermediary proxies may log query strings.
  """

  @doc """
  Bulk status for up to 10 device ids. Returns
  `{:ok, %{device_id => element}}` (lowercase ids); each element has
  `"status"`, `"code"` (model), `"gen"`, `"online"` — parse with
  `Shelly.Status.parse/4`:

      Shelly.Status.parse(el["status"], channel, el["online"] in [1, true],
        %{model: el["code"], gen: Shelly.Status.gen_to_int(el["gen"])})
  """
  @spec get_statuses(Shelly.Client.t(), [String.t()]) ::
          {:ok, %{optional(String.t()) => map()}} | {:error, term()}
  def get_statuses(conn, device_ids) when is_list(device_ids) do
    if length(device_ids) > 10 do
      {:error, :too_many_ids}
    else
      do_get_statuses(conn, device_ids)
    end
  end

  defp do_get_statuses(conn, device_ids) do
    body = %{ids: device_ids, select: ["status"]}

    case post_json(conn, "/v2/devices/api/get", body) do
      {:ok, %{status: 200, body: elements}} when is_list(elements) ->
        # An element without a usable id can't be looked up by one;
        # keying it as "" silently dropped every such element but the last.
        {:ok,
         for(
           element <- elements,
           id = element_id(element),
           id != nil,
           into: %{},
           do: {id, element}
         )}

      other ->
        error(other)
    end
  end

  @doc """
  Switch a relay on or off. `toggle_after` (seconds) asks Shelly's own
  cloud to revert the command later — a watchdog that survives your
  app going down.
  """
  @spec set_switch(Shelly.Client.t(), String.t(), non_neg_integer(), boolean(), keyword()) ::
          :ok | {:error, term()}
  def set_switch(conn, device_id, channel, on?, opts \\ []) when is_boolean(on?) do
    body =
      %{id: device_id, channel: channel, on: on?}
      |> maybe_put(:toggle_after, Keyword.get(opts, :toggle_after))

    conn
    |> post_json("/v2/devices/api/set/switch", body)
    |> command_result()
  end

  @doc ~S(Control a cover: position is "open" | "close" | "stop" | 0..100.)
  @spec set_cover(
          Shelly.Client.t(),
          String.t(),
          non_neg_integer(),
          String.t() | non_neg_integer(),
          keyword()
        ) ::
          :ok | {:error, term()}
  def set_cover(conn, device_id, channel, position, _opts \\ []) do
    body = %{id: device_id, channel: channel, position: position}

    conn
    |> post_json("/v2/devices/api/set/cover", body)
    |> command_result()
  end

  @doc "Control a light: opts may include :on, :brightness, :temperature, :toggle_after."
  @spec set_light(Shelly.Client.t(), String.t(), non_neg_integer(), keyword()) ::
          :ok | {:error, term()}
  def set_light(conn, device_id, channel, opts \\ []) do
    body =
      opts
      |> Map.new()
      |> Map.merge(%{id: device_id, channel: channel})

    conn
    |> post_json("/v2/devices/api/set/light", body)
    |> command_result()
  end

  # A rejected command comes back as HTTP 200 with "isok": false, so the
  # status code alone reported a switch that never moved as switched.
  # Confirmation must be positive: a proxy's HTML error page, or any body
  # that isn't Shelly saying yes, is a failure — on a control API, that is
  # the direction to be wrong in.
  defp command_result({:ok, %{status: 200, body: %{"isok" => true}}}), do: :ok
  defp command_result({:ok, %{status: 200} = response}), do: error({:ok, response})
  defp command_result(other), do: error(other)

  defp element_id(%{"id" => id}) when is_binary(id) do
    case String.trim(id) do
      "" -> nil
      trimmed -> String.downcase(trimmed)
    end
  end

  defp element_id(_element), do: nil

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp post_json(conn, path, body) do
    if Shelly.Client.keyed?(conn),
      do: do_post_json(conn, path, body),
      else: {:error, :no_auth_key}
  end

  defp do_post_json(conn, path, body) do
    Shelly.RateGate.run(Shelly.Client.rate_key(conn), fn ->
      Shelly.HTTP.request(
        [
          method: :post,
          url: conn.server <> path,
          params: [auth_key: conn.auth_key],
          json: body,
          receive_timeout: 15_000,
          retry: false
        ],
        conn
      )
    end)
  end

  # See `Shelly.Account` — one pacing budget per account, whichever
  # transport is talking.
  defp error({:ok, %{status: status, body: body}}), do: {:error, {:shelly_http, status, body}}
  defp error({:error, reason}), do: {:error, reason}
end
