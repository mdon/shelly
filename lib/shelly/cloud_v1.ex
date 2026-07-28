defmodule Shelly.CloudV1 do
  @moduledoc """
  The **legacy** Shelly Cloud v1 API (`/device/status`,
  `/device/relay/control`). Shelly has deprecated it and announced
  removal — prefer `Shelly.CloudV2` (same auth key) or the OAuth
  `Shelly.Account` API. Kept as a fallback.

  Takes the same `conn` map as `Shelly.CloudV2`.
  """

  @type conn :: %{server: String.t(), auth_key: String.t()}

  @doc "Full status for one device. Parse with `Shelly.Status.parse/4`."
  def get_status(conn, device_id) do
    case post(conn, "/device/status", id: device_id) do
      {:ok, %{status: 200, body: %{"isok" => true, "data" => data}}} ->
        {:ok, data}

      other ->
        error(other)
    end
  end

  @doc "Switch a relay channel on or off."
  def set_relay(conn, device_id, channel, on?) when is_boolean(on?) do
    body = [id: device_id, channel: channel, turn: if(on?, do: "on", else: "off")]

    case post(conn, "/device/relay/control", body) do
      {:ok, %{status: 200, body: %{"isok" => true}}} -> :ok
      other -> error(other)
    end
  end

  defp post(conn, path, form) do
    Shelly.RateGate.run({conn.server, conn.auth_key}, fn ->
      Req.request(
        method: :post,
        url: conn.server <> path,
        form: Keyword.put(form, :auth_key, conn.auth_key),
        receive_timeout: 15_000,
        retry: false
      )
    end)
  rescue
    e -> {:error, e}
  end

  defp error({:ok, %{status: status, body: body}}), do: {:error, {:shelly_http, status, body}}
  defp error({:error, reason}), do: {:error, reason}
end
