defmodule Shelly.BlindReviewTest do
  @moduledoc """
  Defects found by a review that was given no context — no history, no
  hypotheses, no list of known issues.

  It found 38, none of which the existing 178 tests caught. The pattern in
  its coverage analysis is the useful part: the suite was not thin, it
  *stopped one case short*. Four separate tests enumerated a vocabulary or
  swept a range of values and omitted exactly the member that failed —
  `"stopped"` from the cover states, channel-bounds for Gen1 sensors but
  not the other classes, `""` from the credential sweep but not `"  x  "`.

  Every case here is the omitted member of a list that already existed.
  """

  use ExUnit.Case, async: true

  alias Shelly.{Client, Events, Status}

  describe "the documented Shelly 2.5 workaround must actually work" do
    # A 2.5 in roller mode reports BOTH arrays and gives no in-payload
    # signal of its mode, so the docs tell callers to say which it is.
    # `extra` merged after dispatch, so it relabelled the wrong answer
    # rather than producing the right one — worse than not documenting it.
    @roller_mode %{
      "relays" => [%{"ison" => false}],
      "rollers" => [%{"state" => "open", "current_pos" => 70}]
    }

    test "without a hint, the relay array wins (documented limitation)" do
      assert Status.parse(@roller_mode, 0, true).component == "relay"
    end

    test "with the documented hint, the cover parser actually runs" do
      parsed = Status.parse(@roller_mode, 0, true, %{component: "cover"})

      assert parsed.component == "cover"
      assert parsed.on == true, "an open blind must not read as closed"
    end

    test "a hint for a component the payload doesn't have is ignored" do
      parsed = Status.parse(@roller_mode, 0, true, %{component: "light"})

      assert parsed.component == "relay"
    end
  end

  describe "customizing requests must not disarm them" do
    defp capture_request(client, call) do
      parent = self()

      client =
        Client.put_req_options(client,
          plug: fn conn ->
            send(parent, {:request, conn})

            conn
            |> Plug.Conn.put_resp_content_type("application/json")
            |> Plug.Conn.send_resp(200, Jason.encode!(%{"isok" => true, "data" => %{}}))
          end
        )

      call.(client)
      assert_received {:request, conn}
      conn
    end

    test "adding a header keeps the Authorization header" do
      # Keyword.merge replaced :headers wholesale, so one extra header
      # silently un-authenticated every call.
      client =
        Client.new(server: "https://s.shelly.cloud", token: "tok")
        |> Client.put_req_options(headers: [{"x-request-id", "abc123"}])

      conn = capture_request(client, &Shelly.Account.list_devices/1)

      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer tok"]
      assert Plug.Conn.get_req_header(conn, "x-request-id") == ["abc123"]
    end

    test "a caller cannot redirect a control command to another host" do
      client =
        Client.new(server: "https://s.shelly.cloud", auth_key: "k")
        |> Client.put_req_options(url: "https://elsewhere.example/hijacked")

      conn = capture_request(client, &Shelly.CloudV2.set_switch(&1, "abc", 0, true))

      assert conn.host == "s.shelly.cloud"
      refute conn.request_path =~ "hijacked"
    end
  end

  describe "the socket can be supervised the way its docs describe" do
    test "child_spec accepts a client and options" do
      client = Client.new(server: "https://s.shelly.cloud", token: "tok")
      spec = Shelly.Events.child_spec({client, handler: fn _ -> :ok end})

      assert %{id: Shelly.Events, start: {Shelly.Events, :start_link, [^client, opts]}} = spec
      assert Keyword.has_key?(opts, :handler)
    end

    test "a missing or unusable handler is an error, not a raise" do
      client = Client.new(server: "https://s.shelly.cloud", token: "tok")

      assert Events.start_link(client, []) == {:error, :no_handler}
      assert {:error, {:invalid_handler, _}} = Events.start_link(client, handler: :not_a_function)
    end
  end

  describe "payload shapes that used to raise in the caller's process" do
    test "a scalar where a nested map was promised" do
      # Account.parse_status was the third site of the class the Events
      # module has a comment about.
      assert %{component: _} = Shelly.Account.parse_status(%{"cloud" => "connected"}, 0)
      assert %{component: _} = Shelly.Account.parse_status(%{"_dev_info" => 1}, 0)
    end

    test "a device listing whose entries aren't maps" do
      assert Shelly.Account.expand_channels(%{"abc" => "not-a-map"}) == []

      # A good entry alongside a bad one still comes through.
      assert [%{id: "def"}] =
               Shelly.Account.expand_channels(%{"abc" => "bad", "def" => %{"name" => "Boiler"}})
    end

    test "an absurd channel count is bounded rather than materialized" do
      rows = Shelly.Account.expand_channels(%{"abc" => %{"channels_count" => 100_000}})

      assert length(rows) <= 64

      assert Shelly.Account.expand_channels(%{"abc" => %{"channels_count" => "2junk"}})
             |> length() == 1
    end
  end

  describe "the omitted member of each enumeration" do
    test "a Gen2 cover saying 'stopped' with no position is unknown" do
      # partial_delta_test enumerates "open"/"closed"/%{} under "fall back
      # to the vocabulary" and omits this one, which its own comment calls
      # what an uncalibrated cover says forever.
      assert Status.parse(%{"cover:0" => %{"state" => "stopped"}}, 0, true).on == nil
      assert Status.parse(%{"cover:0" => %{"state" => "calibrating"}}, 0, true).on == nil

      # And the two generations now agree on the same words.
      gen1 = Status.parse(%{"rollers" => [%{"state" => "stop"}]}, 0, true).on
      gen2 = Status.parse(%{"cover:0" => %{"state" => "stopped"}}, 0, true).on
      assert gen1 == gen2
    end

    test "a Gen1 battery sensor answers for its own channel only" do
      # agreement_test pins out-of-range channels for Gen1 arrays and RPC
      # switches, and lists the battery sensors at channel 0 only.
      flood = %{"flood" => true, "bat" => %{"value" => 90}}

      assert Status.has_component?(flood, 0)
      refute Status.has_component?(flood, 7)
      assert Status.component_of(flood, 7) == nil
      assert Status.parse(flood, 7, true).component == "unknown"
    end

    test "a padded credential is not sent with its padding" do
      # exhaustive_test sweeps [nil, "", "   "] and asserts each is
      # refused; it never asked what a padded but real credential does.
      client = Client.new(server: "https://s.shelly.cloud", token: "  tok  ")

      assert Client.oauth?(client)
      assert client.token == "tok"

      parent = self()

      client
      |> Client.put_req_options(
        plug: fn conn ->
          send(parent, {:auth, Plug.Conn.get_req_header(conn, "authorization")})
          Plug.Conn.send_resp(conn, 200, "{}")
        end
      )
      |> Shelly.Account.list_devices()

      assert_received {:auth, ["Bearer tok"]}
    end

    test "a whitespace-only token is not a token" do
      # oauth_test covers "" and stops there.
      assert Client.new(server: "https://s.shelly.cloud", token: "   ").token == nil
      assert Client.token_expired?(Client.new(server: "https://s.shelly.cloud", token: "   "))
    end

    test "token_expired? and oauth? cannot disagree" do
      # A blank token WITH an expiry was the untested cell: expired? said
      # false, oauth? said false, and the documented routing then chose
      # the path that answers {:error, :no_token}.
      for token <- [nil, "", "   "], expires <- [nil, DateTime.add(DateTime.utc_now(), 3600)] do
        client = Client.new(server: "https://s.shelly.cloud", token: token, expires_at: expires)

        assert Client.token_expired?(client) == not Client.oauth?(client)
      end
    end

    test "set_cover honours the options its spec declares" do
      # Called in three tests, always with four arguments.
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

      Shelly.CloudV2.set_cover(client, "abc", 0, 50, toggle_after: 60)
      assert_received {:body, %{"toggle_after" => 60}}
    end

    test "a handler that throws or exits does not take the socket down" do
      # events_dispatch_test covers the raise, which is what made the
      # other two look covered.
      frame = Jason.encode!(%{"event" => "Shelly:Online", "deviceId" => "b923fa", "online" => 1})

      for handler <- [
            fn _ -> throw(:nope) end,
            fn _ -> exit(:nope) end,
            fn _ -> raise "nope" end
          ] do
        state = %{handler: handler, label: "t", attempt: 0, connected_at: nil, known_ids: nil}

        assert ExUnit.CaptureLog.capture_log(fn ->
                 assert {:ok, _} = Events.handle_frame({:text, frame}, state)
               end) =~ "handler crashed"
      end
    end
  end

  describe "addressing" do
    defp socket_url(client), do: Events.socket_url(client.server, client.token)

    test "an IPv6 server produces a usable socket URL" do
      # render_host exists twice in the codebase for this; the socket
      # builder was the third site and didn't have it.
      client = Client.new(server: "https://[2001:db8::1]", token: "tok")

      assert client.server == "https://[2001:db8::1]"
      # The socket URL must re-parse to the same host.
      assert %URI{host: "2001:db8::1"} =
               URI.parse(String.replace(socket_url(client), "wss", "https"))
    end

    test "a server on a custom port keeps it for the socket too" do
      client = Client.new(server: "https://proxy.local:8443", token: "tok")

      assert socket_url(client) =~ ":8443/"
    end

    test "a token with URL-significant characters survives" do
      client = Client.new(server: "https://s.shelly.cloud", token: "a+b&c=d")

      url = socket_url(client)
      assert url =~ "t=a%2Bb%26c%3Dd"
      refute url =~ "&c="
    end
  end

  describe "readings the device says are not valid" do
    test "an invalid Gen1 measurement is not reported as data" do
      stale = %{
        "relays" => [%{"ison" => true}],
        "meters" => [%{"power" => 123.0, "total" => 60, "is_valid" => false}]
      }

      parsed = Status.parse(stale, 0, true)

      refute parsed.metered, "a reading marked invalid must not count as a measurement"
    end

    test "an invalid contact reading is unknown, not closed" do
      assert Status.parse(%{"sensor" => %{"state" => "open", "is_valid" => false}}, 0, true).on ==
               nil
    end
  end
end
