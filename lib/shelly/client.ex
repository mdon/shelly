defmodule Shelly.Client do
  require Logger

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

      Shelly.Client.token_expired?(client)
      #=> false

  ## One server per client

  Both credentials address the same `:server`. Shelly issues an auth key
  together with its own server URI, and an OAuth token names its server
  in the JWT — for one account those are the same host, which is why this
  struct holds one. If you ever meet an account whose key and token live
  on different endpoints, build two clients rather than expecting
  `put_auth_key/2` to carry a second address.

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
      # Trimmed on the way in: a padded credential passed `usable?` and
      # then went out on the wire as `Bearer   tok  `.
      token: credential(Map.get(attrs, :token)),
      refresh_token: credential(Map.get(attrs, :refresh_token)),
      expires_at: expires_at(Map.get(attrs, :expires_at)),
      auth_key: credential(Map.get(attrs, :auth_key)),
      label: Map.get(attrs, :label),
      rate_key: Map.get(attrs, :rate_key),
      req_options: req_options(Map.get(attrs, :req_options, []))
    }
  end

  @doc "Attach (or replace) the never-expiring auth key."
  @spec put_auth_key(t(), String.t() | nil) :: t()
  def put_auth_key(%__MODULE__{} = client, auth_key),
    do: %{client | auth_key: credential(auth_key)}

  @doc "Attach a stable pacing key — see the rate-limiting note above."
  @spec put_rate_key(t(), term()) :: t()
  def put_rate_key(%__MODULE__{} = client, rate_key), do: %{client | rate_key: rate_key}

  @doc "Merge extra Req options (proxy, timeouts, a `:plug` stub)."
  @spec put_req_options(t(), keyword()) :: t()
  def put_req_options(%__MODULE__{} = client, options) do
    unless Keyword.keyword?(options) do
      raise ArgumentError, ":req_options must be a keyword list, got: #{inspect(options)}"
    end

    %{client | req_options: Keyword.merge(client.req_options, options)}
  end

  @doc "Can this client use the OAuth paths (account API, websocket)?"
  @spec oauth?(t()) :: boolean()
  def oauth?(%__MODULE__{token: token}), do: usable_credential?(token)

  @doc "Can this client use the auth-key paths (v2/v1)?"
  @spec keyed?(t()) :: boolean()
  def keyed?(%__MODULE__{auth_key: auth_key}), do: usable_credential?(auth_key)

  @doc """
  Is this client's OAuth token unusable — absent or past its expiry?

  Named for the token rather than the client because a key-only client
  answers `true` here and is nonetheless fully functional: that is the
  point. `if token_expired?(client), do: CloudV2, else: Account` routes
  both a lapsed token and a key-only client to the path that works.

  A client whose expiry was never recorded is assumed live, since the
  cloud is the real authority. Note the trap: a token whose JWT cannot be
  parsed leaves `:expires_at` `nil`, so this answers `false` forever — a
  renewal loop driven only off this will never fire. Record the expiry
  when you store the token.
  """
  @spec token_expired?(t()) :: boolean()
  def token_expired?(%__MODULE__{} = client) do
    cond do
      # Must agree with oauth?/1: a token this client would refuse to send
      # cannot be "not expired", or the documented routing picks the path
      # that then answers {:error, :no_token}.
      not usable_credential?(client.token) -> true
      is_nil(client.expires_at) -> false
      true -> DateTime.compare(client.expires_at, DateTime.utc_now()) != :gt
    end
  end

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
  # Blank is not a credential — and neither is whitespace, which is what
  # a mis-trimmed environment variable or a copy-pasted key looks like.
  defp usable_credential?(value) when is_binary(value), do: String.trim(value) != ""
  defp usable_credential?(_value), do: false

  # Stored trimmed, or not stored at all — so "usable" and "what is sent"
  # can never disagree.
  defp credential(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp credential(_value), do: nil

  defp req_options(options) do
    if Keyword.keyword?(options) do
      options
    else
      raise ArgumentError, ":req_options must be a keyword list, got: #{inspect(options)}"
    end
  end

  defp expires_at(nil), do: nil
  defp expires_at(%DateTime{} = at), do: at

  defp expires_at(other) do
    raise ArgumentError,
          "Shelly.Client :expires_at must be a DateTime or nil, got: #{inspect(other)}"
  end

  defp normalize_server(server) when is_binary(server) do
    uri = URI.parse(if String.contains?(server, "://"), do: server, else: "https://" <> server)

    case uri.host do
      host when is_binary(host) and host != "" ->
        warn_dropped_path(uri, server)
        "https://" <> render_host(String.downcase(host)) <> port_suffix(uri)

      _ ->
        raise ArgumentError, "Shelly.Client could not read a host from server: #{inspect(server)}"
    end
  end

  defp normalize_server(server) do
    raise ArgumentError, "Shelly.Client needs a :server URL, got: #{inspect(server)}"
  end

  # Keep a genuinely custom port, but drop the one URI.parse/1 filled in
  # from the *source* scheme: "http://host" arrives with port 80, and
  # carrying that onto an https URL sends every request to :80.
  # Requests are built from `server <> "/device/..."`, so a base path
  # would be lost. Saying so beats a proxy silently receiving requests at
  # the wrong path.
  defp warn_dropped_path(%URI{path: path}, server) when path not in [nil, "", "/"] do
    Logger.warning(
      "Shelly.Client: ignoring the path in #{inspect(server)} — a server is scheme, host and port"
    )
  end

  defp warn_dropped_path(_uri, _server), do: :ok

  defp port_suffix(%URI{port: port, scheme: scheme}) do
    if is_nil(port) or port == URI.default_port(scheme || "https"), do: "", else: ":#{port}"
  end

  # URI.parse strips the brackets from an IPv6 host; without them back the
  # authority is unparseable.
  defp render_host(host) do
    if String.contains?(host, ":"), do: "[#{host}]", else: host
  end
end
