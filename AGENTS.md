# shelly — agent notes

Framework-agnostic Shelly smart-device client: cloud APIs, real-time
websocket events, component-aware status parsing. Extracted from
NordSwitch (nordswitch.eu), which is still the reference consumer and the
live fleet these paths are proven against.

## Common commands

| Task | Command |
|------|---------|
| Setup | `mix deps.get` |
| Tests | `mix test` |
| Coverage | `mix test --cover` (floor: 90%, no external mocking deps) |
| One gate | `mix precommit` — format, unused deps, warnings-as-errors, tests+coverage, credo --strict, dialyzer |
| Docs | `mix docs` (must be warning-free; ExDoc autolinks `Module.Name` in backticks, so don't reference hidden modules that way) |

`mix precommit` must be green before publishing. Code review and tooling
catch different things — the dead-clause findings in 0.2.1 came from
dialyzer, not from six models reading the source.

## Testing without external deps

No Mox, no bypass. HTTP is stubbed through Req's `:plug` option, carried
on the client:

```elixir
client =
  Shelly.Client.new(
    server: "https://x.shelly.cloud",
    token: "tok",
    req_options: [plug: fn conn -> Plug.Conn.send_resp(conn, 200, body) end]
  )
```

`config :shelly, :req_options` is the global fallback (use `async: false`
when you set it).

## Field notes that shaped this library

Each of these cost a live incident. Don't undo them without evidence.

- **Device ids arrive three ways** — hex, integer, and *decimal string* on
  the websocket. Hex ids are 6 (Gen1) or 12 characters, which is what
  distinguishes a decimal rendering from a hex id. Getting this wrong
  silently drops every event and degrades realtime to polling.
- **A component without its state key is unknown, not off.** Partial
  deltas are real; `:on` is `nil` in that case. Synthesizing `false` told
  a boiler controller its relay was off while it was drawing 15 W.
- **`parse/4`, `has_component?/2` and `component_of/2` all derive from
  `component_tag/2`.** They used to enumerate device classes separately
  and drifted. `test/shelly/agreement_test.exs` pins them together — add
  a row there for every new device class.
- **Shelly answers rejected commands with HTTP 200 and `"isok": false`.**
  Check the body, not just the status.
- **OAuth access tokens last 12 hours** (`exp - iat = 43200`, measured)
  and there is no documented refresh grant. Auth keys don't expire.
- **Gen1 relay energy counters are Watt-minutes**; Gen1 emeters are Wh.
- **The rate limit is per account** (~1 req/s), shared by every transport.
  Pass `:rate_key` so one account is one budget.
- **The access token rides the websocket URL**, so nothing may log a raw
  URL or an unsanitized WebSockex error.
- **Confirm success positively.** Shelly returns HTTP 200 for refused
  commands; require `"isok" => true` rather than treating "not an
  explicit no" as yes.
- **Guard both call sites.** Three of the defects found in review were
  the *same* bug surviving at a second call site after the first was
  fixed. When you fix a shape assumption, grep for its siblings.

## Releasing

Max publishes (`mix hex.publish`). Before that: `mix precommit`, CHANGELOG
entry, version bump in `mix.exs`, and a `v<version>` git tag — `docs`
uses `source_ref: "v#{@version}"`, so an untagged release 404s every
source link on HexDocs.

Commits in this workspace carry no AI attribution.
