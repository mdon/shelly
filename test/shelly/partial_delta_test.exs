defmodule Shelly.PartialDeltaTest do
  @moduledoc """
  A websocket delta can carry a component without its state key. The
  library used to answer `on: false` for those — a confident claim that
  a running relay is off, waved through by both documented guards. On
  price-driven heating, the false OFF is the expensive direction.
  """

  use ExUnit.Case, async: true

  alias Shelly.Status

  test "a switch delta with no output key leaves on unknown, not off" do
    delta = %{"switch:0" => %{"apower" => 15.0}}

    # Both guards still say "this is about the switch on channel 0" —
    # they were never the problem.
    assert Status.has_component?(delta, 0)
    assert Status.component_of(delta, 0) == "switch"

    parsed = Status.parse(delta, 0, true)

    assert parsed.on == nil, "a missing output key must not be reported as off"
    assert parsed.watts == 15.0
    assert parsed.metered
  end

  test "an explicit false is still false" do
    assert Status.parse(%{"switch:0" => %{"output" => false}}, 0, true).on == false
    assert Status.parse(%{"switch:0" => %{"output" => true}}, 0, true).on == true
  end

  test "the same holds for lights and gen1 relays" do
    assert Status.parse(%{"light:0" => %{"apower" => 3.0}}, 0, true).on == nil
    assert Status.parse(%{"relays" => [%{"source" => "http"}]}, 0, true).on == nil
  end

  test "a cover reports position over state vocabulary" do
    # "stopped" is what an uncalibrated cover says forever, and what a
    # cover halted at the closed end says. Position decides.
    assert Status.parse(%{"cover:0" => %{"state" => "stopped", "current_pos" => 0}}, 0, true).on ==
             false

    assert Status.parse(%{"cover:0" => %{"state" => "stopped", "current_pos" => 45}}, 0, true).on ==
             true

    # No position reported: fall back to the vocabulary.
    assert Status.parse(%{"cover:0" => %{"state" => "open"}}, 0, true).on == true
    assert Status.parse(%{"cover:0" => %{"state" => "closed"}}, 0, true).on == false
    assert Status.parse(%{"cover:0" => %{}}, 0, true).on == nil
  end

  test "sensor readings the docs advertise are actually extracted" do
    ht = %{
      "temperature:0" => %{"tC" => 21.4},
      "humidity:0" => %{"rh" => 48.5},
      "devicepower:0" => %{"battery" => %{"percent" => 87}}
    }

    parsed = Status.parse(ht, 0, true)

    assert parsed.temp_c == 21.4
    assert parsed.humidity == 48.5
    assert parsed.battery == 87
  end

  test "add-on sensors on a non-zero channel are not lost" do
    # The Sensor Add-On addresses components by channel; enrichment used
    # to read channel 0 only.
    parsed = Status.parse(%{"temperature:1" => %{"tC" => 30.2}}, 1, true)

    assert parsed.temp_c == 30.2
    assert parsed.component == "sensor"
  end

  test "gen1 door/window reports an open door as on" do
    open = %{"sensor" => %{"state" => "open"}, "bat" => %{"value" => 80}}
    closed = %{"sensor" => %{"state" => "close"}, "bat" => %{"value" => 80}}

    assert Status.parse(open, 0, true).on == true
    assert Status.parse(closed, 0, true).on == false
  end

  test "shelly 2's single shared meter covers both relay channels" do
    two_relays_one_meter = %{
      "relays" => [%{"ison" => true}, %{"ison" => false}],
      "meters" => [%{"power" => 42.0, "total" => 600}]
    }

    assert Status.parse(two_relays_one_meter, 1, true).metered
    assert Status.parse(two_relays_one_meter, 1, true).watts == 42.0
  end

  test "gen1 roller keeps its energy counter" do
    roller = %{
      "rollers" => [%{"state" => "open", "current_pos" => 100}],
      "meters" => [%{"power" => 12.0, "total" => 120}]
    }

    # Watt-minutes -> Wh
    assert Status.parse(roller, 0, true).energy_wh == 2.0
  end

  test "pro 3EM energy comes from the data sibling component" do
    em1 = %{
      "em1:0" => %{"act_power" => 230.0},
      "em1data:0" => %{"total_act_energy" => 12_345.0}
    }

    assert Status.parse(em1, 0, true).energy_wh == 12_345.0
  end
end
