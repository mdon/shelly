defmodule Shelly.AgreementTest do
  @moduledoc """
  `parse/4`, `has_component?/2` and `component_of/2` each decide, for a
  payload and a channel, what the device is. Three separate decisions
  that must give one answer — and drift between them is invisible: the
  consumer pattern the docs recommend (store the parsed component, guard
  later events with `component_of/2`) silently drops every event when
  they disagree.

  This matrix is what would have caught the Gen1 alarm naming, the 3EM
  phases parsing as a relay, and out-of-range channels, in one test.
  """

  use ExUnit.Case, async: true

  alias Shelly.Status

  # {label, payload, channel, expected component or nil}
  @cases [
    {"gen2 switch", %{"switch:0" => %{"output" => true, "apower" => 12.0}}, 0, "switch"},
    {"gen2 switch ch1", %{"switch:1" => %{"output" => false}}, 1, "switch"},
    {"gen2 cover", %{"cover:0" => %{"state" => "open", "current_pos" => 60}}, 0, "cover"},
    {"dimmer", %{"light:0" => %{"output" => true}}, 0, "light"},
    {"cct light", %{"cct:0" => %{"output" => true}}, 0, "light"},
    {"rgbw light", %{"rgbw:0" => %{"output" => false}}, 0, "light"},
    {"pm1", %{"pm1:0" => %{"apower" => 40.5}}, 0, "pm"},
    {"em1 phase b", %{"em1:1" => %{"act_power" => 230.0}}, 1, "em"},
    {"em aggregate", %{"em:0" => %{"total_act_power" => 900.0}}, 0, "em"},
    {"flood alarm", %{"flood:0" => %{"alarm" => true}}, 0, "flood"},
    {"smoke alarm", %{"smoke:0" => %{"alarm" => false}}, 0, "smoke"},
    {"presence", %{"presence:0" => %{"num_objects" => 2}}, 0, "presence"},
    {"h&t sensor", %{"temperature:0" => %{"tC" => 21.0}, "humidity:0" => %{"rh" => 44.0}}, 0,
     "sensor"},
    {"voltmeter", %{"voltmeter:0" => %{"voltage" => 3.3}}, 0, "sensor"},
    {"gen1 relay", %{"relays" => [%{"ison" => true}]}, 0, "relay"},
    {"gen1 light", %{"lights" => [%{"ison" => true}]}, 0, "light"},
    {"gen1 roller", %{"rollers" => [%{"state" => "open", "current_pos" => 100}]}, 0, "cover"},
    {"gen1 emeter", %{"emeters" => [%{"power" => 120.0}]}, 0, "em"},
    {"gen1 flood sensor", %{"flood" => true, "bat" => %{"value" => 90}}, 0, "flood"},
    {"gen1 smoke sensor", %{"smoke" => false, "bat" => %{"value" => 90}}, 0, "smoke"},
    {"gen1 motion sensor", %{"motion" => true, "bat" => %{"value" => 90}}, 0, "presence"},
    {"gen1 h&t", %{"tmp" => %{"tC" => 20.0}, "hum" => %{"value" => 55.0}}, 0, "sensor"},
    {"gen1 door/window", %{"sensor" => %{"state" => "open"}, "bat" => %{"value" => 80}}, 0,
     "sensor"},

    # Nothing for this channel: all three must say so.
    {"sys-only delta", %{"sys" => %{"uptime" => 900}}, 0, nil},
    {"input-only delta", %{"input:0" => %{"state" => true}}, 0, nil},
    {"channel 1 of a one-relay device", %{"relays" => [%{"ison" => true}]}, 1, nil},
    {"channel 2 of a two-switch device", %{"switch:0" => %{}, "switch:1" => %{}}, 2, nil}
  ]

  describe "parse/4, has_component?/2 and component_of/2 agree" do
    for {label, payload, channel, expected} <- @cases do
      test "#{label}" do
        payload = unquote(Macro.escape(payload))
        channel = unquote(channel)
        expected = unquote(expected)

        assert Status.component_of(payload, channel) == expected,
               "component_of disagreed with the expected component"

        assert Status.has_component?(payload, channel) == is_binary(expected),
               "has_component? disagreed with component_of"

        parsed = Status.parse(payload, channel, true)

        if expected do
          assert parsed.component == expected,
                 "parse reported #{inspect(parsed.component)}, component_of said #{inspect(expected)} — " <>
                   "a consumer guarding one against the other would drop this device's events"
        else
          assert parsed.component == "unknown",
                 "parse invented a #{inspect(parsed.component)} for a channel that carries nothing"
        end
      end
    end
  end

  describe "precedence between components sharing a channel" do
    # Actuators outrank meters. This reclassifies 12 light-family/meter
    # pairings relative to 0.2.x, where parse/4 answered with the meter
    # and component_of/2 answered with the light — i.e. they disagreed.
    # No known device emits these, but the resolution is a decision now,
    # so it gets pinned rather than rediscovered.
    for light <- ["cct", "rgb", "rgbw", "rgbcct"],
        {meter_key, meter} <- [
          {"pm1:0", %{"apower" => 5.0}},
          {"em1:0", %{"act_power" => 5.0}},
          {"em:0", %{"total_act_power" => 5.0}}
        ] do
      test "#{light} outranks #{meter_key}" do
        payload = %{
          unquote(meter_key) => unquote(Macro.escape(meter)),
          "#{unquote(light)}:0" => %{"output" => true}
        }

        assert Status.component_of(payload, 0) == "light"
        assert Status.parse(payload, 0, true).component == "light"
        assert Status.parse(payload, 0, true).on == true
      end
    end

    test "a meter still wins when no actuator is present" do
      assert Status.component_of(%{"pm1:0" => %{"apower" => 5.0}}, 0) == "pm"
      assert Status.component_of(%{"em1:0" => %{"act_power" => 5.0}}, 0) == "em"
    end

    test "a sensor never displaces the actuator on its channel" do
      payload = %{"switch:0" => %{"output" => true}, "voltmeter:0" => %{"voltage" => 3.3}}

      assert Status.component_of(payload, 0) == "switch"
      assert Status.parse(payload, 0, true).on == true
      # Enrichment carries battery, temperature and humidity across
      # components — not voltage, which belongs to the component reporting it.
      assert Status.parse(payload, 0, true).voltage == nil
    end

    test "between two sensors, the named one wins and keeps its reading" do
      payload = %{"temperature:0" => %{"tC" => 20.0}, "voltmeter:0" => %{"voltage" => 3.3}}

      assert Status.component_of(payload, 0) == "sensor"
      parsed = Status.parse(payload, 0, true)
      assert parsed.voltage == 3.3
      assert parsed.temp_c == 20.0
    end
  end

  describe "the 3EM shape that dispatch order used to swallow" do
    # One relay, three emeters: channels 1 and 2 carry real power and
    # were parsed as an unmetered relay at 0 W.
    @three_em %{
      "relays" => [%{"ison" => false}],
      "emeters" => [
        %{"power" => 100.0, "voltage" => 230.0, "total" => 1000.0},
        %{"power" => 200.0, "voltage" => 231.0, "total" => 2000.0},
        %{"power" => 300.0, "voltage" => 229.0, "total" => 3000.0}
      ]
    }

    test "the relay channel is the relay" do
      parsed = Status.parse(@three_em, 0, true)
      assert parsed.component == "relay"
      assert Status.component_of(@three_em, 0) == "relay"
    end

    test "the other phases report their power, not a phantom relay" do
      for {channel, watts} <- [{1, 200.0}, {2, 300.0}] do
        parsed = Status.parse(@three_em, channel, true)

        assert parsed.component == "em"
        assert parsed.watts == watts
        assert parsed.metered
        assert Status.component_of(@three_em, channel) == "em"
      end
    end
  end
end
