defmodule Shelly.RateGateTest do
  use ExUnit.Case, async: true

  alias Shelly.RateGate

  test "passes straight through when the gate is not running" do
    assert RateGate.run(:any, fn -> :ran end, :no_such_gate) == :ran
  end

  test "first call per key runs immediately, second is spaced" do
    {:ok, gate} = RateGate.start_link(name: nil, interval_ms: 120)

    t0 = System.monotonic_time(:millisecond)
    assert RateGate.run(:key, fn -> :one end, gate) == :one
    assert RateGate.run(:key, fn -> :two end, gate) == :two
    elapsed = System.monotonic_time(:millisecond) - t0

    assert elapsed >= 100, "second call should have waited ~interval, waited #{elapsed}ms"
  end

  test "different keys do not pace each other" do
    {:ok, gate} = RateGate.start_link(name: nil, interval_ms: 5_000)

    t0 = System.monotonic_time(:millisecond)
    RateGate.run(:a, fn -> :ok end, gate)
    RateGate.run(:b, fn -> :ok end, gate)
    assert System.monotonic_time(:millisecond) - t0 < 1_000
  end

  test "backlog past the cap returns {:error, :throttled} instead of bursting" do
    {:ok, gate} = RateGate.start_link(name: nil, interval_ms: 30_000)

    # slot 1: immediate; slot 2: +30s; slot 3: +60s (at cap); slot 4: rejected
    assert {:ok, _} = GenServer.call(gate, {:reserve, :k})
    assert {:ok, _} = GenServer.call(gate, {:reserve, :k})
    assert {:ok, _} = GenServer.call(gate, {:reserve, :k})
    assert {:error, :throttled} = GenServer.call(gate, {:reserve, :k})
  end

  test "distinct composite keys stay distinct (no phash collisions by construction)" do
    {:ok, gate} = RateGate.start_link(name: nil, interval_ms: 10_000)

    assert {:ok, 0} = GenServer.call(gate, {:reserve, {"server-a", "key-1"}})
    assert {:ok, 0} = GenServer.call(gate, {:reserve, {"server-b", "key-2"}})
  end
end
