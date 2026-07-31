defmodule Shelly.OAuthTest do
  use ExUnit.Case, async: false

  # Requests are answered in-process through Req's `:plug` option, wired in
  # via the :req_options application env seam.
  setup do
    on_exit(fn -> Application.delete_env(:shelly, :req_options) end)
    :ok
  end

  defp stub(fun) do
    Application.put_env(:shelly, :req_options, plug: fun)
  end

  defp respond(conn, status, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(status, Jason.encode!(body))
  end

  defp jwt(claims) do
    payload = claims |> Jason.encode!() |> Base.url_encode64(padding: false)
    "header.#{payload}.signature"
  end

  defp account_token(overrides \\ %{}) do
    %{
      "user_api_url" => "https://shelly-74-eu.shelly.cloud",
      "exp" => 1_785_307_752,
      "iat" => 1_785_264_552
    }
    |> Map.merge(overrides)
    |> jwt()
  end

  describe "exchange_code/2" do
    test "returns the refresh token and the deadline read from the JWT" do
      token = account_token()

      stub(fn conn ->
        respond(conn, 200, %{"access_token" => token, "refresh_token" => "refresh-me"})
      end)

      assert {:ok, result} =
               Shelly.OAuth.exchange_code(
                 jwt(%{"user_api_url" => "https://shelly-74-eu.shelly.cloud"})
               )

      assert result.token == token
      assert result.refresh_token == "refresh-me"
      assert result.expires_at == DateTime.from_unix!(1_785_307_752)
      assert result.server == "https://shelly-74-eu.shelly.cloud"
    end

    test "a token without a refresh token or exp claim yields nils, not a crash" do
      token = jwt(%{"user_api_url" => "https://shelly-74-eu.shelly.cloud"})

      stub(fn conn -> respond(conn, 200, %{"data" => %{"code" => token}}) end)

      assert {:ok, result} = Shelly.OAuth.exchange_code(token)
      assert result.refresh_token == nil
      assert result.expires_at == nil
    end
  end

  describe "refresh/2" do
    test "swaps a live token for a fresh one when the server supports it" do
      renewed = account_token(%{"exp" => 1_785_350_952})

      stub(fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        assert body =~ "grant_type=refresh_token"
        assert body =~ "refresh_token=stored-refresh"

        respond(conn, 200, %{"access_token" => renewed, "refresh_token" => "next-refresh"})
      end)

      account =
        Shelly.Client.new(
          server: "https://shelly-74-eu.shelly.cloud",
          token: account_token(),
          refresh_token: "stored-refresh"
        )

      assert {:ok, result} = Shelly.OAuth.refresh(account)
      assert result.token == renewed
      assert result.refresh_token == "next-refresh"
      assert result.expires_at == DateTime.from_unix!(1_785_350_952)
    end

    test "falls back to the access token when no refresh token was stored" do
      stub(fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        assert body =~ "refresh_token=" <> URI.encode_www_form("the-access-token")

        respond(conn, 401, %{"errors" => %{"invalid_token" => "nope"}})
      end)

      account =
        Shelly.Client.new(server: "https://shelly-74-eu.shelly.cloud", token: "the-access-token")

      assert Shelly.OAuth.refresh(account) == {:error, :refresh_unsupported}
    end

    test "a 4xx means the grant is unsupported — callers re-authorize instead of retrying" do
      stub(fn conn -> respond(conn, 400, %{"error" => "unsupported_grant_type"}) end)

      account =
        Shelly.Client.new(server: "https://shelly-74-eu.shelly.cloud", token: account_token())

      assert Shelly.OAuth.refresh(account) == {:error, :refresh_unsupported}
    end

    test "a 200 that carries no token is not mistaken for success" do
      stub(fn conn -> respond(conn, 200, %{"isok" => true}) end)

      account =
        Shelly.Client.new(server: "https://shelly-74-eu.shelly.cloud", token: account_token())

      assert Shelly.OAuth.refresh(account) == {:error, :refresh_unsupported}
    end

    test "server errors surface as-is so callers can retry" do
      stub(fn conn -> respond(conn, 503, %{"error" => "maintenance"}) end)

      account =
        Shelly.Client.new(server: "https://shelly-74-eu.shelly.cloud", token: account_token())

      assert {:error, {:oauth_http, 503, _}} = Shelly.OAuth.refresh(account)
    end

    test "an account with no token cannot be refreshed" do
      client = Shelly.Client.new(server: "https://shelly-74-eu.shelly.cloud")
      assert Shelly.OAuth.refresh(client) == {:error, :no_token}
    end
  end
end
