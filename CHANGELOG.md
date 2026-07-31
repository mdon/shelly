# Changelog

## v0.2.1

A pre-publish review (six external models plus a verification pass against
Shelly's own API docs) found that the decimal-id fix this release was
written for was **half a fix**, and turned up eight more defects of the same
family: a lookup or a shape assumption that quietly produces a plausible
wrong answer instead of an error.

### Fixed — device identity

- **`Events.normalize_device_id/1` missed Gen1 ids entirely.** Shelly's spec
  pins hex ids to 6 (Gen1) or 12 characters; the decimal form of a 6-char id
  is 8 digits, so the previous "longer than 12" rule left it untouched and
  every Gen1 event was dropped — the exact failure this release exists to fix.
  Conversion is now driven by the documented widths, and integer and string
  forms of one id resolve to the same key (they previously differed by
  padding: `"000000b923fa"` vs `"b923fa"`).

### Fixed — protocol contracts

- **`Account.all_statuses/1` keyed results by a field Shelly documents as
  unreliable.** The vendor says the `devices_status` keys "should be ignored";
  entries are now keyed by `_dev_info.id`, with the outer key as fallback.
- **`Account.parse_status/2` read online state from `cloud.connected`**, a
  component only mains-powered Gen2+ devices carry, so every battery, Gen1
  and virtual device was reported offline. It now reads `_dev_info.online`.
- **`CloudV1.get_status/2` returned the response wrapper**, not the
  `device_status` its own docs told you to parse — yielding a device that
  looked permanently off. It now returns `{:ok, {device_status, online}}`.

### Fixed — status parsing

- **A component without its state key is no longer reported as off.** A
  websocket delta like `%{"switch:0" => %{"apower" => 15.0}}` passes both
  guards but says nothing about the relay; `:on` is now `nil` (unknown)
  instead of a confident `false`. On price-driven heating, a false OFF is
  the expensive direction.
- **Gen1 3EM: phases 1 and 2 parsed as an unmetered relay at 0 W.** Gen1
  arrays were dispatched on existence rather than on holding the requested
  channel, so a device with one relay and three emeters answered "relay" for
  every channel — while the library's own `component_of/2` said "em".
- **`component_of/2` and `parse/4` disagreed on Gen1 alarms** ("sensor" vs
  "flood"/"smoke"/"presence"). The documented guard pattern — store the
  parsed component, compare later events against `component_of/2` — dropped
  every event from those devices.
- **Gen2 covers ignored `current_pos`**, so a cover stopped at the closed end
  (and any uncalibrated cover, which reports "stopped" forever) read as open.
  Position now decides, matching the Gen1 roller path.
- **Humidity was never extracted**, despite being advertised in the docs.
  `:humidity` is now part of the parsed status.
- **Sensor add-ons on non-zero channels were invisible**: battery, temperature
  and humidity enrichment only ever looked at channel 0.
- **Pro 3EM energy was permanently `nil`** — it lives in the sibling
  `em1data:N` / `emdata:0` components.
- **Gen1 rollers discarded their energy counter**; the original Shelly 2's
  single shared meter left channel 1 looking unmetered; a Gen1 Door/Window
  sensor always read closed.

### Fixed — safety and robustness

- `OAuth.to_account/1` dropped `:refresh_token` and `:expires_at`, so
  following the documented path sent the *access* token to `refresh/2` as
  the refresh token.
- `OAuth.refresh/2` reported **429 and 408 as `:refresh_unsupported`**,
  telling callers to re-authorize a perfectly good grant because they were
  merely rate limited.
- The `*.shelly.cloud` host pin was case-sensitive, so an uppercase claim
  silently rerouted to the fallback server. (The pin itself was probed for
  userinfo, suffix, port and path bypasses and holds.)
- `Events.start_link/1` no longer returns WebSockex's URL error verbatim
  (it embeds the connection URL, which carries the access token); an
  unusable server address comes back as `{:error, :invalid_server_url}`.
- An `Online` event with no readable flag is no longer reported as offline —
  a missing field is not evidence that a device is down.
- A scalar `"device"` value in an event used to raise inside `get_in/2`,
  outside the handler's rescue, killing the socket process.
- Every dropped event now logs at debug with the id and the message keys.
  Silence in those branches is what let the decimal-id bug hide.

### Changed

- **Request options are per call.** `:req_options` on an account or conn map
  is merged into every request for `Account`, `CloudV1`, `CloudV2` and
  `OAuth` — previously only OAuth honoured it, and only globally, so nothing
  else could be proxied, re-timed or stubbed. The global
  `config :shelly, :req_options` still works as a fallback.
- **`:rate_key`** on an account or conn map gives one pacing budget per
  account across transports and across token refreshes; without it the
  credential is still the key, which meant a token refresh silently reset
  the budget.
- Docs: the root module no longer describes access tokens as long-lived
  (they last 12 hours), and `Events`' moduledoc no longer claims string ids
  pass through unchanged.

### Tests

40 → 107. New: an agreement matrix asserting `parse/4`, `has_component?/2`
and `component_of/2` give one answer for 29 payload shapes (this catches the
whole drift class at once), partial-delta behaviour, the Gen1 6-character id
forms, and the first HTTP-level tests for `Account`.

## v0.2.0

Token lifetime work, driven by a live account going dark: a `shelly-diy`
access token turned out to last exactly 12 hours (`exp - iat = 43200`),
after which every HTTP call returns `401 invalid_token` and the
websocket is closed right after the handshake.

- `Shelly.OAuth.exchange_code/2` now returns `:refresh_token` and
  `:expires_at` (parsed from the token's `exp` claim) alongside the
  access token. Previously both were discarded, leaving callers no way
  to see expiry coming. **Persist them.**
- `Shelly.OAuth.refresh/2` — best-effort renewal via the conventional
  `grant_type=refresh_token`. Shelly documents no refresh grant, so a
  4xx is reported as `{:error, :refresh_unsupported}` and the caller
  should re-authorize the user (or fall back to an auth key, which does
  not expire, for polling and control).
- `Shelly.Events` no longer reconnects forever against a dead token.
  Resetting the attempt counter in `handle_connect/2` made the cap
  unreachable whenever the handshake succeeded and the session was
  dropped immediately; the counter now clears only after a session has
  held for a minute.
- Token requests accept extra Req options via
  `config :shelly, :req_options` (the seam the new tests use).
- Docs: the module no longer describes the access token as long-lived.

## v0.1.0

Initial release, extracted from NordSwitch (nordswitch.eu) where the
OAuth/account/v2 paths and switch parsing run against a live mixed
Gen2/Pro/Gen4 fleet.

- `Shelly.OAuth` — authorization-code flow (server claims pinned to
  `https://*.shelly.cloud`), `to_account/1` bridge.
- `Shelly.Account` — Bearer-token account API: device list with
  per-channel expansion, whole-account status in one call,
  `parse_status/2`, switch control.
- `Shelly.CloudV2` — auth-key API: bulk status (≤10 ids),
  switch/cover/light control, `toggle_after` watchdog.
- `Shelly.CloudV1` — deprecated legacy endpoints (fallback).
- `Shelly.Events` — real-time websocket per account: handler callback,
  id normalization, jittered exponential reconnect with attempt cap,
  token-redacting logs.
- `Shelly.Status` — component-aware parser for Gen1–Gen4 payloads
  (switch/cover/light/CCT/RGB(W)/pm1/em/em1, flood, smoke, presence,
  temperature/humidity, voltmeter; Gen1 relays/lights/rollers/emeters
  and battery sensors), `metered`/`component` reporting,
  `has_component?/2` + `component_of/2` partial-delta guards, battery
  and sensor-temperature enrichment.
- `Shelly.RateGate` — per-account pacing (~1 req/s) with backlog cap
  (`{:error, :throttled}`) and key pruning.

Pre-publish review by a multi-model quorum (Gemini, Grok, Kimi, ZAI,
Vibe); findings incorporated.
