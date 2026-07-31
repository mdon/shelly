defmodule Shelly.RateGate do
  @moduledoc """
  Per-account rate gate for Shelly Cloud traffic. The cloud allows
  ~1 request/second/account and returns 429 for anything faster — and
  polling, control commands and one-off calls all draw from the same
  budget, so every call should flow through one gate.

  Callers reserve the next free slot for their key and sleep in their
  own process until it arrives; the gate itself never blocks. When the
  backlog for a key exceeds one minute, callers are rejected with
  `{:error, :throttled}` instead of being queued into a burst:

      Shelly.RateGate.run({server, auth_key}, fn -> Req.request(...) end)

  Start it in your supervision tree:

      children = [Shelly.RateGate, ...]

  When the gate isn't running (scripts, tests), calls pass straight
  through unpaced.
  """

  use GenServer

  @default_interval_ms 1200
  @max_backlog_ms 60_000

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Run `fun` in the calling process, no earlier than the key's next free
  slot. `key` is any term identifying the budget (typically
  `{server, auth_key}` or an account id).

  Returns `fun`'s result, or `{:error, :throttled}` when the key's
  backlog already exceeds one minute.
  """
  @spec run(term(), (-> result), GenServer.server()) :: result | {:error, :throttled}
        when result: var
  def run(key, fun, gate \\ __MODULE__) when is_function(fun, 0) do
    case GenServer.whereis(gate) do
      nil -> fun.()
      _pid -> run_paced(key, fun, gate)
    end
  end

  defp run_paced(key, fun, gate) do
    case GenServer.call(gate, {:reserve, key}, @max_backlog_ms + 5_000) do
      {:ok, wait} ->
        if wait > 0, do: Process.sleep(wait)
        fun.()

      {:error, :throttled} ->
        {:error, :throttled}
    end
  catch
    # The gate can stop between the lookup and the call. Unpaced is the
    # documented behaviour when it isn't running; exiting the caller's
    # process is not.
    :exit, {reason, _call} when reason in [:noproc, :normal, :shutdown] ->
      fun.()
  end

  @impl true
  def init(opts) do
    interval =
      case Keyword.get(opts, :interval_ms, @default_interval_ms) do
        ms when is_integer(ms) and ms > 0 ->
          ms

        invalid ->
          raise ArgumentError,
                "Shelly.RateGate :interval_ms must be a positive integer, got: " <>
                  "#{inspect(invalid)}. Zero or negative disables pacing, which is how you get 429s."
      end

    {:ok, %{interval: interval, slots: %{}}}
  end

  @impl true
  def handle_call({:reserve, key}, _from, state) do
    now = System.monotonic_time(:millisecond)
    last_slot = Map.get(state.slots, key, now - state.interval)
    slot = max(now, last_slot + state.interval)

    if slot - now > @max_backlog_ms do
      # Refuse to stack a burst behind the cap — the caller backs off.
      {:reply, {:error, :throttled}, state}
    else
      slots = state.slots |> prune(now, state.interval) |> Map.put(key, slot)
      {:reply, {:ok, slot - now}, %{state | slots: slots}}
    end
  end

  # Drop keys whose slot is long past — keeps the map bounded with
  # dynamic keys.
  defp prune(slots, now, interval) do
    cutoff = now - interval * 2

    if map_size(slots) > 100 do
      :maps.filter(fn _k, slot -> slot >= cutoff end, slots)
    else
      slots
    end
  end
end
