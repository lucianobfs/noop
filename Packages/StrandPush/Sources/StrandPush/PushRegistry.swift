/// The v1 replace-window streams this package implements. Append streams (`hrSample`,
/// `rrInterval`, `event`, `battery`, `spo2Sample`, `skinTempSample`, `respSample`,
/// `gravitySample`) are out of scope on purpose — see the package README.
public enum PushMutableStream: String, CaseIterable, Sendable {
    case dailyMetric
    case sleepSession
    case workout

    public var wireName: String { rawValue }
}

/// A replace-window part's window is keyed either by a `day` text column or a `startTs`
/// unix-seconds column. See `docs/PUSH_PROTOCOL.md` "Authoritative rolling-window delivery".
public enum PushWindowSelector: Sendable {
    case day
    case startTs
}

/// One row of the v1 registry table: everything encoding, validation, and window assembly need
/// to know about a stream. This is the "one value, not branches" shape the task calls for —
/// adding a stream later is one more entry here, not a new code path.
public struct PushStreamSpec: Sendable {
    public let stream: PushMutableStream
    public let keyColumns: [String]
    public let windowSelector: PushWindowSelector
    public let requiredDataColumns: [String]
    public let nullableDataColumns: [String]

    public var dataColumns: [String] { requiredDataColumns + nullableDataColumns }
}

/// The single source of truth for the registry. Port of the three mutable rows of the Kotlin
/// `PushProtocol.REGISTRY` (`android/app/src/main/java/com/noop/push/PushProtocol.kt`) plus the
/// column list from `PushDao.kt`'s `TableSpec` table, restricted to the in-scope streams.
public enum PushRegistry {
    public static let streams: [PushMutableStream: PushStreamSpec] = [
        .dailyMetric: PushStreamSpec(
            stream: .dailyMetric,
            keyColumns: ["day"],
            windowSelector: .day,
            requiredDataColumns: [],
            nullableDataColumns: [
                "totalSleepMin", "efficiency", "deepMin", "remMin", "lightMin", "disturbances",
                "restingHr", "avgHrv", "recovery", "strain", "exerciseCount", "spo2Pct",
                "skinTempDevC", "respRateBpm", "steps", "activeKcalEst", "spo2Red", "spo2Ir",
            ]
        ),
        .sleepSession: PushStreamSpec(
            stream: .sleepSession,
            keyColumns: ["startTs"],
            windowSelector: .startTs,
            requiredDataColumns: ["endTs", "userEdited"],
            nullableDataColumns: [
                "efficiency", "restingHr", "avgHrv", "stagesJSON", "startTsAdjusted",
                "motionJSON", "sleepStateJSON", "stagingSparse",
            ]
        ),
        .workout: PushStreamSpec(
            stream: .workout,
            keyColumns: ["startTs", "sport"],
            windowSelector: .startTs,
            requiredDataColumns: ["endTs", "source"],
            nullableDataColumns: [
                "durationS", "energyKcal", "avgHr", "maxHr", "strain", "distanceM",
                "zonesJSON", "notes", "routePolyline", "steps",
            ]
        ),
    ]

    public static func spec(for stream: PushMutableStream) -> PushStreamSpec {
        // Every case of the (exhaustive, CaseIterable) enum has an entry above; a missing one is a
        // programmer error worth crashing on rather than silently sending a truncated registry.
        guard let spec = streams[stream] else {
            preconditionFailure("no registry entry for \(stream.wireName)")
        }
        return spec
    }
}

/// The complete v1 wire vocabulary (append + mutable), used ONLY to tell "unknown stream name"
/// (a receiver bug or typo) apart from "a real v1 stream this narrow client doesn't implement"
/// (`hrSample` et al. — never an error; the intersection with our compiled registry is empty).
enum PushWireVocabulary {
    static let allStreamNames: Set<String> = [
        "hrSample", "rrInterval", "event", "battery", "spo2Sample", "skinTempSample",
        "respSample", "gravitySample", "dailyMetric", "sleepSession", "workout", "journal",
    ]
}
