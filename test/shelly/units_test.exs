defmodule Shelly.UnitsTest do
  use ExUnit.Case, async: true

  describe "Shelly.Events.normalize_device_id/1" do
    test "integer ids convert to padded lowercase hex" do
      # Real pair from a live device: Decimal Id <-> Device Id
      assert Shelly.Events.normalize_device_id(79_530_338_915_136) == "485519999340"
    end

    test "string ids pass through downcased (hex strings are canonical)" do
      assert Shelly.Events.normalize_device_id("0CDC7EF76644") == "0cdc7ef76644"
    end

    test "decimal strings convert — the live websocket sends ids this way" do
      # Same real pair as above, but as the string Shelly actually pushes.
      # Left unconverted, consumers match nothing and realtime silently
      # degrades to polling.
      assert Shelly.Events.normalize_device_id("79530338915136") == "485519999340"
      assert Shelly.Events.normalize_device_id("14141162481220") == "0cdc7ef76644"
      assert Shelly.Events.normalize_device_id(" 79530338915136 ") == "485519999340"
    end

    test "a 12-digit all-numeric id is hex, not decimal" do
      # "485519999340" is both a valid hex id and a valid number; length
      # decides, since a real id's decimal form needs 13+ digits.
      assert Shelly.Events.normalize_device_id("485519999340") == "485519999340"
    end

    test "small integers are zero-padded to mac width" do
      assert Shelly.Events.normalize_device_id(255) == "0000000000ff"
    end

    test "garbage returns nil" do
      assert Shelly.Events.normalize_device_id(%{}) == nil
    end
  end

  describe "Shelly.OAuth" do
    test "authorize_url encodes client and redirect" do
      url = Shelly.OAuth.authorize_url("https://app.example/cb")
      assert url =~ "my.shelly.cloud/oauth_login.html"
      assert url =~ "client_id=shelly-diy"
      assert url =~ URI.encode_www_form("https://app.example/cb")
    end

    test "peek_jwt reads claims without verifying" do
      claims = %{"user_api_url" => "shelly-74-eu.shelly.cloud"}
      payload = claims |> Jason.encode!() |> Base.url_encode64(padding: false)
      token = "header.#{payload}.sig"

      assert Shelly.OAuth.peek_jwt(token) == claims
      assert Shelly.OAuth.peek_jwt("not-a-jwt") == nil
      assert Shelly.OAuth.peek_jwt(nil) == nil
    end

    test "to_account bridges the exchange result shape" do
      grant = %{access_token: "tok", user_api_url: "https://s.shelly.cloud", label: "x"}
      assert Shelly.OAuth.to_account(grant) == %{server: "https://s.shelly.cloud", token: "tok"}
    end
  end

  describe "Shelly.Account.expand_channels/1" do
    test "multi-channel devices expand to one row per channel" do
      devices = %{
        "AABBCCDDEEFF" => %{"name" => "Pro", "channels_count" => 3, "type" => "SPSW", "gen" => 2},
        "112233445566" => %{"name" => "Plug", "type" => "SNPL", "cloud_online" => true}
      }

      rows = Shelly.Account.expand_channels(devices)

      assert length(rows) == 4
      pro_rows = Enum.filter(rows, &(&1.id == "aabbccddeeff"))
      assert Enum.map(pro_rows, & &1.channel) |> Enum.sort() == [0, 1, 2]
      assert hd(pro_rows).name =~ "· ch"

      plug = Enum.find(rows, &(&1.id == "112233445566"))
      assert plug.name == "Plug"
      assert plug.online
    end
  end

  describe "Shelly.CloudV2.get_statuses/2 guard" do
    test "more than 10 ids returns an error tuple, not a crash" do
      conn = %{server: "https://example.invalid", auth_key: "k"}
      ids = Enum.map(1..11, &"device-#{&1}")
      assert Shelly.CloudV2.get_statuses(conn, ids) == {:error, :too_many_ids}
    end
  end
end
