defmodule Shelly.Account do
  require Logger

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
    Enum.flat_map(devices, fn
      {id, info} when is_binary(id) and is_map(info) -> expand_device(id, info)
      # A malformed entry is one device we can't offer, not a crash.
      _entry -> []
    end)
  end

  defp expand_device(id, info) do
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
  end

  # Bounded: this arrives from the API, and a nonsense value would
  # otherwise materialize that many rows.
  @max_channels 64

  defp channel_count(count) when is_integer(count) and count > 0,
    do: min(count, @max_channels)

  defp channel_count(count) when is_binary(count) do
    case Integer.parse(count) do
      {value, ""} when value > 0 -> min(value, @max_channels)
      _ -> 1
    end
  end

  defp channel_count(_count), do: 1

  defp blank_to_nil(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

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
        {:ok, key_by_device(statuses)}

      other ->
        error(other)
    end
  end

  defp key_by_device(statuses) do
    Enum.reduce(statuses, %{}, fn {key, status}, acc ->
      id = status_key(key, status)

      if Map.has_key?(acc, id) do
        # Two entries claiming one id: keeping the last silently discarded
        # a device.
        Logger.warning("Shelly.Account: duplicate device id #{inspect(id)} in all_status")
      end

      Map.put_new(acc, id, status)
    end)
  end

  defp status_key(outer_key, status) do
    id =
      case status do
        # An empty id is not an id — fall back rather than collapsing
        # every such entry under "".
        %{"_dev_info" => %{"id" => id}} when is_binary(id) ->
          blank_to_nil(id) || outer_key

        # Numeric ids go through the same normalization the other two
        # transports use, so one device is one key everywhere.
        %{"_dev_info" => %{"id" => id}} when is_integer(id) ->
          Shelly.Events.normalize_device_id(id)

        _ ->
          outer_key
      end

    id |> to_string() |> String.trim() |> String.downcase()
  end

  @doc """
  Switch a relay channel on or off.

  Takes no options — in particular there is **no `:toggle_after`**, since
  the account API has no equivalent of the v2 endpoint's cloud-side
  watchdog. Passing it returns `{:error, :toggle_after_unsupported}`
  rather than switching without the safety net you asked for. For
  unattended equipment, heating especially, drive control through
  `Shelly.CloudV2.set_switch/5` with an auth key — see "Controlling
  equipment safely" in `Shelly`.
  """
  @spec set_switch(Shelly.Client.t(), String.t(), non_neg_integer(), boolean(), keyword()) ::
          :ok | {:error, term()}
  def set_switch(client, device_id, channel, on?, opts \\ [])

  def set_switch(%Shelly.Client{}, _device_id, _channel, _on?, opts)
      when is_list(opts) and opts != [] do
    if Keyword.has_key?(opts, :toggle_after) do
      # Silently dropping this would leave a caller believing their relay
      # reverts if the app dies — for unattended heating that is the
      # belief that matters most.
      {:error, :toggle_after_unsupported}
    else
      {:error, {:unsupported_options, Keyword.keys(opts)}}
    end
  end

  def set_switch(%Shelly.Client{} = client, device_id, channel, on?, _opts)
      when is_boolean(on?) do
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
  # Total, like the parser it wraps: the documented usage is
  # `parse_status(statuses[id], channel)`, and a missing id yields nil.
  def parse_status(raw_status, channel) when not is_map(raw_status),
    do: Shelly.Status.parse(raw_status, channel, false)

  def parse_status(raw_status, channel) do
    # Account statuses carry the model and generation inside `_dev_info`,
    # not at the top level where the RPC parser looks — without this the
    # recommended path reported model: nil, gen: nil while the legacy
    # auth-key path reported both.
    info = raw_status["_dev_info"]

    extra =
      case info do
        %{} ->
          %{model: info["code"], gen: Shelly.Status.gen_to_int(info["gen"])}

        _ ->
          %{}
      end

    Shelly.Status.parse(raw_status, channel, online?(raw_status), extra)
  end

  # `_dev_info.online` is the cloud's own view and the documented source.
  # `cloud.connected` only exists on mains-powered Gen2+ devices, so
  # reading it first reported every battery, Gen1 and virtual device as
  # offline.
  defp online?(%{"_dev_info" => %{"online" => online}}) when is_boolean(online), do: online
  defp online?(%{"_dev_info" => %{"online" => online}}), do: online in [1, "1", "true"]

  defp online?(%{"cloud" => cloud}) when is_map(cloud), do: cloud["connected"] == true
  defp online?(_status), do: false

  defp post(%Shelly.Client{} = client, path, form) do
    if Shelly.Client.oauth?(client), do: do_post(client, path, form), else: {:error, :no_token}
  end

  defp do_post(%Shelly.Client{} = client, path, form) do
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
