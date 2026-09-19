import Foundation
import WhoopStore

/// What happened to one stream during a `PushCoordinator.push` call.
public struct PushStreamOutcome: Equatable, Sendable {
    public let stream: PushMutableStream
    public let sent: Int
    public let accepted: Int
    public let failure: PushFailure?

    public init(stream: PushMutableStream, sent: Int, accepted: Int, failure: PushFailure?) {
        self.stream = stream
        self.sent = sent
        self.accepted = accepted
        self.failure = failure
    }
}

public struct PushRunResult: Equatable, Sendable {
    public let outcomes: [PushStreamOutcome]

    public init(outcomes: [PushStreamOutcome]) {
        self.outcomes = outcomes
    }
}

/// The one entry point this package exposes: negotiate capabilities, then replace-window push
/// each stream the receiver both declared and this package implements. No progress store and no
/// cursor table — every call re-sends the full current window; the receiver's `replace_window`
/// semantics make that safe and idempotent.
public enum PushCoordinator {
    public static func push(
        endpoint: PushEndpointPolicy.ValidEndpoint,
        token: String,
        deviceId: String,
        sourceId: String,
        windowDays: Int = 14,
        store: WhoopStore,
        httpClient: any PushHTTPClient,
        today: Date = Date(),
        timeZone: TimeZone = .current
    ) async -> PushRunResult {
        let source = PushSnapshotSource(reader: store.registryWriter)
        let transport = PushTransport(endpoint: endpoint, token: token, client: httpClient)

        let capabilitiesResult = await transport.capabilities()
        guard case .available(let capabilities) = capabilitiesResult else {
            let failure: PushFailure
            if case .rejected(let rejected) = capabilitiesResult {
                failure = rejected
            } else {
                failure = PushFailure(code: .capabilitiesInvalid)
            }
            return PushRunResult(outcomes: PushMutableStream.allCases.map {
                PushStreamOutcome(stream: $0, sent: 0, accepted: 0, failure: failure)
            })
        }

        var outcomes: [PushStreamOutcome] = []
        for stream in PushMutableStream.allCases where capabilities.mutableStreams.contains(stream) {
            outcomes.append(await pushOne(
                stream: stream, deviceId: deviceId, sourceId: sourceId, windowDays: windowDays,
                today: today, timeZone: timeZone, source: source, transport: transport
            ))
        }
        return PushRunResult(outcomes: outcomes)
    }

    private static func pushOne(
        stream: PushMutableStream, deviceId: String, sourceId: String, windowDays: Int,
        today: Date, timeZone: TimeZone, source: PushSnapshotSource, transport: PushTransport
    ) async -> PushStreamOutcome {
        let window = PushWindow.ending(today: today, timeZone: timeZone, windowDays: windowDays)
        let records: [PushMutableRecord]
        let batches: [PushBatch]
        do {
            records = try source.mutableRows(stream: stream, deviceId: deviceId, window: window)
            batches = try PushProtocol.mutableBatches(
                stream: stream, sourceId: sourceId, deviceId: deviceId, window: window, records: records
            )
        } catch {
            return PushStreamOutcome(stream: stream, sent: 0, accepted: 0, failure: PushFailure(code: .localData))
        }

        var accepted = 0
        for batch in batches {
            let response: PushHTTPResponse
            do {
                response = try await transport.post(batch)
            } catch let transportError as PushTransportError {
                return PushStreamOutcome(stream: stream, sent: records.count, accepted: accepted, failure: transportError.failure)
            } catch {
                return PushStreamOutcome(stream: stream, sent: records.count, accepted: accepted, failure: PushFailure(code: .networkIO))
            }
            guard (200...299).contains(response.statusCode) else {
                let failure = PushFailure.http(status: response.statusCode, receiverCode: PushError.parseCode(response.body))
                return PushStreamOutcome(stream: stream, sent: records.count, accepted: accepted, failure: failure)
            }
            guard let ack = try? PushAck.parse(response.body), ack.exactlyMatches(batch) else {
                return PushStreamOutcome(stream: stream, sent: records.count, accepted: accepted, failure: PushFailure(code: .ackInvalid))
            }
            accepted += batch.recordCount
        }
        return PushStreamOutcome(stream: stream, sent: records.count, accepted: accepted, failure: nil)
    }
}
