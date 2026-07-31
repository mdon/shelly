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

    test "ids pad to the width Shelly documents: 6 for Gen1, 12 otherwise" do
      # The spec pins hex ids to 6 or 12 characters, zero-padded. Padding
      # everything to 12 gave one Gen1 device two keys — "000000b923fa"
      # from an integer event, "b923fa" from a string one.
      assert Shelly.Events.normalize_device_id(255) == "0000ff"
      assert Shelly.Events.normalize_device_id(0xB923FA) == "b923fa"
      assert Shelly.Events.normalize_device_id(0x485519999340) == "485519999340"
    end

    test "Gen1 decimal strings convert — 8 digits, so a >12 rule misses them" do
      # 0xb923fa renders as "12133370". This is the half of the decimal-id
      # bug that 0.2.1's first attempt left in place.
      assert Shelly.Events.normalize_device_id("12133370") == "b923fa"

      assert Shelly.Events.normalize_device_id("12133370") ==
               Shelly.Events.normalize_device_id(0xB923FA)
    end

    test "the integer and string forms of one id agree" do
      for id <- [0xB923FA, 0x485519999340, 0x0CDC7EF76644] do
        from_integer = Shelly.Events.normalize_device_id(id)
        from_decimal_string = Shelly.Events.normalize_device_id(Integer.to_string(id))
        assert from_integer == from_decimal_string
      end
    end

    test "a 6-character all-digit string is a Gen1 hex id, not decimal" do
      assert Shelly.Events.normalize_device_id("123456") == "123456"
    end

    test "non-hex ids (BLE/Z-Wave X-prefixed) pass through downcased" do
      assert Shelly.Events.normalize_device_id("XAABBCCDDEEFF") == "xaabbccddeeff"
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

      assert Shelly.OAuth.to_account(grant) == %{
               server: "https://s.shelly.cloud",
               token: "tok",
               refresh_token: nil,
               expires_at: nil
             }
    end

    test "to_account carries the refresh token and expiry refresh/2 needs" do
      # Dropping these made the documented refresh path send the access
      # token as the refresh token.
      expires_at = DateTime.from_unix!(1_785_307_752)

      grant = %{
        access_token: "tok",
        user_api_url: "https://s.shelly.cloud",
        refresh_token: "refresh-me",
        expires_at: expires_at,
        label: "someone@example.com"
      }

      account = Shelly.OAuth.to_account(grant)
      assert account.refresh_token == "refresh-me"
      assert account.expires_at == expires_at
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
