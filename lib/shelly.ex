defmodule Shelly do
  @moduledoc """
  Shelly smart-device client for Elixir — cloud APIs, real-time events,
  and component-aware status parsing across every hardware generation.

  Extracted from [NordSwitch](https://nordswitch.eu), where it drives a
  live fleet spanning Gen2 (Plus 1PM), Pro (Pro 3) and Gen4 hardware.

  ## The pieces

    * `Shelly.Client` — one struct holding an account's server,
      credentials and pacing key. Everything else takes one.
    * `Shelly.OAuth` — "connect your Shelly account" authorization-code
      flow; yields a client whose access token lasts **12 hours**.
    * `Shelly.Account` — token-authorized account API: list all devices
      (names, models, channels), whole-account status in one call,
      relay control. **The recommended path** — no auth keys.
    * `Shelly.CloudV2` — auth-key API: bulk status (≤10 devices),
      switch/cover/light control, `toggle_after` watchdog. The key
      doesn't expire, so this keeps working when a token lapses.
    * `Shelly.CloudV1` — the deprecated legacy API, kept as a fallback.
    * `Shelly.Events` — real-time websocket per account with a handler
      callback (status changes, online transitions).
    * `Shelly.Status` — one parser for every payload shape: Gen2/3/4
      RPC components (switch/cover/light/CCT/RGB(W)/PM1/EM/EM1, flood,
      smoke, presence, temperature/humidity sensors, voltmeter,
      devicepower) and Gen1 arrays (relays with Watt-minute counters,
      lights, rollers, emeters, battery sensors). Reports `component`
      and `metered` so a relay without power metering is never mistaken
      for one drawing 0 W.
    * `Shelly.RateGate` — per-account request pacing (the cloud 429s
      beyond ~1 req/s/account); add it to your supervision tree.

  ## Quick start (OAuth path)

      # 1. In your supervision tree:
      children = [Shelly.RateGate]

      # 2. Send the user to Shelly's login:
      Shelly.OAuth.authorize_url("https://myapp.example/oauth/callback")

      # 3. In your callback — this hands back a ready client:
      {:ok, client} = Shelly.OAuth.exchange_code(code)

      # Persist client.token, client.expires_at and client.refresh_token,
      # and give the client a stable pacing key once you have an id:
      client = Shelly.Client.put_rate_key(client, account.id)

      # 4. Devices + live data:
      {:ok, devices} = Shelly.Account.list_devices(client)
      {:ok, statuses} = Shelly.Account.all_statuses(client)

      parsed = Shelly.Account.parse_status(statuses["0cdc7ef76644"], 0)
      # => %{on: true, watts: 2.4, component: "switch", metered: true, ...}

      # 5. Control:
      :ok = Shelly.Account.set_switch(client, "0cdc7ef76644", 0, false)

      # 6. Realtime:
      {:ok, _pid} = Shelly.Events.start_link(client, handler: &handle_event/1)

  ## Surviving token expiry

  Attach the account's auth key and control keeps working after the
  12-hour token dies — only realtime and device discovery need OAuth:

      client = Shelly.Client.put_auth_key(client, key)

      if Shelly.Client.token_expired?(client) do
        Shelly.CloudV2.set_switch(client, id, 0, true)
      else
        Shelly.Account.set_switch(client, id, 0, true)
      end

  ## Field notes baked into this library

    * Cloud rate limit is ~1 request/second/account and it *will* 429
      concurrent bursts — hence `Shelly.RateGate`.
    * Gen1 relay energy counters count **Watt-minutes**; Gen1 emeters
      count real Wh. `Shelly.Status` converts appropriately.
    * Websocket events can be partial deltas — guard with
      `Shelly.Status.has_component?/2` (or compare
      `Shelly.Status.component_of/2` against the device's known
      component) before parsing. A component can also arrive without its
      state key, in which case `:on` is `nil`, meaning *unknown* rather
      than off.
    * The v1 API is deprecated by Shelly; v2 accepts the same auth key.
    * **OAuth access tokens last 12 hours** (`exp - iat = 43200`,
      measured twice on live accounts). Shelly publishes no refresh
      grant, but `Shelly.OAuth.refresh/2` works against a token that is
      still live — a fleet renewing itself every ~11 hours ran unattended
      for days. Persist `:expires_at` and renew ahead of it; an **expired**
      token cannot be refreshed, only re-authorized. An auth key does not
      expire at all, which is what covers your app being down across a
      deadline.
    * Device ids arrive as hex, as integers, and as decimal strings —
      normalize with `Shelly.Events.normalize_device_id/1` before
      matching anything.
  """
end
