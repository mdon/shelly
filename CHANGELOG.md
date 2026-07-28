# Changelog

## v0.1.0 (unreleased)

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
