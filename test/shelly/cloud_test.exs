defmodule Shelly.CloudTest do
  @moduledoc """
  The auth-key clients had no HTTP-level coverage at all, which is where
  the v1 envelope bug lived: `get_status/2` returned the wrapper its own
  docs told you to parse, and parsing that yields a device that looks
  permanently off.
  """

  use ExUnit.Case, async: true

  @conn %{
    server: "https://shelly-74-eu.shelly.cloud",
    auth_key: "key-123",
    rate_key: :test_account
  }

  defp conn(fun), do: Map.put(@conn, :req_options, plug: fun)

  defp json(conn, status \\ 200, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(status, Jason.encode!(body))
  end

  describe "CloudV2.get_statuses/2" do
    test "returns statuses keyed by lowercase device id" do
      conn =
        conn(fn conn ->
          json(conn, [
            %{
              "id" => "0CDC7EF76644",
              "status" => %{"switch:0" => %{"output" => true}},
              "online" => 1
            }
          ])
        end)

      assert {:ok, %{"0cdc7ef76644" => element}} =
               Shelly.CloudV2.get_statuses(conn, ["0cdc7ef76644"])

      assert element["online"] == 1
    end

    test "refuses more than the API's ten ids rather than truncating" do
      ids = Enum.map(1..11, &"device#{&1}")
      assert Shelly.CloudV2.get_statuses(@conn, ids) == {:error, :too_many_ids}
    end

    test "an HTTP error surfaces with its status" do
      conn = conn(fn conn -> json(conn, 401, %{"isok" => false}) end)

      assert {:error, {:shelly_http, 401, _}} = Shelly.CloudV2.get_statuses(conn, ["abc"])
    end
  end

  describe "CloudV2 control" do
    test "set_switch sends the channel and state, and passes the auth key" do
      conn =
        conn(fn conn ->
          conn = Plug.Conn.fetch_query_params(conn)
          assert conn.query_params["auth_key"] == "key-123"

          {:ok, body, conn} = Plug.Conn.read_body(conn)
          assert %{"id" => "abc", "channel" => 1, "on" => true} = Jason.decode!(body)

          json(conn, %{"isok" => true})
        end)

      assert Shelly.CloudV2.set_switch(conn, "abc", 1, true) == :ok
    end

    test "toggle_after rides along when asked for, and is absent otherwise" do
      with_watchdog =
        conn(fn conn ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          assert Jason.decode!(body)["toggle_after"] == 1800
          json(conn, %{"isok" => true})
        end)

      without =
        conn(fn conn ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          refute Map.has_key?(Jason.decode!(body), "toggle_after")
          json(conn, %{"isok" => true})
        end)

      assert Shelly.CloudV2.set_switch(with_watchdog, "abc", 0, true, toggle_after: 1800) == :ok
      assert Shelly.CloudV2.set_switch(without, "abc", 0, true) == :ok
    end

    test "a non-ok body is an error, not a silent success" do
      conn = conn(fn conn -> json(conn, %{"isok" => false, "errors" => %{"bad" => "no"}}) end)

      assert {:error, _} = Shelly.CloudV2.set_switch(conn, "abc", 0, true)
    end

    test "covers and lights reach their endpoints" do
      cover =
        conn(fn conn -> assert conn.request_path =~ "cover" and json(conn, %{"isok" => true}) end)

      light =
        conn(fn conn -> assert conn.request_path =~ "light" and json(conn, %{"isok" => true}) end)

      assert Shelly.CloudV2.set_cover(cover, "abc", 0, 50) == :ok
      assert Shelly.CloudV2.set_light(light, "abc", 0, brightness: 40) == :ok
    end
  end

  describe "CloudV1.get_status/2" do
    test "unwraps the envelope, returning the status and the online flag" do
      conn =
        conn(fn conn ->
          json(conn, %{
            "isok" => true,
            "data" => %{
              "online" => true,
              "device_status" => %{"relays" => [%{"ison" => true}]}
            }
          })
        end)

      assert {:ok, {device_status, true}} = Shelly.CloudV1.get_status(conn, "b923fa")

      # The point of unwrapping: this is what the docs tell you to parse.
      parsed = Shelly.Status.parse(device_status, 0, true)
      assert parsed.component == "relay"
      assert parsed.on == true
    end

    test "an offline device still returns its last status" do
      conn =
        conn(fn conn ->
          json(conn, %{
            "isok" => true,
            "data" => %{"online" => false, "device_status" => %{"relays" => [%{"ison" => false}]}}
          })
        end)

      assert {:ok, {_status, false}} = Shelly.CloudV1.get_status(conn, "b923fa")
    end

    test "set_switch uses the v1 turn vocabulary" do
      conn =
        conn(fn conn ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          assert body =~ "turn=off"
          assert body =~ "auth_key=key-123"
          json(conn, %{"isok" => true})
        end)

      assert Shelly.CloudV1.set_switch(conn, "b923fa", 0, false) == :ok
    end
  end
end
