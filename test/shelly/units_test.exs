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

    test "a client knows whether its token is still good" do
      live =
        Shelly.Client.new(
          server: "https://s.shelly.cloud",
          token: "tok",
          expires_at: DateTime.add(DateTime.utc_now(), 3600)
        )

      dead = %{live | expires_at: DateTime.add(DateTime.utc_now(), -60)}
      keyless = Shelly.Client.new(server: "https://s.shelly.cloud", auth_key: "key")

      refute Shelly.Client.expired?(live)
      assert Shelly.Client.expired?(dead)
      # No token at all counts as expired, and no expiry recorded counts
      # as live — the cloud is the real authority.
      assert Shelly.Client.expired?(keyless)

      refute Shelly.Client.expired?(
               Shelly.Client.new(server: "https://s.shelly.cloud", token: "t")
             )

      assert Shelly.Client.expires_in(live) > 3500
      assert Shelly.Client.expires_in(keyless) == nil
    end

    test "a client reports which transports it can use" do
      oauth = Shelly.Client.new(server: "https://s.shelly.cloud", token: "tok")
      keyed = Shelly.Client.new(server: "https://s.shelly.cloud", auth_key: "key")
      both = Shelly.Client.put_auth_key(oauth, "key")

      assert Shelly.Client.oauth?(oauth)
      refute Shelly.Client.keyed?(oauth)
      assert Shelly.Client.keyed?(keyed)
      refute Shelly.Client.oauth?(keyed)
      assert Shelly.Client.oauth?(both) and Shelly.Client.keyed?(both)
    end

    test "the server is normalized, and a missing one is a loud error" do
      assert Shelly.Client.new(server: "SHELLY-74-EU.shelly.cloud").server ==
               "https://shelly-74-eu.shelly.cloud"

      assert_raise ArgumentError, fn -> Shelly.Client.new(token: "tok") end
    end

    test "a non-default port survives normalization" do
      # Dropping it would quietly send a proxied or test client to 443.
      assert Shelly.Client.new(server: "https://127.0.0.1:4040").server ==
               "https://127.0.0.1:4040"

      assert Shelly.Client.new(server: "https://s.shelly.cloud:443").server ==
               "https://s.shelly.cloud"
    end

    test "one account is one rate budget, whatever the credential" do
      # Without an explicit key the credential stands in, so a token
      # refresh would silently start a fresh budget.
      stable = Shelly.Client.new(server: "https://s.shelly.cloud", token: "a", rate_key: 7)
      refreshed = %{stable | token: "b"}

      assert Shelly.Client.rate_key(stable) == Shelly.Client.rate_key(refreshed)

      implicit = Shelly.Client.new(server: "https://s.shelly.cloud", token: "a")
      assert Shelly.Client.rate_key(implicit) != Shelly.Client.rate_key(%{implicit | token: "b"})
    end
  end
end
