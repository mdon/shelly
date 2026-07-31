defmodule Shelly.CloudV1 do
  @moduledoc """
  The **legacy** Shelly Cloud v1 API (`/device/status`,
  `/device/relay/control`). Shelly has deprecated it and announced
  removal — prefer `Shelly.CloudV2` (same auth key) or the OAuth
  `Shelly.Account` API. Kept as a fallback.

  Takes the same `Shelly.Client` as `Shelly.CloudV2` — one holding an
  `:auth_key`.
  """

  @doc """
  Full status for one device, as `{:ok, {device_status, online}}` —
  `device_status` goes to `Shelly.Status.parse/4`, `online` is the
  cloud's view of the device.

  The v1 response wraps the status: `data` holds `online` and
  `device_status`. Returning `data` itself (as this did before 0.2.1)
  handed callers a map `Shelly.Status.parse/4` reads as `"unknown"` with
  `on: false` — a device that looks permanently off.
  """
  @spec get_status(Shelly.Client.t(), String.t()) :: {:ok, {map(), boolean()}} | {:error, term()}
  def get_status(conn, device_id) do
    case post(conn, "/device/status", id: device_id) do
      {:ok,
       %{
         status: 200,
         body: %{"isok" => true, "data" => %{"device_status" => device_status} = data}
       }}
      when is_map(device_status) ->
        {:ok, {device_status, data["online"] == true}}

      # Falling back to the wrapper here handed callers a map that parses
      # as "unknown" and `on: false` — a device that looks permanently off.
      {:ok, %{status: 200, body: %{"isok" => true}}} ->
        {:error, :no_device_status}

      other ->
        error(other)
    end
  end

  @doc "Switch a relay channel on or off."
  @spec set_switch(Shelly.Client.t(), String.t(), non_neg_integer(), boolean()) ::
          :ok | {:error, term()}
  def set_switch(conn, device_id, channel, on?) when is_boolean(on?) do
    body = [id: device_id, channel: channel, turn: if(on?, do: "on", else: "off")]

    case post(conn, "/device/relay/control", body) do
      {:ok, %{status: 200, body: %{"isok" => true}}} -> :ok
      other -> error(other)
    end
  end

  defp post(%Shelly.Client{auth_key: nil}, _path, _form), do: {:error, :no_auth_key}

  defp post(conn, path, form) do
    Shelly.RateGate.run(Shelly.Client.rate_key(conn), fn ->
      Shelly.HTTP.request(
        [
          method: :post,
          url: conn.server <> path,
          form: Keyword.put(form, :auth_key, conn.auth_key),
          receive_timeout: 15_000,
          retry: false
        ],
        conn
      )
    end)
  end

  defp error({:ok, %{status: status, body: body}}), do: {:error, {:shelly_http, status, body}}
  defp error({:error, reason}), do: {:error, reason}
end
