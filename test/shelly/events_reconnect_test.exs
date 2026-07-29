defmodule Shelly.EventsReconnectTest do
  @moduledoc """
  Regression cover for the reconnect loop: an expired token still completes
  the websocket handshake, so a socket that resets its attempt counter on
  connect reconnects forever instead of giving up.
  """

  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  defp state(attrs) do
    Map.merge(
      %{
        handler: fn _ -> :ok end,
        label: "shelly-74-eu.shelly.cloud",
        attempt: 0,
        connected_at: nil
      },
      attrs
    )
  end

  defp now, do: System.monotonic_time(:millisecond)

  test "connecting no longer clears the attempt counter" do
    {:ok, connected} = Shelly.Events.handle_connect(:conn, state(%{attempt: 4}))

    assert connected.attempt == 4
    assert is_integer(connected.connected_at)
  end

  test "a connection dropped seconds after opening keeps counting toward the cap" do
    log =
      capture_log(fn ->
        assert {:ok, _state} =
                 Shelly.Events.handle_disconnect(
                   %{reason: :closed},
                   state(%{attempt: 10, connected_at: now()})
                 )
      end)

    assert log =~ "giving up"
  end

  test "a session that held for a minute earns a fresh set of attempts" do
    capture_log(fn ->
      assert {:reconnect, reconnected} =
               Shelly.Events.handle_disconnect(
                 %{reason: :closed},
                 state(%{attempt: 10, connected_at: now() - 120_000})
               )

      assert reconnected.attempt == 1
      assert reconnected.connected_at == nil
    end)
  end

  test "disconnect reasons never leak the token-carrying URL" do
    log =
      capture_log(fn ->
        Shelly.Events.handle_disconnect(
          %{
            reason: %WebSockex.RequestError{
              code: 401,
              message: "wss://host:6113/shelly/wss/hk_sock?t=secret"
            }
          },
          state(%{attempt: 10, connected_at: now()})
        )
      end)

    refute log =~ "secret"
  end
end
