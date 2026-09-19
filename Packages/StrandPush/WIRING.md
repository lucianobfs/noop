# StrandPush — wiring follow-up

This package is a standalone library. It is not yet called from any app target. This is the
plan for the follow-up work to actually wire it in.

## 1. Settings surface

Add a "Self-hosted push" section to the macOS/iOS settings screen (wherever the existing
Whoop/Oura account settings live): endpoint URL field, bearer token field (stored in Keychain, not
`UserDefaults`), a device identifier (reuse the existing per-install device id, if one exists, or
generate and persist a UUID), and a source identifier (one persisted UUID per install, generated
once).

## 2. Trigger

Match the Android app's cadence: a periodic background task (macOS: a launch agent / scheduled
`BGAppRefreshTask`-equivalent won't exist on macOS — use a repeating `Timer` or a scheduled job
via `NSBackgroundActivityScheduler`; iOS: `BGAppRefreshTask`) that calls
`PushCoordinator.push(...)` with the persisted settings. On failure, back off per
`PushFailure.retryable`; do not retry a non-retryable failure without a settings change.

## 3. Endpoint validation at the settings boundary

Call `PushEndpointPolicy.validate(_:)` when the user edits the endpoint field and reject the save
if invalid, surfacing `Problem` as a user-facing message, before ever persisting it. Do not
re-validate at push time only — a URL that was valid when entered and became invalid (e.g. DNS
change) is a push-time failure, not a settings error, and should NOT block the settings screen
retroactively.

## 4. Add the append streams

The eight append streams (`hrSample`, `rrInterval`, `event`, `battery`, `spo2Sample`,
`skinTempSample`, `respSample`, `gravitySample`) are not implemented. They need:

- A `PushAppendStream` registry entry (cursor column, not a window selector).
- A cursor/progress store (this package has none — mutable streams never need one). Model it on
  `PushDao.kt`'s progress table, NOT on `PushCoordinator.kt`'s in-memory Kotlin structures, since
  those close over Room-specific types.
- A `PushTable` protocol uniting the append and mutable stream enums IF and only if real code ends
  up needing to iterate over both together; do not add this abstraction speculatively (see the
  README's "no `PushTable` protocol" note).

## 5. Add the `journal` mutable stream

`journal`'s natural key is `(day, question)`, not `(day)` alone — see
`android/app/src/main/java/com/noop/push/PushDao.kt`'s `TableSpec` for `MUTABLE_JOURNAL`. It needs
its own `PushRegistry` entry and its own `PushSnapshotSource` query against WhoopStore's `journal`
table.

## 6. Cross-platform data gap: `workout.routePolyline`

The Android `Workout` Room entity has a `routePolyline` column; the macOS/iOS `WhoopStore.workout`
table does not. Until WhoopStore adds that column (and something populates it from
HealthKit/whatever GPS source is available), this package will keep sending `"routePolyline":
null` for every workout record. Decide whether that gap is acceptable indefinitely or whether
WhoopStore needs a migration — that decision belongs to whoever owns WhoopStore's schema, not to
this package.

## 7. Progress / dedup optimization (not required for correctness)

The Kotlin twin uses `PushProtocol.mutableSnapshotHash` (ported here, unused by the coordinator)
to skip re-sending a window whose content hasn't changed since the last successful push. This
package computes every window's batches on every call. Wiring in the skip-if-unchanged
optimization needs a small persisted "last successful hash per stream" store; add it only once
push frequency becomes a measured problem.
