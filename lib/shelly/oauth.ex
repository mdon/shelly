defmodule Shelly.OAuth do
  @moduledoc """
  Shelly Cloud OAuth (authorization-code) flow — the "connect your
  account" path that replaces auth keys entirely.

  Flow:

    1. Send the user to `authorize_url/2` (their popup shows Shelly's
       own login).
    2. Shelly redirects to your `redirect_uri` with a `code` param.
    3. `exchange_code/2` swaps it for a long-lived access token
       (invalidated only by a password change).

  The token authorizes the account API (`Shelly.Account`) as an
  `Authorization: Bearer` header and the real-time websocket
  (`Shelly.Events`).

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

  Returns `{:ok, %{access_token: token, user_api_url: url, label: label}}` —
  `user_api_url` is the account's home cloud server (read from the
  token's JWT claims), `label` a best-effort account identifier.
  """
  def exchange_code(code, client_id \\ @default_client_id) when is_binary(code) do
    server = server_from_jwt(code) || @fallback_server

    result =
      Req.request(
        method: :post,
        url: server <> "/oauth/auth",
        form: [grant_type: "code", code: code, client_id: client_id],
        receive_timeout: 15_000,
        retry: false
      )

    with {:ok, %{status: 200, body: body}} <- result,
         token when is_binary(token) <- extract_token(body) do
      claims = peek_jwt(token) || %{}
      api_url = normalize_url(claims["user_api_url"] || server)

      {:ok,
       %{
         access_token: token,
         user_api_url: api_url,
         label: claims["email"] || claims["user"] || URI.parse(api_url).host
       }}
    else
      {:ok, %{status: status, body: body}} -> {:error, {:oauth_http, status, body}}
      {:error, reason} -> {:error, reason}
      nil -> {:error, :no_token_in_response}
    end
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

  defp normalize_url(url) do
    if String.starts_with?(url, "http"), do: url, else: "https://" <> url
  end
end
