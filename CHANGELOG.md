# Changelog

## v0.2.1

- **`Shelly.Events` delivered unusable device ids for live status events.**
  Shelly's websocket sends the device id as the *decimal* rendering of the
  hex id in a string (`"79530338915136"` for `485519999340`), and
  `normalize_device_id/1` only converted integers — a binary was merely
  downcased. Consumers matching that against their device ids found
  nothing, so every `StatusOnChange` was dropped and realtime silently
  degraded to whatever polling the caller had. Decimal strings now
  convert; a 12-character all-digit id is still treated as hex, since
  that is itself a valid id and only length distinguishes the two.

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
