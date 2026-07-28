defmodule Shelly.RateGate do
  @moduledoc """
  Per-account rate gate for Shelly Cloud traffic. The cloud allows
  ~1 request/second/account and returns 429 for anything faster — and
  polling, control commands and one-off calls all draw from the same
  budget, so every call should flow through one gate.

  Callers reserve the next free slot for their key and sleep in their
  own process until it arrives; the gate itself never blocks:

      Shelly.RateGate.run({server, auth_key}, fn -> Req.request(...) end)

  Start it in your supervision tree:

      children = [Shelly.RateGate, ...]

  When the gate isn't running (scripts, tests), calls pass straight
  through unpaced.
  """

  use GenServer

  @default_interval_ms 1200
  @max_wait_ms 60_000

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Run `fun` in the calling process, no earlier than the key's next free
  slot. `key` is any term identifying the budget (typically
  `{server, auth_key}` or an account id).
  """
  def run(key, fun, gate \\ __MODULE__) when is_function(fun, 0) do
    case GenServer.whereis(gate) do
      nil ->
        fun.()

      _pid ->
        wait = GenServer.call(gate, {:reserve, :erlang.phash2(key)}, @max_wait_ms + 5_000)
        if wait > 0, do: Process.sleep(wait)
        fun.()
    end
  end

  @impl true
  def init(opts),
    do: {:ok, %{interval: Keyword.get(opts, :interval_ms, @default_interval_ms), slots: %{}}}

  @impl true
  def handle_call({:reserve, key}, _from, state) do
    now = System.monotonic_time(:millisecond)
    last_slot = Map.get(state.slots, key, now - state.interval)
    slot = now |> max(last_slot + state.interval) |> min(now + @max_wait_ms)
    {:reply, slot - now, %{state | slots: Map.put(state.slots, key, slot)}}
  end
end
