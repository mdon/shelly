defmodule Shelly.Account do
  @moduledoc """
  Account-level Shelly Cloud API, authorized by an OAuth access token
  (`Authorization: Bearer`) — no per-device auth keys needed.

  An *account* here is a plain map (or any struct) with:

    * `:server` — the account's cloud server, e.g.
      `"https://shelly-74-eu.shelly.cloud"` (from `Shelly.OAuth`'s
      `user_api_url`)
    * `:token` — the OAuth access token
    * `:rate_key` — *optional*, a stable identifier for the account
      (e.g. its id). Rate limiting is per account, so setting this keeps
      one budget across token refreshes and across the auth-key clients;
      without it the token itself is the key.
    * `:req_options` — *optional* keyword list merged into every Req
      call (proxy, timeouts, a `:plug` stub in tests)

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
  @spec list_devices(account()) :: {:ok, map()} | {:error, term()}
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
  @spec expand_channels(map()) :: [map()]
  def expand_channels(devices) when is_map(devices) do
    Enum.flat_map(devices, fn {id, info} ->
      channels = channel_count(info["channels_count"])
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

  defp channel_count(count) when is_integer(count) and count > 0, do: count

  defp channel_count(count) when is_binary(count) do
    case Integer.parse(count) do
      {value, _} when value > 0 -> value
      _ -> 1
    end
  end

  defp channel_count(_count), do: 1

  @doc """
  Status of every device on the account in ONE call (`all_status`).
  Returns `{:ok, %{device_id => raw_status}}` with lowercase ids; parse
  per device/channel with `Shelly.Status.parse/4`.

  Keys come from each entry's `_dev_info.id`, not from the map key
  Shelly returns them under: the vendor documents those outer keys as
  inconsistent ("should be ignored", notably for virtual/thermostat
  devices), and a caller looking a device up by id would silently miss
  it. The outer key is the fallback when an entry carries no `_dev_info`.
  """
  @spec all_statuses(account()) :: {:ok, %{optional(String.t()) => map()}} | {:error, term()}
  def all_statuses(account) do
    case post(account, "/device/all_status", show_info: true) do
      {:ok, %{status: 200, body: %{"isok" => true, "data" => %{"devices_status" => statuses}}}} ->
        {:ok, Map.new(statuses, fn {key, st} -> {status_key(key, st), st} end)}

      other ->
        error(other)
    end
  end

  defp status_key(outer_key, status) do
    id =
      case status do
        %{"_dev_info" => %{"id" => id}} when is_binary(id) -> id
        _ -> outer_key
      end

    String.downcase(id)
  end

  @doc "Switch a relay channel on or off."
  @spec set_switch(account(), String.t(), non_neg_integer(), boolean()) :: :ok | {:error, term()}
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
  @spec parse_status(map(), non_neg_integer()) :: Shelly.Status.t()
  def parse_status(raw_status, channel) when is_map(raw_status) do
    Shelly.Status.parse(raw_status, channel, online?(raw_status))
  end

  # `_dev_info.online` is the cloud's own view and the documented source.
  # `cloud.connected` only exists on mains-powered Gen2+ devices, so
  # reading it first reported every battery, Gen1 and virtual device as
  # offline.
  defp online?(%{"_dev_info" => %{"online" => online}}) when is_boolean(online), do: online
  defp online?(%{"_dev_info" => %{"online" => online}}), do: online in [1, "true"]
  defp online?(status), do: get_in(status, ["cloud", "connected"]) == true

  defp post(account, path, form) do
    case Shelly.RateGate.run(rate_key(account), fn ->
           Shelly.HTTP.request(
             [
               method: :post,
               url: account.server <> path,
               headers: [{"Authorization", "Bearer " <> account.token}],
               form: form,
               receive_timeout: 15_000,
               retry: false
             ],
             account
           )
         end) do
      {:error, :throttled} -> {:error, :throttled}
      other -> other
    end
  end

  # Shelly's ~1 req/s budget is per ACCOUNT, so the pacing key must not
  # change when the token is refreshed (a fresh key would let a burst
  # through) and must be shareable with the auth-key clients. Callers can
  # set `:rate_key` explicitly; otherwise the token is the fallback.
  defp rate_key(%{rate_key: key}) when not is_nil(key), do: {:shelly_account, key}
  defp rate_key(account), do: {account.server, account.token}

  defp error({:ok, %{status: status, body: body}}), do: {:error, {:shelly_http, status, body}}
  defp error({:error, reason}), do: {:error, reason}
end
