defmodule Shelly.SecondBlindTest do
  @moduledoc """
  Findings from a second context-free review, run against code the first
  one had already been through.

  The recurring shape is the same and worth naming again: a rule applied
  in one place and not at its sibling. `is_valid` honoured by the meter
  parser and ignored by `enrich/2`. Channel scoping applied to
  temperature and not to battery. `:component` deleted from `extra` on
  the map clause and merged on the non-map one. Each pair sits within a
  few lines of the other.
  """

  use ExUnit.Case, async: true

  alias Shelly.{Client, Events, Status}

  describe "a command must never be sent twice" do
    test "an exit from the request itself is not read as a dead gate" do
      # The catch wrapped fun.() as well as the GenServer.call, so a
      # request exiting {:noproc, _} — a dead Finch pool — was treated as
      # "the gate died" and re-run.
      start_supervised!({Shelly.RateGate, name: :dup_gate, interval_ms: 1})

      counter = :counters.new(1, [])

      assert catch_exit(
               Shelly.RateGate.run(
                 :key,
                 fn ->
                   :counters.add(counter, 1, 1)
                   exit({:noproc, {GenServer, :call, [:missing_pool, :req]}})
                 end,
                 :dup_gate
               )
             )

      assert :counters.get(counter, 1) == 1, "the request ran more than once"
    end

    test "a gate that isn't running still runs the request exactly once" do
      counter = :counters.new(1, [])

      assert Shelly.RateGate.run(
               :key,
               fn ->
                 :counters.add(counter, 1, 1)
                 :ran
               end,
               :no_such_gate
             ) == :ran

      assert :counters.get(counter, 1) == 1
    end
  end

  describe "validity flags apply wherever the reading is read" do
    test "enrichment does not reinstate what the parser refused" do
      # gen1_temperature/1 rejected these, then enrich/2 re-read the same
      # raw maps and put the values back.
      payload = %{
        "relays" => [%{"ison" => true}],
        "tmp" => %{"tC" => 99.0, "is_valid" => false},
        "hum" => %{"value" => 55.0, "is_valid" => false},
        "bat" => %{"value" => 42, "is_valid" => false}
      }

      parsed = Status.parse(payload, 0, true)

      assert parsed.temp_c == nil
      assert parsed.humidity == nil
      assert parsed.battery == nil
    end

    test "a Gen1 emeter phase marked invalid is not a measurement" do
      payload = %{"emeters" => [%{"power" => 0.0, "total" => 123.4, "is_valid" => false}]}
      parsed = Status.parse(payload, 0, true)

      refute parsed.metered
      assert parsed.energy_wh == nil
    end

    test "valid readings are unaffected" do
      payload = %{
        "emeters" => [%{"power" => 100.0, "total" => 200.0}],
        "tmp" => %{"tC" => 21.0}
      }

      parsed = Status.parse(payload, 0, true)

      assert parsed.metered
      assert parsed.temp_c == 21.0
    end
  end

  describe "one channel's readings are its own" do
    test "battery is channel-scoped like temperature" do
      payload = %{
        "switch:0" => %{"output" => true},
        "switch:1" => %{"output" => false},
        "devicepower:0" => %{"battery" => %{"percent" => 42}},
        "temperature:0" => %{"tC" => 20.0}
      }

      assert Status.parse(payload, 0, true).battery == 42
      assert Status.parse(payload, 1, true).battery == nil
      assert Status.parse(payload, 1, true).temp_c == nil
    end
  end

  describe "the two cover generations agree on every input" do
    test "a negative position is uncalibrated, not closed" do
      gen2 = Status.parse(%{"cover:0" => %{"current_pos" => -1, "state" => "open"}}, 0, true).on
      gen1 = Status.parse(%{"rollers" => [%{"current_pos" => -1, "state" => "open"}]}, 0, true).on

      assert gen2 == gen1
      assert gen2 == true, "a negative position must fall through to the state, not report closed"
    end
  end

  describe "extra never labels a status the parser didn't produce" do
    test "on the non-map clause too" do
      # The map clause deletes :component before merging; this one didn't.
      assert Status.parse("junk", 0, true, %{component: "cover"}).component == "unknown"
      assert Status.parse(nil, 0, true, %{component: "cover"}).component == "unknown"

      # Other keys still come through on that path.
      assert Status.parse("junk", 0, true, %{model: "X"}).model == "X"
    end
  end

  describe "device identity is one answer everywhere" do
    test "an integer known-id resolves the ambiguous case correctly" do
      # to_string/1 gave the decimal rendering, so an integer known-id
      # pushed the lookup to the wrong device.
      assert Events.normalize_device_id("405408", [0x062FA0]) == "062fa0"
      assert Events.normalize_device_id("405408", ["062fa0"]) == "062fa0"
      assert Events.normalize_device_id("405408", [405_408]) == "062fa0"
    end

    test "an unusable nested id does not mask a valid top-level one" do
      parent = self()

      state = %{
        handler: &send(parent, &1),
        label: "t",
        attempt: 0,
        connected_at: nil,
        known_ids: nil
      }

      frame =
        Jason.encode!(%{
          "event" => "Shelly:StatusOnChange",
          "device" => %{"id" => ""},
          "deviceId" => "485519999340",
          "status" => %{"switch:0" => %{"output" => true}}
        })

      assert {:ok, _} = Events.handle_frame({:text, frame}, state)
      assert_received {:status, "485519999340", _}
    end
  end

  describe "request options cannot disarm a request" do
    test ":auth is refused, since Req's auth step replaces the header" do
      parent = self()

      client =
        Client.new(server: "https://s.shelly.cloud", token: "real-token")
        |> Client.put_req_options(
          auth: {:bearer, "ATTACKER"},
          plug: fn conn ->
            send(parent, {:auth, Plug.Conn.get_req_header(conn, "authorization")})
            Plug.Conn.send_resp(conn, 200, "{}")
          end
        )

      ExUnit.CaptureLog.capture_log(fn -> Shelly.Account.list_devices(client) end)

      assert_received {:auth, ["Bearer real-token"]}
    end
  end

  describe "entry points are total where their documented usage can miss" do
    test "parse_status accepts what a missing id lookup returns" do
      # The docs show parse_status(statuses[id], channel).
      assert %{component: "unknown"} = Shelly.Account.parse_status(nil, 0)
      assert %{component: "unknown"} = Shelly.Account.parse_status("junk", 0)
    end
  end

  describe "the recommended path is honest about what it cannot do" do
    test "asking the account API for a watchdog is refused, not ignored" do
      client = Client.new(server: "https://s.shelly.cloud", token: "tok")

      assert Shelly.Account.set_switch(client, "abc", 0, true, toggle_after: 600) ==
               {:error, :toggle_after_unsupported}
    end

    test "the v2 path carries every option it is given" do
      parent = self()

      client =
        Client.new(server: "https://s.shelly.cloud", auth_key: "k")
        |> Client.put_req_options(
          plug: fn conn ->
            {:ok, body, conn} = Plug.Conn.read_body(conn)
            send(parent, {:body, Jason.decode!(body)})

            conn
            |> Plug.Conn.put_resp_content_type("application/json")
            |> Plug.Conn.send_resp(200, Jason.encode!(%{"isok" => true}))
          end
        )

      Shelly.CloudV2.set_cover(client, "abc", 0, 50, duration: 5)
      assert_received {:body, %{"duration" => 5, "position" => 50}}
    end
  end

  describe "a refresh cannot produce a client that never expires" do
    test "an opaque replacement token keeps the previous deadline" do
      deadline = DateTime.add(DateTime.utc_now(), 3600) |> DateTime.truncate(:second)

      client =
        Client.new(
          server: "https://shelly-74-eu.shelly.cloud",
          token: "old",
          expires_at: deadline,
          req_options: [
            plug: fn conn ->
              conn
              |> Plug.Conn.put_resp_content_type("application/json")
              |> Plug.Conn.send_resp(200, Jason.encode!(%{"access_token" => "opaque-not-a-jwt"}))
            end
          ]
        )

      assert {:ok, refreshed} = Shelly.OAuth.refresh(client)
      assert refreshed.token == "opaque-not-a-jwt"

      # nil here would mean "never expires", permanently.
      assert refreshed.expires_at == deadline
    end
  end
end
