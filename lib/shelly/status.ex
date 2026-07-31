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

  ## Known limitations on two Gen1 devices

    * **Shelly 2.5 in roller mode** reports `relays` *and* `rollers`, and
      relays win — so an open blind reads as a closed relay. The device
      gives no in-payload signal of its mode, and reordering would break
      the far more common relay mode, which also carries a `rollers`
      array. Pass `extra: %{component: "cover"}` when you know the mode.
    * **Pro 3EM channel 0** resolves to `em1:0` (phase A) rather than the
      `em:0` three-phase aggregate, since a per-channel component is the
      more useful answer for a caller asking about channel 0. Read
      `status["em:0"]` directly for the total.
  """

  @typedoc """
  A parsed status.

  Every parse emits all of these keys, so pattern-matching is safe. It is
  deliberately a plain map rather than a struct because `parse/4` merges a
  caller-supplied `extra` map into the result — a documented extension
  point for transport-level fields the parser doesn't know about. Merging
  arbitrary keys into a struct produces a malformed struct instead of an
  error, which would turn that extension point into silent corruption.

  `:on` is `nil` when the payload named the component but carried no
  state for it (a partial websocket delta) — unknown, not off.
  """
  @type t :: %{
          on: boolean() | nil,
          online: boolean(),
          watts: float(),
          voltage: float() | nil,
          current: float() | nil,
          energy_wh: float() | nil,
          temp_c: float() | nil,
          humidity: float() | nil,
          battery: integer() | nil,
          rssi: integer() | nil,
          input_state: boolean() | nil,
          source: String.t() | nil,
          model: String.t() | nil,
          gen: integer() | nil,
          metered: boolean(),
          component: String.t(),
          raw: map()
        }

  @doc """
  Parse a device_status map for one channel. `online` is supplied by the
  caller (it lives outside device_status in every transport). `extra`
  merges transport-level fields (model/gen) over the parsed defaults.
  """
  @spec parse(map() | term(), non_neg_integer(), boolean(), map()) :: t()
  def parse(status, channel, online, extra \\ %{})

  def parse(status, channel, online, extra) when is_map(status) and is_map(extra) do
    base =
      case forced_tag(extra, status, channel) || component_tag(status, channel) do
        nil -> unknown_status(status, online)
        tag -> parse_tagged(tag, status, channel, online)
      end

    base
    |> enrich(status, channel)
    # `:component` steered the dispatch above; merging it as a value too
    # would relabel a status when the hint matched nothing, which is the
    # confidently-wrong answer this option exists to avoid.
    |> Map.merge(Map.delete(extra, :component), fn _k, parsed, from_extra ->
      if is_nil(from_extra), do: parsed, else: from_extra
    end)
  end

  # A non-map `extra` is a caller mistake, not a reason to raise.
  def parse(status, channel, online, _extra) when is_map(status),
    do: parse(status, channel, online, %{})

  def parse(_status, _channel, online, extra) when is_map(extra) do
    unknown_status(%{}, online)
    |> Map.merge(extra, fn _k, parsed, from_extra ->
      if is_nil(from_extra), do: parsed, else: from_extra
    end)
  end

  def parse(_status, _channel, online, _extra), do: unknown_status(%{}, online)

  @doc """
  Does this payload carry actual data for the device's channel?
  Partial payloads (websocket deltas with only `sys` or an input
  update) must be skipped, not parsed into a false "off".
  """
  @spec has_component?(map() | term(), non_neg_integer()) :: boolean()
  def has_component?(status, channel) when is_map(status) do
    component_tag(status, channel) != nil
  end

  def has_component?(_status, _channel), do: false

  ## One dispatch --------------------------------------------------------
  #
  # `parse/4`, `has_component?/2` and `component_of/2` used to enumerate
  # every device class separately. They drifted — `component_of/2` called
  # a Gen1 flood sensor "sensor" while `parse/4` called it "flood", so a
  # caller guarding one against the other dropped every event from those
  # devices, and Gen1 arrays were dispatched without the channel check the
  # other two applied. All three now derive from `component_tag/2`, so a
  # new device class is added in exactly one place.

  # Resolution order, most actionable first: **actuators** (things you can
  # switch), then **meters** (things that measure), then **sensors**
  # (things that report a condition). A payload naming several components
  # for one channel answers with the one a caller can act on.
  #
  # Two forms can't be expressed as "prefix:channel" — the light family
  # spans four keys, the three-phase aggregate exists only on channel 0 —
  # so they are interleaved explicitly at their place in the order rather
  # than being demoted to the end by accident.

  # {payload key prefix, tag, reported component}
  @actuator_components [
    {"switch", :switch, "switch"},
    {"cover", :cover, "cover"},
    {"light", :light, "light"}
  ]

  @meter_components [
    {"pm1", :pm1, "pm"},
    {"em1", :em1, "em"}
  ]

  @sensor_components [
    {"flood", :flood, "flood"},
    {"smoke", :smoke, "smoke"},
    {"presence", :presence, "presence"},
    {"voltmeter", :voltmeter, "sensor"}
  ]

  @rpc_components @actuator_components ++ @meter_components ++ @sensor_components

  # {payload key, tag, reported component} — Gen1 arrays, indexed by channel
  @gen1_arrays [
    {"relays", :gen1_relay, "relay"},
    {"lights", :gen1_light, "light"},
    {"rollers", :gen1_roller, "cover"},
    {"emeters", :gen1_emeter, "em"}
  ]

  defp component_tag(status, channel) do
    rpc_tag(status, channel) || gen1_tag(status, channel)
  end

  defp rpc_tag(status, channel) do
    actuator_tag(status, channel) ||
      meter_tag(status, channel) ||
      sensor_tag(status, channel)
  end

  defp actuator_tag(status, channel) do
    prefix_tag(@actuator_components, status, channel) ||
      if light_family_key(status, channel), do: :light_family
  end

  defp meter_tag(status, channel) do
    prefix_tag(@meter_components, status, channel) ||
      if channel == 0 and is_map(status["em:0"]), do: :em
  end

  defp sensor_tag(status, channel) do
    prefix_tag(@sensor_components, status, channel) ||
      if is_map(status["temperature:#{channel}"]) or is_map(status["humidity:#{channel}"]),
        do: :rpc_sensor
  end

  defp prefix_tag(components, status, channel) do
    Enum.find_value(components, fn {prefix, tag, _component} ->
      if is_map(status["#{prefix}:#{channel}"]), do: tag
    end)
  end

  defp gen1_tag(status, channel) do
    # Gen1 battery sensors are single-channel devices; answering for
    # every channel made has_component?/2 useless for them.
    Enum.find_value(@gen1_arrays, fn {key, tag, _component} ->
      if gen1_channel_present?(status[key], channel), do: tag
    end) ||
      if channel == 0 and gen1_sensor?(status), do: :gen1_sensor
  end

  defp tag_component(:light_family, _status), do: "light"
  defp tag_component(:rpc_sensor, _status), do: "sensor"
  defp tag_component(:em, _status), do: "em"
  # Must match what parse_gen1_sensor/2 reports, or a caller guarding one
  # against the other silently drops the device.
  defp tag_component(:gen1_sensor, status), do: gen1_sensor_component(status)

  defp tag_component(tag, _status) do
    Enum.find_value(@rpc_components ++ @gen1_arrays, fn {_key, candidate, component} ->
      if candidate == tag, do: component
    end)
  end

  defp parse_tagged(:switch, status, channel, online), do: parse_switch(status, channel, online)
  defp parse_tagged(:cover, status, channel, online), do: parse_cover(status, channel, online)
  defp parse_tagged(:light, status, channel, online), do: parse_light(status, channel, online)
  defp parse_tagged(:pm1, status, channel, online), do: parse_pm1(status, channel, online)
  defp parse_tagged(:em1, status, channel, online), do: parse_em1(status, channel, online)
  defp parse_tagged(:em, status, _channel, online), do: parse_em(status, online)

  defp parse_tagged(:light_family, status, channel, online),
    do: parse_light_family(status, channel, online)

  defp parse_tagged(:flood, status, channel, online),
    do: parse_alarm(status, "flood", channel, online)

  defp parse_tagged(:smoke, status, channel, online),
    do: parse_alarm(status, "smoke", channel, online)

  defp parse_tagged(:presence, status, channel, online),
    do: parse_presence(status, channel, online)

  defp parse_tagged(:rpc_sensor, status, channel, online),
    do: parse_rpc_sensor(status, channel, online)

  defp parse_tagged(:voltmeter, status, channel, online),
    do: parse_voltmeter(status, channel, online)

  defp parse_tagged(:gen1_relay, status, channel, online),
    do: parse_gen1_relay(status, channel, online)

  defp parse_tagged(:gen1_light, status, channel, online),
    do: parse_gen1_light(status, channel, online)

  defp parse_tagged(:gen1_roller, status, channel, online),
    do: parse_gen1_roller(status, channel, online)

  defp parse_tagged(:gen1_emeter, status, channel, online),
    do: parse_gen1_emeter(status, channel, online)

  defp parse_tagged(:gen1_sensor, status, _channel, online),
    do: parse_gen1_sensor(status, online)

  defp gen1_channel_present?(list, channel) when is_list(list) and channel >= 0,
    do: length(list) > channel

  defp gen1_channel_present?(_, _), do: false

  @doc ~S|Normalize the v2 API's gen strings ("G1".."G4") to integers.|
  @spec gen_to_int(String.t() | integer() | term()) :: integer() | nil
  def gen_to_int("G" <> rest) do
    case Integer.parse(rest) do
      {n, ""} -> n
      _ -> nil
    end
  end

  def gen_to_int(n) when is_integer(n), do: n
  def gen_to_int(_), do: nil

  # A caller who knows what the device is — a Shelly 2.5 in roller mode
  # reports `relays` AND `rollers` with no in-payload signal of its mode —
  # can say so with `extra: %{component: "cover"}`. This selects the
  # parser; merging `extra` afterwards only ever relabelled the answer,
  # so the documented workaround produced an open blind still reported as
  # closed, now stamped "cover" and therefore believed.
  defp forced_tag(extra, status, channel) do
    case Map.get(extra, :component) do
      nil -> nil
      component -> matching_tag(component, status, channel)
    end
  end

  defp matching_tag(component, status, channel) do
    forced_candidates()
    |> Enum.filter(fn {name, _tag} -> name == component end)
    |> Enum.find_value(fn {_name, tag} -> if tag_applies?(tag, status, channel), do: tag end)
  end

  defp forced_candidates do
    [
      {"cover", :gen1_roller},
      {"cover", :cover},
      {"relay", :gen1_relay},
      {"switch", :switch},
      {"light", :gen1_light},
      {"light", :light},
      {"em", :gen1_emeter},
      {"em", :em1},
      {"em", :em}
    ]
  end

  defp tag_applies?(:gen1_roller, status, channel),
    do: gen1_channel_present?(status["rollers"], channel)

  defp tag_applies?(:gen1_relay, status, channel),
    do: gen1_channel_present?(status["relays"], channel)

  defp tag_applies?(:gen1_light, status, channel),
    do: gen1_channel_present?(status["lights"], channel)

  defp tag_applies?(:gen1_emeter, status, channel),
    do: gen1_channel_present?(status["emeters"], channel)

  defp tag_applies?(:em, status, channel), do: channel == 0 and is_map(status["em:0"])

  defp tag_applies?(tag, status, channel) do
    Enum.any?(@rpc_components, fn {prefix, candidate, _component} ->
      candidate == tag and is_map(status["#{prefix}:#{channel}"])
    end)
  end

  ## Total accessors ------------------------------------------------------
  #
  # Device payloads are JSON from a network, so any key can hold anything.
  # `parse/4` promises a status for every input, and these keep that
  # promise: a scalar where a map was expected reads as absent rather than
  # raising in the caller's process.

  defp as_map(value) when is_map(value), do: value
  defp as_map(_value), do: %{}

  defp as_list(value) when is_list(value), do: value
  defp as_list(_value), do: []

  # get_in/2 for payloads: any non-map link in the chain means "absent".
  defp dig(value, keys), do: Enum.reduce(keys, value, &fetch_key/2)

  defp fetch_key(key, value) when is_map(value), do: Map.get(value, key)
  defp fetch_key(_key, _value), do: nil

  defp at(list, index), do: list |> as_list() |> Enum.at(index) |> as_map()

  ## Gen2+ components -----------------------------------------------------

  defp parse_switch(status, channel, online) do
    sw = as_map(status["switch:#{channel}"])

    rpc_common(status, online, channel)
    |> Map.merge(%{
      on: output_state(sw["output"]),
      watts: to_float(sw["apower"]),
      voltage: opt_float(sw["voltage"]),
      current: opt_float(sw["current"]),
      energy_wh: opt_float(dig(sw, ["aenergy", "total"])),
      temp_c: opt_float(dig(sw, ["temperature", "tC"])),
      source: opt_string(sw["source"]),
      metered: is_number(sw["apower"]),
      component: "switch"
    })
  end

  defp parse_cover(status, channel, online) do
    cover = as_map(status["cover:#{channel}"])

    rpc_common(status, online, channel)
    |> Map.merge(%{
      on: cover_state(cover),
      watts: to_float(cover["apower"]),
      voltage: opt_float(cover["voltage"]),
      current: opt_float(cover["current"]),
      energy_wh: opt_float(dig(cover, ["aenergy", "total"])),
      temp_c: opt_float(dig(cover, ["temperature", "tC"])),
      source: opt_string(cover["source"]),
      metered: is_number(cover["apower"]),
      component: "cover"
    })
  end

  defp parse_light(status, channel, online) do
    light = as_map(status["light:#{channel}"])

    rpc_common(status, online, channel)
    |> Map.merge(%{
      on: output_state(light["output"]),
      watts: to_float(light["apower"]),
      voltage: opt_float(light["voltage"]),
      current: opt_float(light["current"]),
      energy_wh: opt_float(dig(light, ["aenergy", "total"])),
      temp_c: opt_float(dig(light, ["temperature", "tC"])),
      source: opt_string(light["source"]),
      metered: is_number(light["apower"]),
      component: "light"
    })
  end

  # PM Mini class: measures a circuit, cannot switch it. `on` is
  # meaningless — kept false; the data is the wattage.
  defp parse_pm1(status, channel, online) do
    pm = as_map(status["pm1:#{channel}"])

    rpc_common(status, online, channel)
    |> Map.merge(%{
      on: false,
      watts: to_float(pm["apower"]),
      voltage: opt_float(pm["voltage"]),
      current: opt_float(pm["current"]),
      energy_wh: opt_float(dig(pm, ["aenergy", "total"])),
      metered: is_number(pm["apower"]),
      component: "pm"
    })
  end

  # Pro 3EM single-phase channels.
  defp parse_em1(status, channel, online) do
    em = as_map(status["em1:#{channel}"])

    rpc_common(status, online, channel)
    |> Map.merge(%{
      on: false,
      watts: to_float(em["act_power"] || em["apower"]),
      voltage: opt_float(em["voltage"]),
      current: opt_float(em["current"]),
      energy_wh:
        opt_float(dig(em, ["aenergy", "total"])) ||
          opt_float(dig(status, ["em1data:#{channel}", "total_act_energy"])),
      metered: is_number(em["act_power"] || em["apower"]),
      component: "em"
    })
  end

  # Pro 3EM three-phase aggregate.
  defp parse_em(status, online) do
    em = as_map(status["em:0"])

    rpc_common(status, online, 0)
    |> Map.merge(%{
      on: false,
      watts: to_float(em["total_act_power"]),
      current: opt_float(em["total_current"]),
      energy_wh: opt_float(dig(status, ["emdata:0", "total_act"])),
      metered: is_number(em["total_act_power"]),
      component: "em"
    })
  end

  defp rpc_common(status, online, channel) do
    wifi = as_map(status["wifi"])
    input = as_map(status["input:#{channel}"])

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

  # A component can arrive without its state key: websocket deltas carry
  # only what changed, so `%{"switch:0" => %{"apower" => 15.0}}` says
  # nothing about the relay. `nil` means "unknown" — synthesizing `false`
  # here told callers a running boiler was off.
  defp output_state(true), do: true
  defp output_state(false), do: false
  defp output_state(_absent), do: nil

  # Position is the honest signal when the cover reports one: "stopped"
  # covers both a cover halted mid-travel and an uncalibrated one that
  # says "stopped" forever. Falls back to the state vocabulary.
  defp cover_state(cover) do
    case numeric(cover["current_pos"]) do
      position when is_number(position) ->
        position > 0

      _ ->
        case cover["state"] do
          "open" -> true
          "opening" -> true
          "closing" -> true
          state when state in ["closed", "close"] -> false
          # "stopped"/"calibrating" describe the motor, not the blind —
          # and an uncalibrated cover says "stopped" forever.
          _ -> nil
        end
    end
  end

  ## Gen1 arrays -----------------------------------------------------------

  defp parse_gen1_relay(status, channel, online) do
    relay = at(status["relays"], channel)
    meter = gen1_meter(status["meters"], channel)

    gen1_common(status, channel, online)
    |> Map.merge(%{
      on: output_state(relay["ison"]),
      watts: to_float(meter && meter["power"]),
      # Gen1 relay energy counters count Watt-minutes, not Wh.
      energy_wh: watt_minutes_to_wh(meter && meter["total"]),
      source: opt_string(relay["source"]),
      metered: is_number(meter && meter["power"]),
      component: "relay"
    })
  end

  defp parse_gen1_light(status, channel, online) do
    light = at(status["lights"], channel)
    meter = gen1_meter(status["meters"], channel)

    gen1_common(status, channel, online)
    |> Map.merge(%{
      on: output_state(light["ison"]),
      watts: to_float(meter && meter["power"]),
      energy_wh: watt_minutes_to_wh(meter && meter["total"]),
      metered: is_number(meter && meter["power"]),
      component: "light"
    })
  end

  defp parse_gen1_roller(status, channel, online) do
    roller = at(status["rollers"], channel)
    meter = gen1_meter(status["meters"], channel)

    watts = roller["power"] || (meter && meter["power"])

    gen1_common(status, channel, online)
    |> Map.merge(%{
      on: roller_open?(roller),
      watts: to_float(watts),
      energy_wh: watt_minutes_to_wh(meter && meter["total"]),
      metered: is_number(watts),
      component: "cover"
    })
  end

  defp parse_gen1_emeter(status, channel, online) do
    emeter = at(status["emeters"], channel)

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

  # The original Shelly 2 drives two relays through a single meter, so a
  # lone meter covers whichever channel asked for it.
  # Gen1 devices mark a reading they could not take with is_valid: false;
  # reporting it as a measurement claims data that was never collected.
  defp valid_reading?(%{"is_valid" => false}), do: false
  defp valid_reading?(_reading), do: true

  defp gen1_meter(meters, channel) when is_list(meters) do
    case Enum.at(meters, channel) do
      nil -> if length(meters) == 1, do: valid_meter(List.first(meters))
      meter -> valid_meter(meter)
    end
  end

  defp gen1_meter(_meters, _channel), do: nil

  defp valid_meter(meter) do
    meter = as_map(meter)
    if valid_reading?(meter), do: meter, else: %{}
  end

  # Gen1 rollers report "open" | "close" | "stop"; when calibrated,
  # current_pos (0..100) is the reliable openness signal.
  defp roller_open?(%{"current_pos" => position}) when is_number(position) and position >= 0,
    do: position > 0

  defp roller_open?(%{"state" => "open"}), do: true
  defp roller_open?(%{"state" => state}) when state in ["close", "closed"], do: false
  # "stop"/"stopped"/"calibrating" say where the motor is, not where the
  # blind is — and Gen2 covers answer `true` for exactly these, so a
  # confident `false` here made the generations contradict each other.
  defp roller_open?(_roller), do: nil

  defp gen1_temperature(status) do
    tmp = as_map(status["tmp"])

    if valid_reading?(tmp) do
      opt_float(tmp["tC"] || tmp["value"] || numeric(status["temperature"]))
    else
      nil
    end
  end

  defp gen1_common(status, channel, online) do
    wifi = as_map(status["wifi_sta"])
    input = at(status["inputs"], channel)

    %{
      online: online,
      on: false,
      watts: 0.0,
      voltage: opt_float(status["voltage"]),
      current: nil,
      energy_wh: nil,
      temp_c: gen1_temperature(status),
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
  defp light_family_key(status, channel) do
    Enum.find(
      ["cct:#{channel}", "rgb:#{channel}", "rgbw:#{channel}", "rgbcct:#{channel}"],
      fn key ->
        is_map(status[key])
      end
    )
  end

  defp parse_light_family(status, channel, online) do
    light = as_map(status[light_family_key(status, channel)])

    rpc_common(status, online, channel)
    |> Map.merge(%{
      on: output_state(light["output"]),
      watts: to_float(light["apower"]),
      voltage: opt_float(light["voltage"]),
      current: opt_float(light["current"]),
      energy_wh: opt_float(dig(light, ["aenergy", "total"])),
      source: opt_string(light["source"]),
      metered: is_number(light["apower"]),
      component: "light"
    })
  end

  # Flood / smoke sensors: "on" = alarm ringing. Honest and useful.
  defp parse_alarm(status, kind, channel, online) do
    sensor = as_map(status["#{kind}:#{channel}"])

    # A delta naming the component without its alarm key says nothing
    # about the alarm. Reporting `false` there tells a consumer the smoke
    # detector stopped — see output_state/1.
    rpc_common(status, online, channel)
    |> Map.merge(%{on: output_state(sensor["alarm"]), component: kind})
  end

  defp parse_presence(status, channel, online) do
    presence = as_map(status["presence:#{channel}"])

    detected =
      case {numeric(presence["num_objects"]), presence["presence"]} do
        {count, _} when is_number(count) -> count > 0
        {_, flag} when is_boolean(flag) -> flag
        _ -> nil
      end

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
    volt = as_map(status["voltmeter:#{channel}"])

    rpc_common(status, online, channel)
    |> Map.merge(%{voltage: opt_float(volt["voltage"]), component: "sensor"})
  end

  # Gen1 battery sensors (H&T, Flood, Smoke, Door/Window, Motion) have
  # tmp/hum/bat/alarm keys and no actuator arrays.
  @gen1_sensor_maps ~w(tmp hum bat sensor)
  @gen1_sensor_flags ~w(flood smoke motion)

  defp gen1_sensor?(status) do
    sensor_shaped? =
      Enum.any?(@gen1_sensor_maps, &is_map(status[&1])) or
        Enum.any?(@gen1_sensor_flags, &is_boolean(status[&1]))

    sensor_shaped? and not gen1_actuator?(status)
  end

  # A device with an actuator array is that actuator, not a sensor —
  # even when it also reports temperature or a flood flag.
  defp gen1_actuator?(status) do
    Enum.any?(@gen1_arrays, fn {key, _tag, _component} -> is_list(status[key]) end)
  end

  defp parse_gen1_sensor(status, online) do
    on =
      cond do
        is_boolean(status["flood"]) -> status["flood"]
        is_boolean(status["smoke"]) -> status["smoke"]
        is_boolean(status["motion"]) -> status["motion"]
        is_boolean(dig(status, ["sensor", "motion"])) -> dig(status, ["sensor", "motion"])
        # Door/Window reports state under `sensor`. Without this an open
        # door read as closed, because the catch-all said false.
        is_map(status["sensor"]) -> gen1_contact_open?(status["sensor"])
        true -> nil
      end

    gen1_common(status, 0, online)
    |> Map.merge(%{on: on, component: gen1_sensor_component(status)})
  end

  defp gen1_sensor_component(status) do
    cond do
      is_boolean(status["flood"]) -> "flood"
      is_boolean(status["smoke"]) -> "smoke"
      is_boolean(status["motion"]) -> "presence"
      is_boolean(dig(status, ["sensor", "motion"])) -> "presence"
      true -> "sensor"
    end
  end

  # Door/Window: `state` is "open"/"close", older units report `is_valid`
  # alongside. Anything unrecognized stays unknown rather than "closed".
  defp gen1_contact_open?(%{"is_valid" => false}), do: nil
  defp gen1_contact_open?(%{"state" => "open"}), do: true
  defp gen1_contact_open?(%{"state" => state}) when state in ["close", "closed"], do: false
  defp gen1_contact_open?(_sensor), do: nil

  # Cross-cutting fields that ride ALONGSIDE the main component:
  # battery (devicepower / gen1 bat) and sensor temperature when the
  # component itself carried none.
  defp enrich(parsed, status, channel) do
    battery =
      opt_int(dig(status, ["devicepower:#{channel}", "battery", "percent"])) ||
        opt_int(dig(status, ["devicepower:0", "battery", "percent"])) ||
        opt_int(dig(status, ["bat", "value"]))

    # Only this channel's readings, plus the device-wide Gen1 ones. Falling
    # back to channel 0 gave every channel of a multi-channel device the
    # first channel's temperature as its own.
    temp =
      parsed[:temp_c] ||
        opt_float(dig(status, ["temperature:#{channel}", "tC"])) ||
        opt_float(dig(status, ["tmp", "tC"])) ||
        opt_float(dig(status, ["tmp", "value"]))

    humidity =
      opt_float(dig(status, ["humidity:#{channel}", "rh"])) ||
        opt_float(dig(status, ["hum", "value"]))

    parsed
    |> Map.put(:battery, battery)
    |> Map.put(:temp_c, temp)
    |> Map.put(:humidity, humidity)
  end

  @doc """
  Which component the payload carries for this channel ("switch",
  "cover", "light", "pm", "em", "relay", "flood", "smoke", "presence",
  "sensor") or nil when none — use it to guard event deltas against a
  device's known component before applying `parse/4`.
  """
  @spec component_of(map() | term(), non_neg_integer()) :: String.t() | nil
  def component_of(status, channel) when is_map(status) do
    case component_tag(status, channel) do
      nil -> nil
      tag -> tag_component(tag, status)
    end
  end

  def component_of(_status, _channel), do: nil

  defp unknown_status(raw, online) do
    %{
      # Nothing in this payload spoke for the channel, so its state is
      # not known — the same stance every named component takes.
      on: nil,
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
      humidity: nil,
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
