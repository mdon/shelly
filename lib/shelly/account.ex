defmodule Shelly.Account do
  @moduledoc """
  Account-level Shelly Cloud API, authorized by an OAuth access token
  (`Authorization: Bearer`) — no per-device auth keys needed.

  An *account* here is a plain map (or any struct) with:

    * `:server` — the account's cloud server, e.g.
      `"https://shelly-74-eu.shelly.cloud"` (from `Shelly.OAuth`'s
      `user_api_url`)
    * `:token` — the OAuth access token

  All calls are paced through `Shelly.RateGate` when it is running
  (~1 request/second/account is the cloud's limit).
  """

  @type account :: %{server: String.t(), token: String.t()}

  @doc """
  List every device on the account (`get_all_lists`): id, user-given
  name, model/type, generation, channel count, room, online state.

  Returns `{:ok, devices}` where `devices` is the raw map keyed by
  device id — see `expand_channels/1` for a flattened per-channel list.
  """
  def list_devices(account) do
    case post(account, "/interface/device/get_all_lists", []) do
      {:ok, %{status: 200, body: %{"isok" => true, "data" => %{"devices" => devices}}}} ->
        {:ok, devices}

      other ->
        error(other)
    end
  end

  @doc """
  Flatten a `list_devices/1` result into one entry per channel —
  multi-relay devices (Pro 2/3/4) become several addable rows.
  """
  def expand_channels(devices) when is_map(devices) do
    Enum.flat_map(devices, fn {id, info} ->
      channels = max(info["channels_count"] || 1, 1)
      base_name = info["name"] || id

      for channel <- 0..(channels - 1) do
        %{
          id: String.downcase(id),
          channel: channel,
          name: if(channels > 1, do: "#{base_name} · ch#{channel}", else: base_name),
          model: info["type"],
          gen: info["gen"],
          online: info["cloud_online"] == true,
          raw: info
        }
      end
    end)
  end

  @doc """
  Status of every device on the account in ONE call (`all_status`).
  Returns `{:ok, %{device_id => raw_status}}` with lowercase ids; parse
  per device/channel with `Shelly.Status.parse/4`.
  """
  def all_statuses(account) do
    case post(account, "/device/all_status", show_info: true) do
      {:ok, %{status: 200, body: %{"isok" => true, "data" => %{"devices_status" => statuses}}}} ->
        {:ok, Map.new(statuses, fn {id, st} -> {String.downcase(id), st} end)}

      other ->
        error(other)
    end
  end

  @doc "Switch a relay channel on or off."
  def set_switch(account, device_id, channel, on?) when is_boolean(on?) do
    body = [id: device_id, channel: channel, turn: if(on?, do: "on", else: "off")]

    case post(account, "/device/relay/control", body) do
      {:ok, %{status: 200, body: %{"isok" => true}}} -> :ok
      other -> error(other)
    end
  end

  @doc """
  Parse one device's `all_statuses/1` entry for a channel — derives
  online from the payload's cloud connectivity instead of assuming it:

      {:ok, statuses} = Shelly.Account.all_statuses(account)
      Shelly.Account.parse_status(statuses["0cdc7ef76644"], 0)
  """
  def parse_status(raw_status, channel) when is_map(raw_status) do
    online = get_in(raw_status, ["cloud", "connected"]) == true
    Shelly.Status.parse(raw_status, channel, online)
  end

  defp post(account, path, form) do
    case Shelly.RateGate.run({account.server, account.token}, fn ->
           Req.request(
             method: :post,
             url: account.server <> path,
             headers: [{"Authorization", "Bearer " <> account.token}],
             form: form,
             receive_timeout: 15_000,
             retry: false
           )
         end) do
      {:error, :throttled} -> {:error, :throttled}
      other -> other
    end
  end

  defp error({:ok, %{status: status, body: body}}), do: {:error, {:shelly_http, status, body}}
  defp error({:error, reason}), do: {:error, reason}
end
