defmodule Shelly.OAuth do
  @moduledoc """
  Shelly Cloud OAuth (authorization-code) flow — the "connect your
  account" path that replaces auth keys entirely.

  Note: the flow is Shelly's own non-standard variant — there is no
  `state` parameter for CSRF binding, and the authorization code is
  itself a JWT whose (unverified) claims name the account's cloud
  server. Server claims are pinned to `https://*.shelly.cloud` before
  use.

  Flow:

    1. Send the user to `authorize_url/2` (their popup shows Shelly's
       own login).
    2. Shelly redirects to your `redirect_uri` with a `code` param.
    3. `exchange_code/2` swaps it for an access token.

  The token authorizes the account API (`Shelly.Account`) as an
  `Authorization: Bearer` header and the real-time websocket
  (`Shelly.Events`).

  ## Token lifetime

  **Access tokens expire.** Measured against a `shelly-diy` grant on a
  live account: `exp - iat = 43200` seconds — exactly 12 hours — after
  which every call (and the websocket) returns
  `401 invalid_token`. Read the deadline from `:expires_at` in the
  `exchange_code/2` result (or from the JWT's `exp` claim via
  `peek_jwt/1`) and renew *before* it passes, rather than treating the
  token as permanent.

  `refresh/2` attempts a renewal. Shelly does not document a refresh
  grant, so it is best-effort: it returns `{:error, :refresh_unsupported}`
  when the server rejects the attempt, and callers should fall back to
  sending the user through `authorize_url/2` again — or to a
  never-expiring auth key (`Shelly.CloudV2`) for HTTP polling and
  control.

  The default `shelly-diy` client id is for personal/DIY integrations;
  commercial integrators get their own via Shelly support
  (support@shelly.cloud).
  """

  @default_client_id "shelly-diy"
  @login_url "https://my.shelly.cloud/oauth_login.html"
  @fallback_server "https://shelly-1-eu.shelly.cloud"

  @doc "URL to open (usually in a popup) to start the grant."
  def authorize_url(redirect_uri, client_id \\ @default_client_id) do
    @login_url <> "?" <> URI.encode_query(client_id: client_id, redirect_uri: redirect_uri)
  end

  @doc """
  Exchange an authorization code for an access token.

  Returns `{:ok, %{access_token: token, refresh_token: refresh, expires_at:
  datetime, user_api_url: url, label: label}}` — `user_api_url` is the
  account's home cloud server (read from the token's JWT claims),
  `label` a best-effort account identifier.

  `:expires_at` is a `DateTime` derived from the token's `exp` claim
  (`nil` if the token carries no expiry); `:refresh_token` is whatever
  the server returned under `refresh_token`, or `nil`. **Persist both** —
  a token that looks permanent stops working 12 hours in.
  """
  def exchange_code(code, client_id \\ @default_client_id) when is_binary(code) do
    server = server_from_jwt(code) || @fallback_server

    result =
      Req.request(
        [
          method: :post,
          url: server <> "/oauth/auth",
          form: [grant_type: "code", code: code, client_id: client_id],
          receive_timeout: 15_000,
          retry: false
        ] ++ req_options()
      )

    with {:ok, %{status: 200, body: body}} <- result,
         token when is_binary(token) <- extract_token(body) do
      {:ok, token_result(token, body, server)}
    else
      {:ok, %{status: status, body: body}} -> {:error, {:oauth_http, status, body}}
      {:error, reason} -> {:error, reason}
      nil -> {:error, :no_token_in_response}
    end
  end

  @doc """
  Best-effort renewal of an access token that is about to expire.

  Shelly publishes no refresh grant for the Cloud Control API, so this
  tries the conventional one (`grant_type=refresh_token`) against the
  account's own server, sending the stored refresh token when there is
  one and the current access token otherwise.

  Takes the same account map as the rest of the library
  (`%{server: url, token: token}`, e.g. from `to_account/1`), plus an
  optional `:refresh_token`.

  Returns `{:ok, result}` shaped exactly like `exchange_code/2` when the
  server plays along, `{:error, :refresh_unsupported}` when it rejects
  the attempt (the expected outcome today — re-authorize the user
  instead), or `{:error, reason}` on transport failure.

      case Shelly.OAuth.refresh(account) do
        {:ok, %{access_token: token, expires_at: at}} -> store(token, at)
        {:error, :refresh_unsupported} -> ask_user_to_reconnect()
      end
  """
  def refresh(account, client_id \\ @default_client_id)

  def refresh(%{server: server, token: token} = account, client_id) when is_binary(token) do
    refresh_token = Map.get(account, :refresh_token) || token

    result =
      Req.request(
        [
          method: :post,
          url: server <> "/oauth/auth",
          form: [grant_type: "refresh_token", refresh_token: refresh_token, client_id: client_id],
          receive_timeout: 15_000,
          retry: false
        ] ++ req_options()
      )

    case result do
      {:ok, %{status: 200, body: body}} ->
        case extract_token(body) do
          new_token when is_binary(new_token) -> {:ok, token_result(new_token, body, server)}
          nil -> {:error, :refresh_unsupported}
        end

      {:ok, %{status: status}} when status in 400..499 ->
        {:error, :refresh_unsupported}

      {:ok, %{status: status, body: body}} ->
        {:error, {:oauth_http, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def refresh(_account, _client_id), do: {:error, :no_token}

  defp token_result(token, body, server) do
    claims = peek_jwt(token) || %{}
    api_url = normalize_url(claims["user_api_url"] || server)

    %{
      access_token: token,
      refresh_token: extract_refresh_token(body),
      expires_at: expires_at(claims),
      user_api_url: api_url,
      label: claims["email"] || claims["user"] || URI.parse(api_url).host
    }
  end

  defp expires_at(%{"exp" => exp}) when is_integer(exp) do
    case DateTime.from_unix(exp) do
      {:ok, datetime} -> datetime
      _ -> nil
    end
  end

  defp expires_at(_claims), do: nil

  @doc """
  Convert an `exchange_code/2` result into the account map that
  `Shelly.Account` and `Shelly.Events` take.
  """
  def to_account(%{access_token: token, user_api_url: url}) do
    %{server: url, token: token}
  end

  @doc "Read a JWT's payload without verification (routing only — do not trust)."
  def peek_jwt(token) when is_binary(token) do
    with [_, payload, _] <- String.split(token, "."),
         {:ok, json} <- Base.url_decode64(payload, padding: false),
         {:ok, map} <- Jason.decode(json) do
      map
    else
      _ -> nil
    end
  end

  def peek_jwt(_), do: nil

  # Extra options merged into every token request. Exists so tests can
  # pass a `:plug` stub instead of reaching the network; also a hook for
  # consumers that need a proxy or custom timeouts.
  defp req_options, do: Application.get_env(:shelly, :req_options, [])

  defp extract_refresh_token(%{"refresh_token" => t}) when is_binary(t), do: t
  defp extract_refresh_token(%{"data" => %{"refresh_token" => t}}) when is_binary(t), do: t
  defp extract_refresh_token(_), do: nil

  defp extract_token(%{"access_token" => t}) when is_binary(t), do: t
  defp extract_token(%{"data" => %{"code" => t}}) when is_binary(t), do: t
  defp extract_token(%{"data" => %{"access_token" => t}}) when is_binary(t), do: t
  defp extract_token(_), do: nil

  defp server_from_jwt(code) do
    case peek_jwt(code) do
      %{"user_api_url" => url} when is_binary(url) -> normalize_url(url)
      _ -> nil
    end
  end

  # Claims come from UNVERIFIED JWTs — pin the scheme to https and the
  # host to *.shelly.cloud before trusting them as a request target.
  defp normalize_url(url) do
    uri = URI.parse(if String.contains?(url, "://"), do: url, else: "https://" <> url)

    if is_binary(uri.host) and String.ends_with?(uri.host, ".shelly.cloud") do
      "https://" <> uri.host
    else
      @fallback_server
    end
  end
end
