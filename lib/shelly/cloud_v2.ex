defmodule Shelly.CloudV2 do
  @moduledoc """
  Shelly Cloud **v2** API, authorized by a per-account auth key
  (Shelly app → Settings → User Settings → Access And Permissions →
  "Get key" — the key and the server URI are shown together).

  A *conn* is a plain map with:

    * `:server` — e.g. `"https://shelly-74-eu.shelly.cloud"`
    * `:auth_key` — the account's authorization cloud key

  Rate limit: ~1 request/second/account (paced via `Shelly.RateGate`
  when running). Status supports up to 10 devices per call.

  Note: the v2 API takes the auth key as a query parameter (Shelly's
  design) — be aware that intermediary proxies may log query strings.
  """

  @type conn :: %{server: String.t(), auth_key: String.t()}

  @doc """
  Bulk status for up to 10 device ids. Returns
  `{:ok, %{device_id => element}}` (lowercase ids); each element has
  `"status"`, `"code"` (model), `"gen"`, `"online"` — parse with
  `Shelly.Status.parse/4`:

      Shelly.Status.parse(el["status"], channel, el["online"] in [1, true],
        %{model: el["code"], gen: Shelly.Status.gen_to_int(el["gen"])})
  """
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
        {:ok, Map.new(elements, fn el -> {String.downcase(el["id"] || ""), el} end)}

      other ->
        error(other)
    end
  end

  @doc """
  Switch a relay on or off. `toggle_after` (seconds) asks Shelly's own
  cloud to revert the command later — a watchdog that survives your
  app going down.
  """
  def set_switch(conn, device_id, channel, on?, opts \\ []) when is_boolean(on?) do
    body =
      %{id: device_id, channel: channel, on: on?}
      |> maybe_put(:toggle_after, Keyword.get(opts, :toggle_after))

    case post_json(conn, "/v2/devices/api/set/switch", body) do
      {:ok, %{status: 200}} -> :ok
      other -> error(other)
    end
  end

  @doc "Control a cover: position is \"open\" | \"close\" | \"stop\" | 0..100."
  def set_cover(conn, device_id, channel, position, _opts \\ []) do
    body = %{id: device_id, channel: channel, position: position}

    case post_json(conn, "/v2/devices/api/set/cover", body) do
      {:ok, %{status: 200}} -> :ok
      other -> error(other)
    end
  end

  @doc "Control a light: opts may include :on, :brightness, :temperature, :toggle_after."
  def set_light(conn, device_id, channel, opts \\ []) do
    body =
      opts
      |> Map.new()
      |> Map.merge(%{id: device_id, channel: channel})

    case post_json(conn, "/v2/devices/api/set/light", body) do
      {:ok, %{status: 200}} -> :ok
      other -> error(other)
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp post_json(conn, path, body) do
    Shelly.RateGate.run({conn.server, conn.auth_key}, fn ->
      Req.request(
        method: :post,
        url: conn.server <> path,
        params: [auth_key: conn.auth_key],
        json: body,
        receive_timeout: 15_000,
        retry: false
      )
    end)
  end

  defp error({:ok, %{status: status, body: body}}), do: {:error, {:shelly_http, status, body}}
  defp error({:error, reason}), do: {:error, reason}
end
