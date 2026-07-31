# Changelog

## v0.3.0

Credentials became a struct. Every function previously took an ad-hoc map
(`%{server:, token:}` for OAuth, `%{server:, auth_key:}` for the key APIs,
plus optional `:rate_key` / `:req_options` keys nothing declared), which
left the shape of the library's central concept implied rather than
stated. **`Shelly.Client` now is that concept**, and every entry point
takes one.

Breaking, deliberately: 0.2.x had no users to protect, and this is far
cheaper to change now than after it sets.

```elixir
{:ok, client} = Shelly.OAuth.exchange_code(code)
client = Shelly.Client.put_rate_key(client, account.id)

{:ok, statuses} = Shelly.Account.all_statuses(client)
{:ok, _pid} = Shelly.Events.start_link(client, handler: &handle/1)
```

- `Shelly.OAuth.exchange_code/2` and `refresh/2` return a client instead
  of a bare grant map; `to_account/1` is gone, since the client *is* the
  account. A refresh now carries the auth key, pacing key and request
  options forward, and no longer wipes a stored refresh token when the
  server declines to reissue one.
- `Shelly.Account`, `Shelly.CloudV1` and `Shelly.CloudV2` take a client.
  One client can hold **both** credentials, which is how control survives
  a token expiry: realtime and discovery need OAuth, switching doesn't.
- `Shelly.Events.start_link/2` takes a client rather than loose
  `:server`/`:token` options, and returns `{:error, :no_token}` for a
  key-only client instead of opening a socket that can't authenticate.
- New: `Shelly.Client.token_expired?/1`, `expires_in/1`, `oauth?/1`, `keyed?/1`,
  `put_auth_key/2`, `put_rate_key/2`, `put_req_options/2`. Servers are
  normalized to `https://host[:port]` — the port is preserved, which an
  earlier draft of this dropped, silently sending anything on a custom
  port to 443.

### Fixed

Six of these come from a second quorum review, and three of them are the
*same defect surviving at a second call site* after the first was fixed —
which is now a standing note in `AGENTS.md`.

- **A control command is confirmed positively.** `Shelly.CloudV2` reported
  a rejected command as success: Shelly answers a refused switch with HTTP
  200 and `"isok": false`, and only the status code was checked. The first
  fix looked for an explicit `false`, which still accepted a proxy's HTML
  error page or an empty body as a switched relay; `"isok": true` is now
  required, matching `Account` and `CloudV1`.
- **A scalar `"device"` no longer kills the socket on the `Online` path.**
  `online_flag/1` carried the same unguarded `get_in/2` that
  `raw_device_id/1` was hardened against in 0.2.1, and it runs outside the
  handler's rescue — so one malformed event ended realtime for that
  account.
- **Alarm and presence deltas report unknown, not clear.** A `smoke:0`
  delta without its `alarm` key was reported as *not alarming*. This is
  the same unknown-vs-off fix 0.2.1 made for switches, on the classes
  where the wrong direction is a safety issue.
- **`http://` servers no longer become `https://host:80`.** `URI.parse/1`
  fills the port in from the source scheme, and the 0.3.0 port-preserving
  fix carried it onto the upgraded URL — every request then went to :80.
- **An empty string is no longer a credential.** `""` passed
  `is_binary/1`, so a token-less grant produced a client that reported
  itself authorized and 401'd forever.
- **A refresh answering 200 without a token** reports
  `:no_token_in_response` rather than `:refresh_unsupported`, which had
  been sending callers to re-authorize a grant the server never refused.
