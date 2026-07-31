defmodule Shelly.EventsDispatchTest do
  @moduledoc """
  End-to-end frame handling: what the handler actually receives for the
  frames Shelly sends. The decimal-id bug lived precisely here, between a
  well-tested `normalize_device_id/1` and a well-tested parser, in the
  step nothing asserted.
  """

  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  defp state(handler),
    do: %{handler: handler, label: "shelly-74-eu.shelly.cloud", attempt: 0, connected_at: nil}

  defp send_frame(payload) do
    parent = self()
    handler = fn event -> send(parent, {:event, event}) end

    {:ok, _state} =
      Shelly.Events.handle_frame({:text, Jason.encode!(payload)}, state(handler))

    :ok
  end

  test "a status frame reaches the handler with a usable device id" do
    # The id as the live socket sends it: decimal, in a string.
    send_frame(%{
      "event" => "Shelly:StatusOnChange",
      "device" => %{"id" => "79530338915136"},
      "status" => %{"switch:0" => %{"output" => true, "apower" => 2.4}}
    })

    assert_received {:event, {:status, "485519999340", status}}
    assert status["switch:0"]["output"] == true
  end

  test "a Gen1 device's id survives the same trip" do
    send_frame(%{
      "event" => "Shelly:StatusOnChange",
      "device" => %{"id" => "12133370"},
      "status" => %{"relays" => [%{"ison" => true}]}
    })

    assert_received {:event, {:status, "b923fa", _status}}
  end

  test "online events carry a boolean, and an unreadable flag is not 'offline'" do
    send_frame(%{
      "event" => "Shelly:Online",
      "device" => %{"id" => "485519999340"},
      "online" => 1
    })

    assert_received {:event, {:online, "485519999340", true}}

    send_frame(%{
      "event" => "Shelly:Online",
      "device" => %{"id" => "485519999340"},
      "online" => 0
    })

    assert_received {:event, {:online, "485519999340", false}}

    # No readable flag: a missing field is not evidence the device is down.
    capture_log(fn ->
      send_frame(%{"event" => "Shelly:Online", "device" => %{"id" => "485519999340"}})
    end)

    refute_received {:event, {:online, _, _}}
  end

  test "unrecognized events reach the handler as :other" do
    send_frame(%{"event" => "Shelly:Something", "device" => %{"id" => "485519999340"}})
    assert_received {:event, {:other, %{"event" => "Shelly:Something"}}}
  end

  test "drops are logged rather than vanishing" do
    log =
      capture_log(fn ->
        send_frame(%{"event" => "Shelly:StatusOnChange", "status" => %{"switch:0" => %{}}})
      end)

    assert log =~ "dropped StatusOnChange"
    refute_received {:event, _}
  end

  test "a scalar device value does not kill the socket" do
    log =
      capture_log(fn ->
        send_frame(%{
          "event" => "Shelly:StatusOnChange",
          "device" => "not-a-map",
          "status" => %{"switch:0" => %{}}
        })
      end)

    assert log =~ "dropped"
  end

  test "a handler that raises does not take the socket down with it" do
    log =
      capture_log(fn ->
        {:ok, _state} =
          Shelly.Events.handle_frame(
            {:text,
             Jason.encode!(%{
               "event" => "Shelly:StatusOnChange",
               "device" => %{"id" => "485519999340"},
               "status" => %{}
             })},
            state(fn _event -> raise "handler blew up" end)
          )
      end)

    assert log =~ "handler crashed"
  end

  test "undecodable and non-text frames are ignored" do
    handler = fn event -> send(self(), {:event, event}) end

    assert {:ok, _} = Shelly.Events.handle_frame({:text, "not json"}, state(handler))
    assert {:ok, _} = Shelly.Events.handle_frame({:binary, <<1, 2, 3>>}, state(handler))
    refute_received {:event, _}
  end
end
