defmodule Shelly.OAuth do
  @moduledoc """
  Shelly Cloud OAuth (authorization-code) flow — the "connect your
  account" path that replaces auth keys entirely.

  Note: the flow is Shelly's own variant — the authorization code is
  itself a JWT whose (unverified) claims name the account's cloud
  server, and those claims are pinned to `https://*.shelly.cloud` before
  use. Shelly's authorization page does accept a `state` parameter and
  echoes it to your callback; pass one via `authorize_url/2` and compare
  it before calling `exchange_code/2` — it is the only CSRF binding this
  flow has.

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

  require Logger

  @default_client_id "shelly-diy"
  @login_url "https://my.shelly.cloud/oauth_login.html"
  @fallback_server "https://shelly-1-eu.shelly.cloud"

  @doc """
  URL to open (usually in a popup) to start the grant.

  Options:

    * `:state` — an opaque value Shelly echoes back to your callback.
      This library only passes it through: generate one per attempt
      (`Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)`),
      keep it in the user's session, and **compare it before calling
      `exchange_code/2`**. Without that comparison an attacker can feed
      your callback a code from a different account.
    * `:client_id` — defaults to `"shelly-diy"`.
  """
  @spec authorize_url(String.t(), keyword()) :: String.t()
  def authorize_url(redirect_uri, opts \\ [])

  def authorize_url(redirect_uri, opts) when is_list(opts) do
    query = [
      client_id: Keyword.get(opts, :client_id, @default_client_id),
      redirect_uri: redirect_uri
    ]

    query =
      case Keyword.get(opts, :state) do
        state when is_binary(state) and state != "" -> query ++ [state: state]
        _ -> query
      end

    @login_url <> "?" <> URI.encode_query(query)
  end

  # Kept for the 0.2.x positional form, which passed a client id.
  def authorize_url(redirect_uri, client_id) when is_binary(client_id),
    do: authorize_url(redirect_uri, client_id: client_id)

  @doc """
  Exchange an authorization code for an access token.

  Returns `{:ok, %Shelly.Client{}}` — ready to pass to `Shelly.Account`,
  `Shelly.Events` and `refresh/2`. The client's `:server` comes from the
  token's own JWT claims (the account's home cloud server), and `:label`
  is a best-effort account identifier.

  **Persist `:expires_at` and `:refresh_token`** — an access token that
  looks permanent stops working 12 hours in.
  """
  @spec exchange_code(String.t(), String.t()) :: {:ok, Shelly.Client.t()} | {:error, term()}
  def exchange_code(code, client_id \\ @default_client_id) when is_binary(code) do
    server = server_from_jwt(code) || @fallback_server

    result =
      Shelly.HTTP.request(
        method: :post,
        url: server <> "/oauth/auth",
        form: [grant_type: "code", code: code, client_id: client_id],
        receive_timeout: 15_000,
        retry: false
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

  Takes the client whose token is expiring and returns a fresh one,
  carrying the refresh token and expiry forward.

  Returns `{:ok, result}` shaped exactly like `exchange_code/2` when the
  server plays along, `{:error, :refresh_unsupported}` when it rejects
  the attempt (the expected outcome today — re-authorize the user
  instead), or `{:error, reason}` on transport failure.

      case Shelly.OAuth.refresh(client) do
        {:ok, refreshed} -> store(refreshed.token, refreshed.expires_at)
        {:error, :refresh_unsupported} -> ask_user_to_reconnect()
      end
  """
  @spec refresh(Shelly.Client.t(), String.t()) ::
          {:ok, Shelly.Client.t()} | {:error, :refresh_unsupported | :no_token | term()}
  def refresh(account, client_id \\ @default_client_id)

  def refresh(%Shelly.Client{server: server, token: token} = client, client_id)
      when is_binary(token) do
    refresh_token = client.refresh_token || token

    result =
      Shelly.HTTP.request(
        [
          method: :post,
          url: server <> "/oauth/auth",
          form: [grant_type: "refresh_token", refresh_token: refresh_token, client_id: client_id],
          receive_timeout: 15_000,
          retry: false
        ],
        client
      )

    case result do
      {:ok, %{status: 200, body: body}} ->
        case extract_token(body) do
          new_token when is_binary(new_token) ->
            {:ok, token_result(new_token, body, server, client)}

          # The server answered without refusing — reporting that as
          # "unsupported" sends the caller to re-authorize a live grant.
          nil ->
            {:error, :no_token_in_response}
        end

      # 429 and 408 mean "later", not "never" — reporting them as
      # unsupported would send the caller to re-authorize a grant that
      # is still perfectly good.
      {:ok, %{status: status, body: body}} when status in [408, 429] ->
        {:error, {:oauth_http, status, body}}

      {:ok, %{status: status}} when status in 400..499 ->
        {:error, :refresh_unsupported}

      {:ok, %{status: status, body: body}} ->
        {:error, {:oauth_http, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def refresh(_client, _client_id), do: {:error, :no_token}

  defp token_result(token, body, server, previous \\ nil) do
    claims = peek_jwt(token) || %{}
    api_url = normalize_url(claims["user_api_url"] || server)

    # A refresh keeps everything the previous client carried that the
    # response doesn't replace — including the auth key, the pacing key,
    # and a refresh token the server chose not to reissue.
    carried = carried_over(previous)

    Shelly.Client.new(
      Keyword.merge(carried,
        server: api_url,
        token: token,
        refresh_token: extract_refresh_token(body) || carried[:refresh_token],
        expires_at: expires_at(claims),
        label: claims["email"] || claims["user"] || URI.parse(api_url).host
      )
    )
  end

  defp carried_over(%Shelly.Client{} = previous) do
    [
      refresh_token: previous.refresh_token,
      auth_key: previous.auth_key,
      rate_key: previous.rate_key,
      req_options: previous.req_options
    ]
  end

  defp carried_over(_previous), do: []

  defp expires_at(%{"exp" => exp}) when is_integer(exp) do
    case DateTime.from_unix(exp) do
      {:ok, datetime} -> datetime
      _ -> nil
    end
  end

  defp expires_at(_claims), do: nil

  @doc "Read a JWT's payload without verification (routing only — do not trust)."
  @spec peek_jwt(String.t() | nil) :: map() | nil
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

  defp extract_refresh_token(%{"refresh_token" => t}), do: present(t)
  defp extract_refresh_token(%{"data" => %{"refresh_token" => t}}), do: present(t)
  defp extract_refresh_token(_), do: nil

  # An empty string is a binary, and used to sail through as a token —
  # producing a client that reports itself authorized and 401s forever.
  defp extract_token(%{"access_token" => t}), do: present(t)
  defp extract_token(%{"data" => %{"code" => t}}), do: present(t)
  defp extract_token(%{"data" => %{"access_token" => t}}), do: present(t)
  defp extract_token(_), do: nil

  defp present(value) when is_binary(value) and value != "", do: value
  defp present(_value), do: nil

  defp server_from_jwt(code) do
    case peek_jwt(code) do
      %{"user_api_url" => url} when is_binary(url) -> normalize_url(url)
      _ -> nil
    end
  end

  # Claims come from UNVERIFIED JWTs — pin the scheme to https and the
  # host to *.shelly.cloud before trusting them as a request target.
  # Hosts are matched case-insensitively (DNS is), and a non-string claim
  # returns the fallback instead of raising inside the grant. The suffix
  # check is deliberately on the parsed host, so userinfo tricks
  # ("https://evil.shelly.cloud@example.com") resolve to example.com and
  # fail closed.
  defp normalize_url(url) when is_binary(url) do
    uri = URI.parse(if String.contains?(url, "://"), do: url, else: "https://" <> url)
    host = if is_binary(uri.host), do: String.downcase(uri.host)

    if is_binary(host) and String.ends_with?(host, ".shelly.cloud") do
      # Keep a non-default port, the same rule Shelly.Client applies.
      "https://" <> host <> port_suffix(uri)
    else
      Logger.debug(fn -> "Shelly.OAuth: server claim #{inspect(url)} is not a Shelly host" end)
      @fallback_server
    end
  end

  defp normalize_url(_url), do: @fallback_server

  defp port_suffix(%URI{port: port, scheme: scheme}) do
    if is_nil(port) or port == URI.default_port(scheme || "https"), do: "", else: ":#{port}"
  end
end
