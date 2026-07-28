defmodule Shelly.StatusTest do
  use ExUnit.Case, async: true

  alias Shelly.Status

  # Payloads modelled on real captures (Plus 1PM, Shelly 1 Gen4, Pro 3)
  # and the official component docs.

  @gen2_metered_switch %{
    "switch:0" => %{
      "output" => true,
      "apower" => 2.4,
      "voltage" => 230.4,
      "current" => 0.016,
      "aenergy" => %{"total" => 2_265_635.767},
      "temperature" => %{"tC" => 55.87},
      "source" => "SHC"
    },
    "input:0" => %{"id" => 0, "state" => false},
    "wifi" => %{"rssi" => -66},
    "code" => "SNSW-001P16EU"
  }

  @gen4_unmetered_switch %{
    "switch:0" => %{"id" => 0, "output" => false, "source" => "init"},
    "wifi" => %{"rssi" => -55}
  }

  describe "switch parsing" do
    test "metered Gen2 switch: full field extraction" do
      parsed = Status.parse(@gen2_metered_switch, 0, true)

      assert parsed.on
      assert parsed.online
      assert parsed.watts == 2.4
      assert parsed.voltage == 230.4
      assert parsed.energy_wh == 2_265_635.767
      assert parsed.temp_c == 55.87
      assert parsed.rssi == -66
      assert parsed.source == "SHC"
      assert parsed.model == "SNSW-001P16EU"
      assert parsed.component == "switch"
      assert parsed.metered
    end

    test "unmetered switch (Gen4/Pro 3): metered false, watts 0.0" do
      parsed = Status.parse(@gen4_unmetered_switch, 0, true)

      refute parsed.on
      refute parsed.metered
      assert parsed.watts == 0.0
      assert parsed.voltage == nil
      assert parsed.component == "switch"
    end

    test "apower present but nil does not count as metered" do
      status = %{"switch:0" => %{"output" => true, "apower" => nil}}
      refute Status.parse(status, 0, true).metered
    end

    test "multi-channel dispatch reads the right channel" do
      status = %{
        "switch:0" => %{"output" => false},
        "switch:2" => %{"output" => true},
        "input:2" => %{"state" => true}
      }

      parsed = Status.parse(status, 2, true)
      assert parsed.on
      assert parsed.input_state == true
    end
  end

  describe "metering-only components" do
    test "pm1 reports watts without pretending to switch" do
      status = %{
        "pm1:0" => %{"apower" => 143.7, "voltage" => 229.9, "aenergy" => %{"total" => 10.0}}
      }

      parsed = Status.parse(status, 0, true)

      refute parsed.on
      assert parsed.watts == 143.7
      assert parsed.metered
      assert parsed.component == "pm"
    end

    test "pm1 with missing apower is NOT metered (absent reading ≠ 0 W)" do
      parsed = Status.parse(%{"pm1:0" => %{"voltage" => 230.0}}, 0, true)
      refute parsed.metered
      assert parsed.watts == 0.0
    end

    test "em three-phase aggregate" do
      status = %{"em:0" => %{"total_act_power" => 1234.5, "total_current" => 5.4}}
      parsed = Status.parse(status, 0, true)

      assert parsed.watts == 1234.5
      assert parsed.metered
      assert parsed.component == "em"
    end
  end

  describe "cover, light family, sensors, alarms" do
    test "cover open counts as on" do
      status = %{"cover:0" => %{"state" => "open", "apower" => 50.0}}
      parsed = Status.parse(status, 0, true)
      assert parsed.on
      assert parsed.component == "cover"
      assert parsed.metered
    end

    test "cover closed is off" do
      refute Status.parse(%{"cover:0" => %{"state" => "closed"}}, 0, true).on
    end

    test "cct/rgb/rgbw resolve as light family" do
      for key <- ["cct:0", "rgb:0", "rgbw:0"] do
        parsed = Status.parse(%{key => %{"output" => true}}, 0, true)
        assert parsed.on, "#{key} should be on"
        assert parsed.component == "light"
      end
    end

    test "flood alarm maps to on" do
      assert Status.parse(%{"flood:0" => %{"alarm" => true}}, 0, true).on
      refute Status.parse(%{"flood:0" => %{"alarm" => false}}, 0, true).on
      assert Status.parse(%{"flood:0" => %{"alarm" => true}}, 0, true).component == "flood"
    end

    test "temperature/humidity sensor device with battery enrichment" do
      status = %{
        "temperature:0" => %{"tC" => 21.4},
        "humidity:0" => %{"rh" => 48.0},
        "devicepower:0" => %{"battery" => %{"percent" => 87}}
      }

      parsed = Status.parse(status, 0, true)
      assert parsed.component == "sensor"
      assert parsed.temp_c == 21.4
      assert parsed.battery == 87
    end
  end

  describe "Gen1 payloads" do
    test "relay with meter: Watt-minute counter converted to Wh" do
      status = %{
        "relays" => [%{"ison" => true, "source" => "http"}],
        "meters" => [%{"power" => 95.3, "total" => 6000}],
        "wifi_sta" => %{"rssi" => -70},
        "tmp" => %{"tC" => 22.4}
      }

      parsed = Status.parse(status, 0, true)
      assert parsed.on
      assert parsed.watts == 95.3
      assert parsed.energy_wh == 100.0
      assert parsed.gen == 1
      assert parsed.component == "relay"
      assert parsed.metered
    end

    test "relay without meter is unmetered" do
      parsed = Status.parse(%{"relays" => [%{"ison" => false}]}, 0, true)
      refute parsed.metered
      assert parsed.component == "relay"
    end

    test "gen1 emeter counts real Wh (no conversion)" do
      status = %{"emeters" => [%{"power" => 200.0, "total" => 5000.0, "voltage" => 231.0}]}
      parsed = Status.parse(status, 0, true)
      assert parsed.energy_wh == 5000.0
      assert parsed.component == "em"
    end

    test "gen1 roller uses position when calibrated, state vocabulary otherwise" do
      # calibrated, stopped mid-travel: position wins
      assert Status.parse(%{"rollers" => [%{"state" => "stop", "current_pos" => 40}]}, 0, true).on
      refute Status.parse(%{"rollers" => [%{"state" => "stop", "current_pos" => 0}]}, 0, true).on
      # uncalibrated: only "open" counts (gen1 says open|close|stop)
      assert Status.parse(%{"rollers" => [%{"state" => "open"}]}, 0, true).on
      refute Status.parse(%{"rollers" => [%{"state" => "close"}]}, 0, true).on
    end

    test "gen1 battery sensor (H&T): temp + battery, no actuator" do
      status = %{"tmp" => %{"tC" => 19.5}, "hum" => %{"value" => 60}, "bat" => %{"value" => 74}}
      parsed = Status.parse(status, 0, true)
      assert parsed.component == "sensor"
      assert parsed.temp_c == 19.5
      assert parsed.battery == 74
    end

    test "gen1 flood sensor alarm" do
      parsed = Status.parse(%{"flood" => true, "bat" => %{"value" => 90}}, 0, true)
      assert parsed.on
      assert parsed.component == "flood"
      assert parsed.battery == 90
    end
  end

  describe "partial-delta guards" do
    test "sys-only delta has no component" do
      refute Status.has_component?(%{"sys" => %{"uptime" => 1}}, 0)
      assert Status.component_of(%{"sys" => %{}}, 0) == nil
    end

    test "devicepower-only delta is partial (battery is enrichment, not identity)" do
      delta = %{"devicepower:0" => %{"battery" => %{"percent" => 55}}}
      refute Status.has_component?(delta, 0)
      assert Status.component_of(delta, 0) == nil
    end

    test "component_of distinguishes device classes" do
      assert Status.component_of(@gen2_metered_switch, 0) == "switch"
      assert Status.component_of(%{"cover:0" => %{}}, 0) == "cover"
      assert Status.component_of(%{"relays" => [%{}]}, 0) == "relay"
    end
  end

  describe "robustness" do
    test "unknown payloads degrade with a complete, stable shape" do
      parsed = Status.parse(%{"weird:0" => %{}}, 0, true)
      assert parsed.component == "unknown"
      assert Map.has_key?(parsed, :voltage)
      assert Map.has_key?(parsed, :battery)
      assert parsed.raw == %{"weird:0" => %{}}
    end

    test "non-map status still honours extra" do
      parsed = Status.parse(nil, 0, false, %{model: "X", gen: 3})
      assert parsed.model == "X"
      assert parsed.gen == 3
      refute parsed.online
    end

    test "extra can override with false" do
      parsed = Status.parse(@gen2_metered_switch, 0, true, %{online: false})
      refute parsed.online
    end

    test "negative prices... sorry, negative power (grid export) survives" do
      parsed = Status.parse(%{"switch:0" => %{"output" => true, "apower" => -320.5}}, 0, true)
      assert parsed.watts == -320.5
      assert parsed.metered
    end

    test "gen_to_int handles garbage without raising" do
      assert Status.gen_to_int("G2") == 2
      assert Status.gen_to_int(4) == 4
      assert Status.gen_to_int("GBLE") == nil
      assert Status.gen_to_int("G") == nil
      assert Status.gen_to_int(nil) == nil
    end
  end
end
