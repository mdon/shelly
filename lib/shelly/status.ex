defmodule Shelly.Status do
  @moduledoc """
  Parses Shelly device status payloads into a flat status map — one parser for every transport (legacy v1 API,
  v2 API, OAuth account API, websocket events) and every hardware shape:

    * **Gen2/3/4 RPC components**, per channel, in resolution order:
      `switch:N` (relays, with or without power metering — Plus 1PM
      meters, Shelly 1 Gen4 and Pro 3 don't), `cover:N` (roller
      shutters), `light:N` (dimmers), `pm1:N` (metering-only PM Mini),
      `em1:N` / `em:0` (Pro 3EM class energy meters — measure, can't
      switch).
    * **Gen1 arrays**: `relays`/`meters` (Watt-minute counters!),
      `lights`, `rollers`, `emeters`.

  Besides the live values, the parse reports what it found:
  `:component` ("switch", "cover", "light", "pm", "em", "relay", …,
  "unknown") and `:metered` (the payload actually carries a power
  measurement — a 0 W reading from an unmetered relay is not data).

  `has_component?/2` guards partial payloads: websocket events may
  carry only the piece that changed (`sys`, an input), and parsing
  those as a full status would wrongly report the device off.
  """

  @doc """
  Parse a device_status map for one channel. `online` is supplied by the
  caller (it lives outside device_status in every transport). `extra`
  merges transport-level fields (model/gen) over the parsed defaults.
  """
  def parse(status, channel, online, extra \\ %{})

  def parse(status, channel, online, extra) when is_map(status) do
    base =
      cond do
        is_map(status["switch:#{channel}"]) ->
          parse_switch(status, channel, online)

        is_map(status["cover:#{channel}"]) ->
          parse_cover(status, channel, online)

        is_map(status["light:#{channel}"]) ->
          parse_light(status, channel, online)

        is_map(status["pm1:#{channel}"]) ->
          parse_pm1(status, channel, online)

        is_map(status["em1:#{channel}"]) ->
          parse_em1(status, channel, online)

        is_map(status["em:0"]) and channel == 0 ->
          parse_em(status, online)

        light_family_key(status, channel) ->
          parse_light_family(status, channel, online)

        is_map(status["flood:#{channel}"]) ->
          parse_alarm(status, "flood", channel, online)

        is_map(status["smoke:#{channel}"]) ->
          parse_alarm(status, "smoke", channel, online)

        is_map(status["presence:#{channel}"]) ->
          parse_presence(status, channel, online)

        is_map(status["temperature:#{channel}"]) or is_map(status["humidity:#{channel}"]) ->
          parse_rpc_sensor(status, channel, online)

        is_map(status["voltmeter:#{channel}"]) ->
          parse_voltmeter(status, channel, online)

        is_map(status["devicepower:#{channel}"]) ->
          parse_rpc_sensor(status, channel, online)

        is_list(status["relays"]) ->
          parse_gen1_relay(status, channel, online)

        is_list(status["lights"]) ->
          parse_gen1_light(status, channel, online)

        is_list(status["rollers"]) ->
          parse_gen1_roller(status, channel, online)

        is_list(status["emeters"]) ->
          parse_gen1_emeter(status, channel, online)

        gen1_sensor?(status) ->
          parse_gen1_sensor(status, online)

        true ->
          unknown_status(status, online)
      end

    base
    |> enrich(status)
    |> Map.merge(extra, fn _k, parsed, from_extra ->
      if is_nil(from_extra), do: parsed, else: from_extra
    end)
  end

  def parse(_status, _channel, online, extra) do
    unknown_status(%{}, online)
    |> Map.merge(extra, fn _k, parsed, from_extra ->
      if is_nil(from_extra), do: parsed, else: from_extra
    end)
  end

  @doc """
  Does this payload carry actual data for the device's channel?
  Partial payloads (websocket deltas with only `sys` or an input
  update) must be skipped, not parsed into a false "off".
  """
  def has_component?(status, channel) when is_map(status) do
    is_map(status["switch:#{channel}"]) or
      is_map(status["cover:#{channel}"]) or
      is_map(status["light:#{channel}"]) or
      is_map(status["pm1:#{channel}"]) or
      is_map(status["em1:#{channel}"]) or
      (channel == 0 and is_map(status["em:0"])) or
      light_family_key(status, channel) != nil or
      is_map(status["flood:#{channel}"]) or
      is_map(status["smoke:#{channel}"]) or
      is_map(status["presence:#{channel}"]) or
      is_map(status["temperature:#{channel}"]) or
      is_map(status["humidity:#{channel}"]) or
      is_map(status["voltmeter:#{channel}"]) or
      gen1_sensor?(status) or
      gen1_channel_present?(status["relays"], channel) or
      gen1_channel_present?(status["lights"], channel) or
      gen1_channel_present?(status["rollers"], channel) or
      gen1_channel_present?(status["emeters"], channel)
  end

  def has_component?(_status, _channel), do: false

  defp gen1_channel_present?(list, channel) when is_list(list), do: length(list) > channel
  defp gen1_channel_present?(_, _), do: false

  @doc ~S|Normalize the v2 API's gen strings ("G1".."G4") to integers.|
  def gen_to_int("G" <> rest) do
    case Integer.parse(rest) do
      {n, ""} -> n
      _ -> nil
    end
  end

  def gen_to_int(n) when is_integer(n), do: n
  def gen_to_int(_), do: nil

  ## Gen2+ components -----------------------------------------------------

  defp parse_switch(status, channel, online) do
    sw = status["switch:#{channel}"]

    rpc_common(status, online, channel)
    |> Map.merge(%{
      on: sw["output"] == true,
      watts: to_float(sw["apower"]),
      voltage: opt_float(sw["voltage"]),
      current: opt_float(sw["current"]),
      energy_wh: opt_float(get_in(sw, ["aenergy", "total"])),
      temp_c: opt_float(get_in(sw, ["temperature", "tC"])),
      source: opt_string(sw["source"]),
      metered: is_number(sw["apower"]),
      component: "switch"
    })
  end

  defp parse_cover(status, channel, online) do
    cover = status["cover:#{channel}"]

    rpc_common(status, online, channel)
    |> Map.merge(%{
      # A cover is "on" while it is anywhere but fully closed — motion
      # and open positions both count; rules/toggles map to open/close.
      on: cover["state"] not in ["closed", nil],
      watts: to_float(cover["apower"]),
      voltage: opt_float(cover["voltage"]),
      current: opt_float(cover["current"]),
      energy_wh: opt_float(get_in(cover, ["aenergy", "total"])),
      temp_c: opt_float(get_in(cover, ["temperature", "tC"])),
      source: opt_string(cover["source"]),
      metered: is_number(cover["apower"]),
      component: "cover"
    })
  end

  defp parse_light(status, channel, online) do
    light = status["light:#{channel}"]

    rpc_common(status, online, channel)
    |> Map.merge(%{
      on: light["output"] == true,
      watts: to_float(light["apower"]),
      voltage: opt_float(light["voltage"]),
      current: opt_float(light["current"]),
      energy_wh: opt_float(get_in(light, ["aenergy", "total"])),
      temp_c: opt_float(get_in(light, ["temperature", "tC"])),
      source: opt_string(light["source"]),
      metered: is_number(light["apower"]),
      component: "light"
    })
  end

  # PM Mini class: measures a circuit, cannot switch it. `on` is
  # meaningless — kept false; the data is the wattage.
  defp parse_pm1(status, channel, online) do
    pm = status["pm1:#{channel}"]

    rpc_common(status, online, channel)
    |> Map.merge(%{
      on: false,
      watts: to_float(pm["apower"]),
      voltage: opt_float(pm["voltage"]),
      current: opt_float(pm["current"]),
      energy_wh: opt_float(get_in(pm, ["aenergy", "total"])),
      metered: is_number(pm["apower"]),
      component: "pm"
    })
  end

  # Pro 3EM single-phase channels.
  defp parse_em1(status, channel, online) do
    em = status["em1:#{channel}"]

    rpc_common(status, online, channel)
    |> Map.merge(%{
      on: false,
      watts: to_float(em["act_power"] || em["apower"]),
      voltage: opt_float(em["voltage"]),
      current: opt_float(em["current"]),
      energy_wh: opt_float(get_in(em, ["aenergy", "total"])),
      metered: is_number(em["act_power"] || em["apower"]),
      component: "em"
    })
  end

  # Pro 3EM three-phase aggregate.
  defp parse_em(status, online) do
    em = status["em:0"]

    rpc_common(status, online, 0)
    |> Map.merge(%{
      on: false,
      watts: to_float(em["total_act_power"]),
      current: opt_float(em["total_current"]),
      metered: is_number(em["total_act_power"]),
      component: "em"
    })
  end

  defp rpc_common(status, online, channel \\ 0) do
    wifi = status["wifi"] || %{}
    input = status["input:#{channel}"] || %{}

    %{
      online: online,
      on: false,
      watts: 0.0,
      voltage: nil,
      current: nil,
      energy_wh: nil,
      temp_c: nil,
      rssi: opt_int(wifi["rssi"]),
      input_state: opt_bool(input["state"]),
      source: nil,
      model: opt_string(status["code"]),
      gen: nil,
      metered: false,
      component: "unknown",
      raw: status
    }
  end

  ## Gen1 arrays -----------------------------------------------------------

  defp parse_gen1_relay(status, channel, online) do
    relay = Enum.at(status["relays"] || [], channel) || %{}
    meter = Enum.at(status["meters"] || [], channel)

    gen1_common(status, channel, online)
    |> Map.merge(%{
      on: relay["ison"] == true,
      watts: to_float(meter && meter["power"]),
      # Gen1 relay energy counters count Watt-minutes, not Wh.
      energy_wh: watt_minutes_to_wh(meter && meter["total"]),
      source: opt_string(relay["source"]),
      metered: is_number(meter && meter["power"]),
      component: "relay"
    })
  end

  defp parse_gen1_light(status, channel, online) do
    light = Enum.at(status["lights"] || [], channel) || %{}
    meter = Enum.at(status["meters"] || [], channel)

    gen1_common(status, channel, online)
    |> Map.merge(%{
      on: light["ison"] == true,
      watts: to_float(meter && meter["power"]),
      energy_wh: watt_minutes_to_wh(meter && meter["total"]),
      metered: is_number(meter && meter["power"]),
      component: "light"
    })
  end

  defp parse_gen1_roller(status, channel, online) do
    roller = Enum.at(status["rollers"] || [], channel) || %{}
    meter = Enum.at(status["meters"] || [], channel)

    position = roller["current_pos"]

    gen1_common(status, channel, online)
    |> Map.merge(%{
      # Gen1 rollers report "open" | "close" | "stop"; when calibrated,
      # current_pos (0..100) is the reliable openness signal.
      on:
        if(is_number(position) and position >= 0,
          do: position > 0,
          else: roller["state"] == "open"
        ),
      watts: to_float(roller["power"] || (meter && meter["power"])),
      metered: is_number(roller["power"] || (meter && meter["power"])),
      component: "cover"
    })
  end

  defp parse_gen1_emeter(status, channel, online) do
    emeter = Enum.at(status["emeters"] || [], channel) || %{}

    gen1_common(status, channel, online)
    |> Map.merge(%{
      on: false,
      watts: to_float(emeter["power"]),
      voltage: opt_float(emeter["voltage"]),
      # Gen1 emeters count real Wh (unlike relay meters).
      energy_wh: opt_float(emeter["total"]),
      metered: is_number(emeter["power"]),
      component: "em"
    })
  end

  defp gen1_common(status, channel, online) do
    wifi = status["wifi_sta"] || %{}
    input = Enum.at(status["inputs"] || [], channel) || %{}

    %{
      online: online,
      on: false,
      watts: 0.0,
      voltage: opt_float(status["voltage"]),
      current: nil,
      energy_wh: nil,
      temp_c: opt_float(get_in(status, ["tmp", "tC"]) || numeric(status["temperature"])),
      rssi: opt_int(wifi["rssi"]),
      input_state: gen1_input(input["input"]),
      source: nil,
      model: nil,
      gen: 1,
      metered: false,
      component: "unknown",
      raw: status
    }
  end

  # CCT / RGB / RGBW / RGBCCT lights share the light contract (output +
  # optional apower); resolve whichever variant the channel has.
  defp light_family_key(status, channel) when is_map(status) do
    Enum.find(
      ["cct:#{channel}", "rgb:#{channel}", "rgbw:#{channel}", "rgbcct:#{channel}"],
      fn key ->
        is_map(status[key])
      end
    )
  end

  defp light_family_key(_, _), do: nil

  defp parse_light_family(status, channel, online) do
    light = status[light_family_key(status, channel)]

    rpc_common(status, online, channel)
    |> Map.merge(%{
      on: light["output"] == true,
      watts: to_float(light["apower"]),
      voltage: opt_float(light["voltage"]),
      current: opt_float(light["current"]),
      energy_wh: opt_float(get_in(light, ["aenergy", "total"])),
      source: opt_string(light["source"]),
      metered: is_number(light["apower"]),
      component: "light"
    })
  end

  # Flood / smoke sensors: "on" = alarm ringing. Honest and useful.
  defp parse_alarm(status, kind, channel, online) do
    sensor = status["#{kind}:#{channel}"]

    rpc_common(status, online, channel)
    |> Map.merge(%{on: sensor["alarm"] == true, component: kind})
  end

  defp parse_presence(status, channel, online) do
    presence = status["presence:#{channel}"]

    detected =
      presence["num_objects"] |> numeric() |> Kernel.||(0) > 0 or presence["presence"] == true

    rpc_common(status, online, channel)
    |> Map.merge(%{on: detected, component: "presence"})
  end

  # H&T-class devices: temperature/humidity (+devicepower) and nothing
  # switchable. Battery and temp land via enrich/2.
  defp parse_rpc_sensor(status, channel, online) do
    rpc_common(status, online, channel)
    |> Map.merge(%{component: "sensor"})
  end

  defp parse_voltmeter(status, channel, online) do
    volt = status["voltmeter:#{channel}"]

    rpc_common(status, online, channel)
    |> Map.merge(%{voltage: opt_float(volt["voltage"]), component: "sensor"})
  end

  # Gen1 battery sensors (H&T, Flood, Smoke, Door/Window, Motion) have
  # tmp/hum/bat/alarm keys and no actuator arrays.
  defp gen1_sensor?(status) when is_map(status) do
    (is_map(status["tmp"]) or is_map(status["hum"]) or is_map(status["bat"]) or
       is_boolean(status["flood"]) or is_boolean(status["smoke"]) or is_boolean(status["motion"])) and
      not is_list(status["relays"]) and not is_list(status["lights"]) and
      not is_list(status["rollers"]) and not is_list(status["emeters"])
  end

  defp gen1_sensor?(_), do: false

  defp parse_gen1_sensor(status, online) do
    {on, component} =
      cond do
        is_boolean(status["flood"]) -> {status["flood"], "flood"}
        is_boolean(status["smoke"]) -> {status["smoke"], "smoke"}
        is_boolean(status["motion"]) -> {status["motion"], "presence"}
        true -> {false, "sensor"}
      end

    gen1_common(status, 0, online)
    |> Map.merge(%{on: on, component: component})
  end

  # Cross-cutting fields that ride ALONGSIDE the main component:
  # battery (devicepower / gen1 bat) and sensor temperature when the
  # component itself carried none.
  defp enrich(parsed, status) do
    battery =
      opt_int(get_in(status, ["devicepower:0", "battery", "percent"])) ||
        opt_int(get_in(status, ["bat", "value"]))

    temp =
      parsed[:temp_c] ||
        opt_float(get_in(status, ["temperature:0", "tC"])) ||
        opt_float(get_in(status, ["tmp", "tC"]))

    parsed
    |> Map.put(:battery, battery)
    |> Map.put(:temp_c, temp)
  end

  @doc """
  Which component the payload carries for this channel ("switch",
  "cover", "light", "pm", "em", "relay", "flood", "smoke", "presence",
  "sensor") or nil when none — use it to guard event deltas against a
  device's known component before applying `parse/4`.
  """
  def component_of(status, channel) when is_map(status) do
    cond do
      is_map(status["switch:#{channel}"]) ->
        "switch"

      is_map(status["cover:#{channel}"]) ->
        "cover"

      is_map(status["light:#{channel}"]) ->
        "light"

      light_family_key(status, channel) ->
        "light"

      is_map(status["pm1:#{channel}"]) ->
        "pm"

      is_map(status["em1:#{channel}"]) ->
        "em"

      channel == 0 and is_map(status["em:0"]) ->
        "em"

      is_map(status["flood:#{channel}"]) ->
        "flood"

      is_map(status["smoke:#{channel}"]) ->
        "smoke"

      is_map(status["presence:#{channel}"]) ->
        "presence"

      is_map(status["temperature:#{channel}"]) or is_map(status["humidity:#{channel}"]) ->
        "sensor"

      is_map(status["voltmeter:#{channel}"]) ->
        "sensor"

      is_list(status["relays"]) and length(status["relays"]) > channel ->
        "relay"

      is_list(status["lights"]) and length(status["lights"]) > channel ->
        "light"

      is_list(status["rollers"]) and length(status["rollers"]) > channel ->
        "cover"

      is_list(status["emeters"]) and length(status["emeters"]) > channel ->
        "em"

      gen1_sensor?(status) ->
        "sensor"

      true ->
        nil
    end
  end

  def component_of(_status, _channel), do: nil

  defp unknown_status(raw, online) do
    %{
      on: false,
      online: online,
      watts: 0.0,
      voltage: nil,
      current: nil,
      energy_wh: nil,
      temp_c: nil,
      rssi: nil,
      input_state: nil,
      source: nil,
      model: nil,
      gen: nil,
      battery: nil,
      metered: false,
      component: "unknown",
      raw: raw
    }
  end

  ## Small helpers ---------------------------------------------------------

  defp watt_minutes_to_wh(n) when is_number(n), do: n / 60.0
  defp watt_minutes_to_wh(_), do: nil

  defp gen1_input(1), do: true
  defp gen1_input(0), do: false
  defp gen1_input(b) when is_boolean(b), do: b
  defp gen1_input(_), do: nil

  defp numeric(n) when is_number(n), do: n
  defp numeric(_), do: nil

  defp to_float(n) when is_number(n), do: n * 1.0
  defp to_float(_), do: 0.0

  defp opt_float(n) when is_number(n), do: n * 1.0
  defp opt_float(_), do: nil

  defp opt_int(n) when is_integer(n), do: n
  defp opt_int(n) when is_float(n), do: round(n)
  defp opt_int(_), do: nil

  defp opt_bool(b) when is_boolean(b), do: b
  defp opt_bool(_), do: nil

  defp opt_string(s) when is_binary(s), do: s
  defp opt_string(_), do: nil
end
