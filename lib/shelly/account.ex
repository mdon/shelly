defmodule Shelly.Account do
  @moduledoc """
  Account-level Shelly Cloud API, authorized by an OAuth access token
  (`Authorization: Bearer`) — no per-device auth keys needed.

  Every function takes a `Shelly.Client` holding a `:token`, usually
  straight from `Shelly.OAuth.exchange_code/2`.

  All calls are paced through `Shelly.RateGate` when it is running
  (~1 request/second/account is the cloud's limit).
  """

  @doc """
  List every device on the account (`get_all_lists`): id, user-given
  name, model/type, generation, channel count, room, online state.

  Returns `{:ok, devices}` where `devices` is the raw map keyed by
  device id — see `expand_channels/1` for a flattened per-channel list.
  """
  @spec list_devices(Shelly.Client.t()) :: {:ok, map()} | {:error, term()}
  def list_devices(%Shelly.Client{} = client) do
    case post(client, "/interface/device/get_all_lists", []) do
      {:ok, %{status: 200, body: %{"isok" => true, "data" => %{"devices" => devices}}}}
      when is_map(devices) ->
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
  @spec all_statuses(Shelly.Client.t()) ::
          {:ok, %{optional(String.t()) => map()}} | {:error, term()}
  def all_statuses(%Shelly.Client{} = client) do
    case post(client, "/device/all_status", show_info: true) do
      {:ok, %{status: 200, body: %{"isok" => true, "data" => %{"devices_status" => statuses}}}}
      when is_map(statuses) ->
        {:ok, Map.new(statuses, fn {key, st} -> {status_key(key, st), st} end)}

      other ->
        error(other)
    end
  end

  defp status_key(outer_key, status) do
    id =
      case status do
        # An empty id is not an id — fall back rather than collapsing
        # every such entry under "".
        %{"_dev_info" => %{"id" => id}} when is_binary(id) and id != "" -> id
        _ -> outer_key
      end

    String.downcase(id)
  end

  @doc "Switch a relay channel on or off."
  @spec set_switch(Shelly.Client.t(), String.t(), non_neg_integer(), boolean()) ::
          :ok | {:error, term()}
  def set_switch(%Shelly.Client{} = client, device_id, channel, on?) when is_boolean(on?) do
    body = [id: device_id, channel: channel, turn: if(on?, do: "on", else: "off")]

    case post(client, "/device/relay/control", body) do
      {:ok, %{status: 200, body: %{"isok" => true}}} -> :ok
      other -> error(other)
    end
  end

  @doc """
  Parse one device's `all_statuses/1` entry for a channel. Online state
  comes from `_dev_info.online`, the cloud's own view, which every device
  carries — unlike `cloud.connected`, which only mains-powered Gen2+
  hardware reports:

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

  defp post(%Shelly.Client{token: nil}, _path, _form), do: {:error, :no_token}

  defp post(%Shelly.Client{} = client, path, form) do
    case Shelly.RateGate.run(Shelly.Client.rate_key(client), fn ->
           Shelly.HTTP.request(
             [
               method: :post,
               url: client.server <> path,
               headers: [{"Authorization", "Bearer " <> client.token}],
               form: form,
               receive_timeout: 15_000,
               retry: false
             ],
             client
           )
         end) do
      {:error, :throttled} -> {:error, :throttled}
      other -> other
    end
  end

  defp error({:ok, %{status: status, body: body}}), do: {:error, {:shelly_http, status, body}}
  defp error({:error, reason}), do: {:error, reason}
end
