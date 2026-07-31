defmodule Shelly.ClientsEdgeTest do
  @moduledoc """
  Error and edge paths across the clients — the branches that only run
  when Shelly says no, which is exactly when a library gets judged.
  """

  use ExUnit.Case, async: false

  setup do
    on_exit(fn -> Application.delete_env(:shelly, :req_options) end)
    :ok
  end

  defp account,
    do:
      Shelly.Client.new(
        server: "https://shelly-74-eu.shelly.cloud",
        token: "tok",
        rate_key: :edge
      )

  defp keyed,
    do:
      Shelly.Client.new(
        server: "https://shelly-74-eu.shelly.cloud",
        auth_key: "key",
        rate_key: :edge
      )

  defp with_plug(client, fun), do: Shelly.Client.put_req_options(client, plug: fun)

  defp json(conn, status \\ 200, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(status, Jason.encode!(body))
  end

  describe "Account" do
    test "list_devices returns the device map and sends the bearer token" do
      account =
        with_plug(account(), fn conn ->
          assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer tok"]

          json(conn, %{
            "isok" => true,
            "data" => %{"devices" => %{"485519999340" => %{"name" => "Boiler"}}}
          })
        end)

      assert {:ok, %{"485519999340" => %{"name" => "Boiler"}}} =
               Shelly.Account.list_devices(account)
    end

    test "a rejected listing is an error" do
      account = with_plug(account(), fn conn -> json(conn, 401, %{"isok" => false}) end)
      assert {:error, {:shelly_http, 401, _}} = Shelly.Account.list_devices(account)
    end

    test "set_switch speaks the relay vocabulary and reports rejection" do
      ok =
        with_plug(account(), fn conn ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          assert body =~ "turn=on"
          json(conn, %{"isok" => true})
        end)

      rejected = with_plug(account(), fn conn -> json(conn, %{"isok" => false}) end)

      assert Shelly.Account.set_switch(ok, "485519999340", 0, true) == :ok
      assert {:error, _} = Shelly.Account.set_switch(rejected, "485519999340", 0, true)
    end

    test "expand_channels names single- and multi-channel devices differently" do
      single = Shelly.Account.expand_channels(%{"a" => %{"name" => "Boiler"}})

      multi =
        Shelly.Account.expand_channels(%{"b" => %{"name" => "Pro 3", "channels_count" => 3}})

      assert [%{name: "Boiler", channel: 0}] = single
      assert length(multi) == 3
      assert Enum.map(multi, & &1.name) == ["Pro 3 · ch0", "Pro 3 · ch1", "Pro 3 · ch2"]
    end

    test "a device with no name falls back to its id" do
      assert [%{name: "485519999340"}] =
               Shelly.Account.expand_channels(%{"485519999340" => %{}})
    end
  end

  describe "OAuth" do
    test "authorize_url carries the client and redirect" do
      url = Shelly.OAuth.authorize_url("https://app.example/cb", client_id: "custom-client")
      assert url =~ "client_id=custom-client"
      assert url =~ URI.encode_www_form("https://app.example/cb")
    end

    test "state is passed through, and a broken one is refused rather than dropped" do
      url = Shelly.OAuth.authorize_url("https://app.example/cb", state: "abc123")
      assert url =~ "state=abc123"

      # Omitting it is a documented choice.
      refute Shelly.OAuth.authorize_url("https://app.example/cb") =~ "state="

      # Passing an unusable one would produce a URL with no CSRF binding
      # while the caller believed otherwise.
      for invalid <- [nil, "", 12_345] do
        assert_raise ArgumentError, fn ->
          Shelly.OAuth.authorize_url("https://app.example/cb", state: invalid)
        end
      end
    end

    test "a server claim that isn't a Shelly host falls back instead of trusting it" do
      # The claim rides in an unverified JWT, so it is pinned to *.shelly.cloud.
      token =
        %{"user_api_url" => "https://evil.example.com"}
        |> Jason.encode!()
        |> Base.url_encode64(padding: false)

      Application.put_env(:shelly, :req_options,
        plug: fn conn -> json(conn, %{"access_token" => "header.#{token}.sig"}) end
      )

      assert {:ok, grant} = Shelly.OAuth.exchange_code("header.#{token}.sig")
      refute grant.server =~ "evil.example.com"
      assert grant.server =~ ".shelly.cloud"
    end

    test "an uppercase Shelly host is accepted, not rerouted" do
      token =
        %{"user_api_url" => "HTTPS://SHELLY-74-EU.SHELLY.CLOUD"}
        |> Jason.encode!()
        |> Base.url_encode64(padding: false)

      Application.put_env(:shelly, :req_options,
        plug: fn conn -> json(conn, %{"access_token" => "header.#{token}.sig"}) end
      )

      assert {:ok, grant} = Shelly.OAuth.exchange_code("header.#{token}.sig")
      assert grant.server == "https://shelly-74-eu.shelly.cloud"
    end

    test "a response with no token at all is an error" do
      Application.put_env(:shelly, :req_options,
        plug: fn conn -> json(conn, %{"isok" => true}) end
      )

      assert Shelly.OAuth.exchange_code("code") == {:error, :no_token_in_response}
    end

    test "a rate-limited refresh is retryable, not 'unsupported'" do
      # 429 used to read as "this grant is dead", sending the app to
      # re-authorize a token that was merely being throttled.
      account =
        with_plug(account(), fn conn -> json(conn, 429, %{"error" => "too many requests"}) end)

      assert {:error, {:oauth_http, 429, _}} = Shelly.OAuth.refresh(account)
    end
  end

  describe "CloudV1" do
    test "a transport failure surfaces as an error tuple, not a raise" do
      # A closed port is the honest simulation: a plug that raises would
      # test Req's exception path, not ours.
      conn =
        Shelly.Client.new(
          server: "https://127.0.0.1:1",
          auth_key: "key",
          rate_key: :edge,
          # verify_none: this asserts our error handling, not whether the
          # machine running the suite has a CA trust store.
          req_options: [
            retry: false,
            connect_options: [timeout: 200, transport_opts: [verify: :verify_none]]
          ]
        )

      assert {:error, %Req.TransportError{}} = Shelly.CloudV1.get_status(conn, "b923fa")
    end

    test "a rejected command reports the status" do
      conn = with_plug(keyed(), fn conn -> json(conn, 403, %{"isok" => false}) end)
      assert {:error, {:shelly_http, 403, _}} = Shelly.CloudV1.set_switch(conn, "b923fa", 0, true)
    end
  end

  describe "RateGate" do
    test "pacing applies per key, and an unstarted gate passes calls straight through" do
      # No gate running here: calls must still work, just unpaced.
      assert Shelly.RateGate.run({:server, :key}, fn -> :ran end, :no_such_gate) == :ran
    end

    test "a running gate spaces successive calls for the same key" do
      start_supervised!({Shelly.RateGate, name: :edge_gate, interval_ms: 60})

      started = System.monotonic_time(:millisecond)
      for _ <- 1..3, do: Shelly.RateGate.run(:same_key, fn -> :ok end, :edge_gate)
      elapsed = System.monotonic_time(:millisecond) - started

      assert elapsed >= 120, "three calls on one key should be spaced by the interval"
    end
  end
end
