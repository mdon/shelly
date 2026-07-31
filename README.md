# Shelly

Shelly smart-device client for Elixir: cloud APIs (OAuth account access,
auth-key v2, legacy v1), real-time websocket events, and component-aware
status parsing across Gen1–Gen4 hardware.

Extracted from [NordSwitch](https://nordswitch.eu) (Nord Pool
price-driven switching), where it runs a live mixed fleet — Plus 1PM,
Pro 3, Gen4 switches — in production.

## Installation

```elixir
def deps do
  [
    {:shelly, "~> 0.2"}
  ]
end
```

Add the rate gate to your supervision tree (the Shelly cloud allows
~1 request/second/account and 429s bursts; the gate defaults to a
slightly padded 1.2 s spacing):

```elixir
children = [
  Shelly.RateGate,
  ...
]
```

## The no-keys path (recommended)

```elixir
# Send the user to Shelly's own login (popup works well):
Shelly.OAuth.authorize_url("https://myapp.example/oauth/callback")

# In your callback, exchange the ?code= param — you get a ready client:
{:ok, client} = Shelly.OAuth.exchange_code(code)

# Persist client.token, client.expires_at and client.refresh_token: an
# access token lasts 12 hours, after which everything below returns 401.
# Renew with Shelly.OAuth.refresh/2 before the deadline, and treat
# {:error, :refresh_unsupported} as "send the user through the login
# again" (auth keys, further down, never expire).

# Rate limiting is per account, so give the client a stable pacing key
# rather than letting the credential stand in for one:
client = Shelly.Client.put_rate_key(client, account.id)

# Every device on the account — user-given names, models, channel counts:
{:ok, devices} = Shelly.Account.list_devices(client)
rows = Shelly.Account.expand_channels(devices)

# Whole-account status in ONE call:
{:ok, statuses} = Shelly.Account.all_statuses(client)
parsed = Shelly.Account.parse_status(statuses["0cdc7ef76644"], 0)
# => %{on: true, watts: 2.4, voltage: 230.4, energy_wh: 2265635.7,
#      temp_c: 55.9, rssi: -66, component: "switch", metered: true, ...}

# Control:
:ok = Shelly.Account.set_switch(client, "0cdc7ef76644", 0, false)
```

## Real-time events

```elixir
Shelly.Events.start_link(client,
  handler: fn
    {:status, device_id, status} ->
      # Guard: events may be partial deltas (only sys/input/battery
      # changed). When you know the device's component, compare it:
      if Shelly.Status.component_of(status, 0) == "switch" do
        MyApp.apply(device_id, Shelly.Status.parse(status, 0, true))
      end

    {:online, device_id, online?} ->
      MyApp.set_online(device_id, online?)

    {:other, _message} ->
      :ok
  end
)
```

A parsed status reports `on: nil` when the payload named the component
but carried no state for it — unknown, not off. Treat it as "keep what
you know".

## Auth-key APIs, and surviving expiry

The classic auth key (Shelly app → Settings → User Settings → Access And
Permissions → "Get key" — key and server are shown together) authorizes
the v2/v1 APIs and never expires:

```elixir
client = Shelly.Client.new(server: "https://shelly-XX-eu.shelly.cloud", auth_key: key)

{:ok, by_id} = Shelly.CloudV2.get_statuses(client, [id1, id2])   # ≤ 10 ids
:ok = Shelly.CloudV2.set_switch(client, id1, 0, true, toggle_after: 7200)
```

`toggle_after` is a watchdog executed by Shelly's own cloud — the relay
reverts even if your app is down. `Shelly.CloudV1` exists as a fallback
for the deprecated legacy endpoints.

One client can hold both credentials, which is how you keep control
working through a token expiry — only realtime and device discovery
genuinely need OAuth:

```elixir
client = Shelly.Client.put_auth_key(oauth_client, key)

if Shelly.Client.expired?(client) do
  Shelly.CloudV2.set_switch(client, id, 0, true)   # key path, still fine
else
  Shelly.Account.set_switch(client, id, 0, true)
end
```

## What the parser understands

Gen2/3/4 RPC components: `switch`, `cover`, `light`, `cct`/`rgb`/
`rgbw`/`rgbcct`, `pm1`, `em`/`em1` (metering-only — never mistaken for
switches), `flood`/`smoke` (on = alarm), `presence`, `temperature`/
`humidity` sensor devices, `voltmeter`, `devicepower` (battery rides
alongside any component). Gen1 arrays: `relays`+`meters` (Watt-minute
counters converted), `lights`, `rollers`, `emeters` (real Wh), and
battery sensor payloads (`tmp`/`hum`/`bat`/`flood`/`smoke`/`motion`).

Every parse reports `component` and `metered`, so an unmetered relay's
"0 W" is distinguishable from a measured zero. Unknown shapes degrade to
`component: "unknown"` with the full payload preserved under `:raw`.

## Status

Young but battle-fed: the OAuth/account/v2 paths and the parser's
switch handling run in production against real hardware; cover, light,
sensor and Gen1 branches are built to the official documentation and
awaiting first contact. Issues and payload samples welcome.

## License

MIT
