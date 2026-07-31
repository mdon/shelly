defmodule Shelly.RegressionTest do
  @moduledoc """
  One test per defect that shipped, or nearly shipped, in 0.2.x–0.3.0.

  Three of these were *incomplete* versions of fixes an earlier release
  claimed to have made — the same defect surviving at a second call site,
  a negative check standing in for a positive one, a guard applied to some
  component classes and not others. That is the pattern this file exists
  to catch.
  """

  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Shelly.{Client, Events, Status}

  describe "a scalar \"device\" value must never kill the socket" do
    # raw_device_id/1 was hardened for this payload in 0.2.1; online_flag/1
    # kept the same unguarded get_in and was only reachable through the
    # Online event, which no test covered.
    setup do
      parent = self()

      %{
        state: %{
          handler: fn e -> send(parent, e) end,
          label: "test",
          attempt: 0,
          connected_at: nil
        }
      }
    end

    test "on the Online path", %{state: state} do
      frame =
        Jason.encode!(%{
          "event" => "Shelly:Online",
          "device" => "not-a-map",
          "deviceId" => "b923fa",
          "online" => true
        })

      capture_log(fn ->
        assert {:ok, _} = Events.handle_frame({:text, frame}, state)
      end)

      assert_received {:online, "b923fa", true}
    end

    test "on the StatusOnChange path", %{state: state} do
      frame =
        Jason.encode!(%{
          "event" => "Shelly:StatusOnChange",
          "device" => 12_345,
          "deviceId" => "b923fa",
          "status" => %{"switch:0" => %{"output" => true}}
        })

      capture_log(fn ->
        assert {:ok, _} = Events.handle_frame({:text, frame}, state)
      end)

      assert_received {:status, "b923fa", _}
    end
  end

  describe "control commands need positive confirmation" do
    defp conn(fun) do
      Client.new(server: "https://s.shelly.cloud", auth_key: "k", req_options: [plug: fun])
    end

    defp send_body(conn, status, body, content_type \\ "application/json") do
      conn
      |> Plug.Conn.put_resp_content_type(content_type)
      |> Plug.Conn.send_resp(status, body)
    end

    test "a proxy's HTML page returned with 200 is not a switched relay" do
      # The 0.3.0 fix checked only for an explicit "isok": false, so any
      # other 200 body still read as success.
      client = conn(fn c -> send_body(c, 200, "<html>Gateway timeout</html>", "text/html") end)

      assert {:error, _} = Shelly.CloudV2.set_switch(client, "abc", 0, true)
    end

    test "an empty 200 body is not a switched relay" do
      client = conn(fn c -> send_body(c, 200, Jason.encode!(%{})) end)

      assert {:error, _} = Shelly.CloudV2.set_switch(client, "abc", 0, true)
      assert {:error, _} = Shelly.CloudV2.set_cover(client, "abc", 0, 50)
      assert {:error, _} = Shelly.CloudV2.set_light(client, "abc", 0, brightness: 10)
    end

    test "Shelly saying yes is still success" do
      client = conn(fn c -> send_body(c, 200, Jason.encode!(%{"isok" => true})) end)

      assert Shelly.CloudV2.set_switch(client, "abc", 0, true) == :ok
    end
  end

  describe "unknown is not off — every component class" do
    test "a smoke delta without its alarm key does not clear the alarm" do
      # The one class where the wrong direction is a safety issue.
      assert Status.parse(%{"smoke:0" => %{"mute" => false}}, 0, true).on == nil
      assert Status.parse(%{"flood:0" => %{"battery" => 90}}, 0, true).on == nil
      assert Status.parse(%{"presence:0" => %{"enabled" => true}}, 0, true).on == nil
    end

    test "an explicit alarm state is still reported" do
      assert Status.parse(%{"smoke:0" => %{"alarm" => true}}, 0, true).on == true
      assert Status.parse(%{"smoke:0" => %{"alarm" => false}}, 0, true).on == false
      assert Status.parse(%{"presence:0" => %{"num_objects" => 2}}, 0, true).on == true
      assert Status.parse(%{"presence:0" => %{"num_objects" => 0}}, 0, true).on == false
      assert Status.parse(%{"presence:0" => %{"presence" => true}}, 0, true).on == true
    end
  end

  describe "credentials the client doesn't have" do
    test "each client reports the missing credential instead of raising" do
      keyed = Client.new(server: "https://s.shelly.cloud", auth_key: "k")
      oauth = Client.new(server: "https://s.shelly.cloud", token: "t")

      # Used to be an ArgumentError from "Bearer " <> nil.
      assert Shelly.Account.list_devices(keyed) == {:error, :no_token}
      assert Shelly.Account.all_statuses(keyed) == {:error, :no_token}
      assert Shelly.Account.set_switch(keyed, "abc", 0, true) == {:error, :no_token}

      assert Shelly.CloudV2.get_statuses(oauth, ["abc"]) == {:error, :no_auth_key}
      assert Shelly.CloudV2.set_switch(oauth, "abc", 0, true) == {:error, :no_auth_key}
      assert Shelly.CloudV1.get_status(oauth, "abc") == {:error, :no_auth_key}

      assert Events.start_link(keyed, handler: fn _ -> :ok end) == {:error, :no_token}
    end

    test "an empty string is not a credential" do
      empty = Client.new(server: "https://s.shelly.cloud", token: "", auth_key: "")

      refute Client.oauth?(empty)
      refute Client.keyed?(empty)
      assert Client.token_expired?(empty)
    end
  end

  describe "payload shapes that aren't what the API promised" do
    defp account(fun) do
      Client.new(server: "https://s.shelly.cloud", token: "t", req_options: [plug: fun])
    end

    defp json(conn, body) do
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, Jason.encode!(body))
    end

    test "a list where a device map was promised is an error, not a delayed crash" do
      client =
        account(fn c -> json(c, %{"isok" => true, "data" => %{"devices" => ["a", "b"]}}) end)

      assert {:error, _} = Shelly.Account.list_devices(client)
    end

    test "a v1 response with no device_status does not become a permanently-off device" do
      client =
        Client.new(
          server: "https://s.shelly.cloud",
          auth_key: "k",
          req_options: [
            plug: fn c -> json(c, %{"isok" => true, "data" => %{"online" => true}}) end
          ]
        )

      assert Shelly.CloudV1.get_status(client, "abc") == {:error, :no_device_status}
    end
  end

  describe "overlapping components on one channel" do
    # No Shelly device is known to emit these, but the resolution order is
    # now a decision rather than an accident, so it gets pinned.
    test "an actuator outranks a sensor sharing its channel" do
      overlap = %{"switch:0" => %{"output" => true}, "temperature:0" => %{"tC" => 40.0}}

      assert Status.component_of(overlap, 0) == "switch"
      assert Status.parse(overlap, 0, true).component == "switch"
      # The sensor reading still rides along as enrichment.
      assert Status.parse(overlap, 0, true).temp_c == 40.0
    end

    test "the three functions agree on every overlap" do
      overlaps = [
        %{"pm1:0" => %{"apower" => 1.0}, "cct:0" => %{"output" => true}},
        %{"em:0" => %{"total_act_power" => 10.0}, "cct:0" => %{"output" => true}},
        %{"cover:0" => %{"state" => "open"}, "voltmeter:0" => %{"voltage" => 1.0}},
        %{"light:0" => %{"output" => true}, "flood:0" => %{"alarm" => false}},
        %{"em1:0" => %{"act_power" => 1.0}, "smoke:0" => %{"alarm" => false}}
      ]

      for payload <- overlaps do
        component = Status.component_of(payload, 0)

        assert Status.has_component?(payload, 0)
        assert Status.parse(payload, 0, true).component == component
      end
    end
  end
end
