defmodule Shelly.Client do
  @moduledoc """
  Everything needed to talk to one Shelly account: where it lives, how to
  authenticate, how to pace requests.

  Every function in this library takes one of these. There are two ways
  to authenticate and a client can hold both:

    * **OAuth** (`:token`) — the "connect your account" path. Authorizes
      the account API (`Shelly.Account`) and the realtime websocket
      (`Shelly.Events`), and **expires after 12 hours**.
    * **Auth key** (`:auth_key`) — the classic per-account key from the
      Shelly app. Authorizes `Shelly.CloudV2` / `Shelly.CloudV1`, and
      does not expire.

  Holding both is the useful combination: realtime and discovery run on
  the token, and control keeps working through its expiry on the key.

      client = Shelly.OAuth.exchange_code(code) |> then(fn {:ok, c} -> c end)
      client = Shelly.Client.put_auth_key(client, "MWFmZTNm…")

      Shelly.Client.expired?(client)
      #=> false

  ## Rate limiting

  Shelly's ~1 request/second budget is **per account**, shared by both
  transports. `:rate_key` is what `Shelly.RateGate` paces on; it defaults
  to the credential, which means a token refresh would start a fresh
  budget and let a burst through. Set it to something stable — your own
  account id — as soon as you have one:

      Shelly.Client.new(server: url, token: token, rate_key: account.id)

  ## Request options

  `:req_options` is merged into every HTTP call this client makes —
  proxies, timeouts, or a `:plug` stub in tests.
  """

  @enforce_keys [:server]
  defstruct [
    :server,
    :token,
    :refresh_token,
    :expires_at,
    :auth_key,
    :label,
    :rate_key,
    req_options: []
  ]

  @type t :: %__MODULE__{
          server: String.t(),
          token: String.t() | nil,
          refresh_token: String.t() | nil,
          expires_at: DateTime.t() | nil,
          auth_key: String.t() | nil,
          label: String.t() | nil,
          rate_key: term(),
          req_options: keyword()
        }

  @doc """
  Build a client. `:server` is required; everything else is optional, so
  a key-only client is `new(server: url, auth_key: key)` and an
  OAuth-only one is `new(server: url, token: token)`.

  The server is normalized to `https://host`.
  """
  @spec new(keyword() | map()) :: t()
  def new(attrs) do
    attrs = Map.new(attrs)

    server =
      attrs
      |> Map.get(:server)
      |> normalize_server()

    %__MODULE__{
      server: server,
      token: Map.get(attrs, :token),
      refresh_token: Map.get(attrs, :refresh_token),
      expires_at: Map.get(attrs, :expires_at),
      auth_key: Map.get(attrs, :auth_key),
      label: Map.get(attrs, :label),
      rate_key: Map.get(attrs, :rate_key),
      req_options: Map.get(attrs, :req_options, [])
    }
  end

  @doc "Attach (or replace) the never-expiring auth key."
  @spec put_auth_key(t(), String.t() | nil) :: t()
  def put_auth_key(%__MODULE__{} = client, auth_key), do: %{client | auth_key: auth_key}

  @doc "Attach a stable pacing key — see the rate-limiting note above."
  @spec put_rate_key(t(), term()) :: t()
  def put_rate_key(%__MODULE__{} = client, rate_key), do: %{client | rate_key: rate_key}

  @doc "Merge extra Req options (proxy, timeouts, a `:plug` stub)."
  @spec put_req_options(t(), keyword()) :: t()
  def put_req_options(%__MODULE__{} = client, options) when is_list(options),
    do: %{client | req_options: Keyword.merge(client.req_options, options)}

  @doc "Can this client use the OAuth paths (account API, websocket)?"
  @spec oauth?(t()) :: boolean()
  def oauth?(%__MODULE__{token: token}), do: is_binary(token)

  @doc "Can this client use the auth-key paths (v2/v1)?"
  @spec keyed?(t()) :: boolean()
  def keyed?(%__MODULE__{auth_key: auth_key}), do: is_binary(auth_key)

  @doc """
  Has the access token passed its expiry?

  A client with no token is expired by definition; one whose expiry was
  never recorded is assumed live, since the cloud is the real authority.
  """
  @spec expired?(t()) :: boolean()
  def expired?(%__MODULE__{token: nil}), do: true
  def expired?(%__MODULE__{expires_at: nil}), do: false

  def expired?(%__MODULE__{expires_at: expires_at}),
    do: DateTime.compare(expires_at, DateTime.utc_now()) != :gt

  @doc "Seconds until the token expires (negative once it has), or `nil`."
  @spec expires_in(t()) :: integer() | nil
  def expires_in(%__MODULE__{expires_at: nil}), do: nil
  def expires_in(%__MODULE__{expires_at: at}), do: DateTime.diff(at, DateTime.utc_now())

  @doc false
  # What RateGate paces on. One account is one budget: without an explicit
  # rate_key the credential stands in, so refreshing a token silently
  # starts a new budget.
  @spec rate_key(t()) :: term()
  def rate_key(%__MODULE__{rate_key: nil} = client),
    do: {client.server, client.token || client.auth_key}

  def rate_key(%__MODULE__{rate_key: key}), do: {:shelly_account, key}

  # Normalizes to https://host[:port]. The port is kept — dropping it
  # silently redirected anything on a non-default port (a proxy, a local
  # test server) to 443.
  defp normalize_server(server) when is_binary(server) do
    uri = URI.parse(if String.contains?(server, "://"), do: server, else: "https://" <> server)

    case uri.host do
      nil -> server
      host -> "https://" <> String.downcase(host) <> port_suffix(uri)
    end
  end

  defp normalize_server(server) do
    raise ArgumentError, "Shelly.Client needs a :server URL, got: #{inspect(server)}"
  end

  defp port_suffix(%URI{port: port}) when port in [nil, 443], do: ""
  defp port_suffix(%URI{port: port}), do: ":#{port}"
end
