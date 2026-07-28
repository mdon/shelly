defmodule Shelly do
  @moduledoc """
  Shelly smart-device client for Elixir — cloud APIs, real-time events,
  and component-aware status parsing across every hardware generation.

  Extracted from [NordSwitch](https://nordswitch.eu), where it drives a
  live fleet spanning Gen2 (Plus 1PM), Pro (Pro 3) and Gen4 hardware.

  ## The pieces

    * `Shelly.OAuth` — "connect your Shelly account" authorization-code
      flow; yields a long-lived token and the account's cloud server.
    * `Shelly.Account` — token-authorized account API: list all devices
      (names, models, channels), whole-account status in one call,
      relay control. **The recommended path** — no auth keys.
    * `Shelly.CloudV2` — auth-key API: bulk status (≤10 devices),
      switch/cover/light control, `toggle_after` watchdog.
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

      # 3. In your callback:
      {:ok, %{access_token: token, user_api_url: server}} =
        Shelly.OAuth.exchange_code(code)

      account = %{server: server, token: token}

      # 4. Devices + live data:
      {:ok, devices} = Shelly.Account.list_devices(account)
      {:ok, statuses} = Shelly.Account.all_statuses(account)

      parsed = Shelly.Status.parse(statuses["0cdc7ef76644"], 0, true)
      # => %{on: true, watts: 2.4, component: "switch", metered: true, ...}

      # 5. Control:
      :ok = Shelly.Account.set_relay(account, "0cdc7ef76644", 0, false)

  ## Field notes baked into this library

    * Cloud rate limit is ~1 request/second/account and it *will* 429
      concurrent bursts — hence `Shelly.RateGate`.
    * Gen1 relay energy counters count **Watt-minutes**; Gen1 emeters
      count real Wh. `Shelly.Status` converts appropriately.
    * Websocket events can be partial deltas — always guard with
      `Shelly.Status.has_component?/2` before parsing.
    * The v1 API is deprecated by Shelly; v2 accepts the same auth key.
    * OAuth tokens outlive everything except a password change.
  """
end