- Missing credentials return `{:error, :no_token}` / `{:error,
  :no_auth_key}` instead of raising from string concatenation, and
  malformed payloads (a list where a device map was promised, a v1
  response with no `device_status`, a `devices_status` that isn't a map)
  are errors rather than plausible-looking empty results.
- `Shelly.RateGate` rejects a zero or negative `:interval_ms` instead of
  silently disabling pacing, and an invalid global `:req_options` is
  logged rather than discarded.

### Fixed (second review round)

- **`Shelly.Status.parse/4` is total again.** It is spec'd to return a
  status for any input, and its own documented guard (`has_component?/2`)
  passed payloads through that then raised: a scalar where a nested map
  was expected — `"bat" => 87`, `"wifi" => 1`, `"aenergy" => 5` — reached
  `Access.get/3`. Every nested read now goes through total accessors, so
  a malformed payload reads as absent instead of crashing the caller.
  This affected `Account.parse_status/2` and both auth-key clients, where
  nothing rescued it.
- **Empty and whitespace-only credentials no longer reach the wire.** The
  predicates rejected them; all four transports and `Events.start_link/2`
  still guarded only `nil`, so `Authorization: "Bearer "` and `auth_key=`
  were being sent. The 0.3.0 entry below claiming this was fixed was
  therefore only half true — the predicates were, the transports weren't.
- **`OAuth.exchange_code/2` no longer raises on a non-object JWT payload.**
  `peek_jwt/1` returned any decoded JSON term, so a token whose payload
  was a string or a list crashed the grant instead of erroring.
- **An unnamed component reports `on: nil`, not `false`.** The
  unknown-vs-off principle now holds one level further out: a payload that
  names nothing for the channel — a battery-only delta, the commonest
  partial there is — no longer claims the device is off.
- **A Gen1 roller in an unrecognized state reports `nil`.** `"stop"`,
  `"stopped"` and `"calibrating"` were reported as closed, while Gen2
  covers report exactly those as open — the two generations contradicted
  each other on the same physical state.
- `Events.normalize_device_id/1` returns `nil` for a blank id rather than
  `""`, which was being delivered to handlers as a device.
- `CloudV2.get_statuses/2` drops elements with no usable id instead of
  collapsing them all under `""`, where every one but the last was lost.
- Per-call `:req_options` are validated and reported like the global ones,
  rather than being silently discarded.
- IPv6 server addresses survive normalization; `expires_at` accepts a
  float `exp` (legal JSON, and it made a token look non-expiring).

### Changed (second review round)

- `Shelly.OAuth.authorize_url/2` **raises** when `:state` is present but
  not a non-empty string. Omitting it is a documented choice; passing an
  unusable one silently produced a URL with no CSRF binding while the
  caller believed otherwise. The 0.2.x positional `client_id` form is
  removed — 0.3.0 breaks every other entry point, so a compatibility shim
  for one function was inconsistent.
- `Shelly.Events.start_link/2` accepts **`:known_ids`**, which resolves
  the ambiguous device ids `normalize_device_id/2` was added for. Without
  it that escape hatch wasn't reachable from the socket — the one place
  the ambiguity actually bites.
- `Shelly.Client.new/1` **raises** on a server with no host (`""`,
  `"wss://"`, `":::"`), where 0.2.x returned the string verbatim and
  failed later, somewhere less obvious.

### Changed

- **Component precedence is now explicit**: actuators, then meters, then
  sensors. The order was previously an accident of which entries fitted a
  lookup table. Concretely this **reclassifies 12 pairings**: a
  light-family component (`cct`/`rgb`/`rgbw`/`rgbcct`) on a channel now
  wins over `pm1`, `em1` and `em:0`, which aligns `parse/4` with what
  `component_of/2` already answered before 0.2.1 unified them. No known
  device emits these overlaps; all 12 are pinned in
  `test/shelly/agreement_test.exs`. A differential against the
  pre-refactor parser over 192 payload/channel combinations shows no
  other resolution changed.
- `Shelly.Client`'s expiry predicate is now **`token_expired?/1`**. The semantics
  are deliberate — a key-only client answers `true` and is nonetheless
  fully functional, which is what makes `if token_expired?, do: CloudV2,
  else: Account` correct — but the old name asserted something about the
  client that was only true of its token.
- `Shelly.OAuth.authorize_url/2` takes options and supports **`:state`**,
  the CSRF binding for the callback. The moduledoc previously claimed
  Shelly had no such parameter; it does, and this library was talking
  users out of the only protection the flow offers.
- `Shelly.Events.normalize_device_id/2` resolves the ambiguous ids that
  length alone cannot (~5% of Gen1 ids) against a set of ids you already
  know.

## v0.2.1 — tagged, never published

*(hex went from 0.2.0 straight to 0.3.0; this section is kept because
0.3.0's notes refer back to it.)*

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
  padding: `"000000b923fa"` vs `"b923fa"`) — **except** where a decimal
  rendering is itself exactly 6 or 12 digits, which no rule can settle;
  0.3.0 adds `normalize_device_id/2` for that case.

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
  the expensive direction. (Applied to switches, lights, covers and Gen1
  relays here; the alarm and presence classes were missed and are fixed
  in 0.3.0.)
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
  outside the handler's rescue, killing the socket process. (Fixed for
  `StatusOnChange` here; the same call in the `Online` path was missed and
  is fixed in 0.3.0.)
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

### Also in this release — quality sweep

Applied the workspace quality-sweep playbook (`~/Desktop/elixir/dev_docs/
quality_sweep.md`), whose central claim is that code review and tooling
catch different things. It held: dialyzer found three dead clauses six
models had read past, and the first HTTP-level test of `CloudV2` found
that a **rejected control command was reported as success** — Shelly
answers a refused switch with HTTP 200 and `"isok": false`, and only the
status code was being checked.

- `mix precommit` — format, unused deps, warnings-as-errors, tests with a
  90% coverage floor, `credo --strict`, dialyzer — all green.
- `@spec` on the public API, plus `Shelly.Status.t()` and
  `Shelly.OAuth.grant()` types. The status map stays a map by design
  (transports differ in what they can report); that contract is now
  stated rather than implied.
- The three dispatch tables in `Shelly.Status` collapsed into one
  (`component_tag/2`), so a new device class is added in one place and
  the drift that caused the Gen1 alarm mismatch can't recur.
- Coverage 72% → 92%, using only `mix test --cover` and Req's `:plug`
  option — no mocking dependencies.

### Tests

40 → 139. New: an agreement matrix asserting `parse/4`, `has_component?/2`
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
