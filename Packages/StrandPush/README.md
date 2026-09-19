# StrandPush

The iOS/macOS half of the self-hosted push export, for the three v1 **replace-window** streams
only: `dailyMetric`, `sleepSession`, `workout`. This is a deliberately narrow hand-port of
`android/app/src/main/java/com/noop/push/` — see `docs/CROSS_PLATFORM.md` and
`docs/PUSH_PROTOCOL.md` for the protocol this package speaks. The eight append streams
(`hrSample`, `rrInterval`, `event`, `battery`, `spo2Sample`, `skinTempSample`, `respSample`,
`gravitySample`) and the `journal` mutable stream are **out of scope**; see `WIRING.md`.

## One data shape

Everything — encoding, validation, and window assembly — reads one static table,
`PushRegistry.streams`. Each `PushStreamSpec` names: the wire stream name, the natural-key
columns, the window selector (`day` or `startTs`), and the required/nullable data columns. There
is no per-stream branch anywhere else in the package; adding a fourth mutable stream later is one
more entry in that table plus one query in `PushSnapshotSource`, not a new code path.

```
PushRegistry.streams[.dailyMetric] = PushStreamSpec(
    stream: .dailyMetric,
    keyColumns: ["day"],
    windowSelector: .day,
    requiredDataColumns: [],
    nullableDataColumns: [18 nullable metric columns...]
)
```

## Files

- `PushRegistry.swift` — the registry table + the full v1 wire vocabulary (for "unknown stream"
  detection in capability documents).
- `PushJSON.swift` — `JSONValue` tree + the canonical (sorted-key) JSON encoder.
- `PushWindow.swift` — the half-open `[startInclusive, endExclusive)` window and its two
  factories (`ending(today:)`, `days(from:to:)`).
- `PushEndpointPolicy.swift` — endpoint validation: scheme, user-info/fragment rejection, the
  local-address allow list, plain-HTTP-must-be-local enforcement.
- `PushProtocol.swift` — NDJSON record/header encoding, deterministic batch IDs
  (`stableUuid`), part splitting under the 5,000-record / 4 MiB decoded bounds, the
  content-addressed snapshot hash.
- `PushCapabilities.swift` — fail-closed capability-document parsing.
- `PushAck.swift` — ack parsing + the exact-match check a replace-window batch needs to count as
  delivered.
- `PushFailure.swift` — the retryable-failure taxonomy and receiver error-body parsing.
- `PushHTTPClient.swift` — the `PushHTTPClient` protocol and its `URLSession` implementation
  (redirects never followed).
- `PushTransport.swift` — the two HTTP calls (`GET` capabilities, `POST` one batch).
- `PushSnapshotSource.swift` — the three GRDB queries against WhoopStore's tables.
- `PushCoordinator.swift` — `PushCoordinator.push(...)`, the one async entry point.

## Deliberate simplifications versus the Kotlin twin

- **Identity encoding only.** This package always sends the decoded NDJSON body directly; it
  never gzips. The protocol allows this (the 4 MiB bound is on the *decoded* body either way), so
  there is no wire/decoded distinction, no `Content-Encoding` header, and no 415-retry-without-gzip
  fallback to port from `PushHttpTransport.kt`.
- **No IDNA/punycode conversion.** A non-ASCII hostname is rejected (`Problem.invalidHost`)
  rather than converted, unlike the Kotlin twin's `IDN.toASCII`. No test in either twin's suite
  exercises a real Unicode hostname; if one is ever needed, add a punycode encoder rather than
  reaching for a private Foundation API.
- **`Double` formatting is Swift's, not Java's.** Both languages use a shortest-round-trip
  decimal algorithm and agree on ordinary health-metric magnitudes (e.g. `61.5`, `60.0`), but they
  are different implementations and are not proven byte-identical for every double. This has not
  been cross-checked against a JVM (this repository has no JVM in its Swift CI path); if a receiver
  ever byte-compares NDJSON across platforms, re-verify this.
- **No `PushTable` protocol.** The Kotlin twin has one interface implemented by both an append
  enum and a mutable enum. This package implements only the mutable half, so there is nothing to
  abstract over yet; introduce a shared protocol only when an append stream is actually added.

## Known cross-platform data gap

The macOS/iOS `workout` cache (`WhoopStore`'s `workout` table) has no GPS-route column. The
Android `Workout` Room entity has `routePolyline`. This package always sends
`"routePolyline": null` for that reason — not a bug, a real capability gap between the two
clients' local caches. See `WIRING.md`.
