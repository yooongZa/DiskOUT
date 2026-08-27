import Foundation
import Darwin

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

private enum MemoryStoreError: Error {
    case requestedFailure
}

private final class MemoryLifecycleStore: AppLifecycleTelemetryStateStore {
    private let lock = NSLock()
    private var storedState: AppLifecycleTelemetryState?
    private var saveCallCount = 0
    private var failedSaveCalls: Set<Int>

    init(
        state: AppLifecycleTelemetryState? = nil,
        failedSaveCalls: Set<Int> = []
    ) {
        storedState = state
        self.failedSaveCalls = failedSaveCalls
    }

    var exists: Bool {
        lock.lock()
        defer { lock.unlock() }
        return storedState != nil
    }

    func load() throws -> AppLifecycleTelemetryState? {
        lock.lock()
        defer { lock.unlock() }
        return storedState
    }

    func save(_ state: AppLifecycleTelemetryState) throws {
        lock.lock()
        defer { lock.unlock() }
        saveCallCount += 1
        if failedSaveCalls.contains(saveCallCount) {
            throw MemoryStoreError.requestedFailure
        }
        storedState = state
    }

    func allowAllSaves() {
        lock.lock()
        failedSaveCalls = []
        lock.unlock()
    }
}

private final class LifecycleURLProtocol: URLProtocol {
    struct Plan {
        let status: Int
        let body: Data
        let deliveryGate: DispatchSemaphore?
        let redirectURL: URL?
        let error: Error?

        init(
            status: Int,
            body: Data = Data("{}".utf8),
            deliveryGate: DispatchSemaphore? = nil,
            redirectURL: URL? = nil,
            error: Error? = nil
        ) {
            self.status = status
            self.body = body
            self.deliveryGate = deliveryGate
            self.redirectURL = redirectURL
            self.error = error
        }
    }

    private static let lock = NSLock()
    private static var responder: ((Int, URLRequest) -> Plan)?
    private static var capturedRequests: [URLRequest] = []
    private let instanceLock = NSLock()
    private var stopped = false

    static var requests: [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return capturedRequests
    }

    static func reset(responder: @escaping (Int, URLRequest) -> Plan) {
        lock.lock()
        self.responder = responder
        capturedRequests = []
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var capturedRequest = request
        if capturedRequest.httpBody == nil, let stream = capturedRequest.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var body = Data()
            var buffer = [UInt8](repeating: 0, count: 1_024)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                body.append(buffer, count: count)
            }
            capturedRequest.httpBody = body
            capturedRequest.httpBodyStream = nil
        }
        let plan: Plan
        Self.lock.lock()
        Self.capturedRequests.append(capturedRequest)
        let index = Self.capturedRequests.count
        plan = Self.responder?(index, capturedRequest) ?? Plan(status: 503)
        Self.lock.unlock()

        DispatchQueue.global(qos: .utility).async { [weak self] in
            plan.deliveryGate?.wait()
            guard let self, !self.isStopped else { return }
            if let error = plan.error {
                self.client?.urlProtocol(self, didFailWithError: error)
                return
            }
            let response = HTTPURLResponse(
                url: self.request.url!,
                statusCode: plan.status,
                httpVersion: "HTTP/1.1",
                headerFields: plan.redirectURL.map {
                    ["Location": $0.absoluteString]
                } ?? ["Content-Type": "application/json"]
            )!
            if let redirectURL = plan.redirectURL {
                var redirectedRequest = capturedRequest
                redirectedRequest.url = redirectURL
                self.client?.urlProtocol(
                    self,
                    wasRedirectedTo: redirectedRequest,
                    redirectResponse: response
                )
                self.client?.urlProtocolDidFinishLoading(self)
                return
            }
            self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            self.client?.urlProtocol(self, didLoad: plan.body)
            self.client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {
        instanceLock.lock()
        stopped = true
        instanceLock.unlock()
    }

    private var isStopped: Bool {
        instanceLock.lock()
        defer { instanceLock.unlock() }
        return stopped
    }
}

private func testSession(onRedirectRejected: (() -> Void)? = nil) -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [LifecycleURLProtocol.self]
    configuration.timeoutIntervalForRequest = 1
    configuration.timeoutIntervalForResource = 2
    return URLSession(
        configuration: configuration,
        delegate: AppLifecycleTelemetrySessionDelegate(
            onRedirectRejected: onRedirectRejected
        ),
        delegateQueue: nil
    )
}

private let endpoint = URL(string: "https://telemetry.example/v1/app-events")!
private let build20 = AppLifecycleBuild(version: "0.5.6", build: "20")
private let build21 = AppLifecycleBuild(version: "0.5.7", build: "21")
private let build22 = AppLifecycleBuild(version: "0.5.8", build: "22")
private let fixedDate = Date(timeIntervalSince1970: 1_787_776_523.123)

private func state(
    lastSeen: AppLifecycleBuild?,
    pending: AppLifecyclePendingUpdate? = nil,
    events: [AppLifecycleEvent] = [],
    deadLetters: [AppLifecycleDeadLetter] = []
) -> AppLifecycleTelemetryState {
    var value = AppLifecycleTelemetryState(
        installationID: "11111111-1111-4111-8111-111111111111"
    )
    value.lastSeen = lastSeen
    value.pendingUpdate = pending
    value.events = events
    value.deadLetters = deadLetters
    return value
}

private func queuedVersionEvent(
    eventID: String = "22222222-2222-4222-8222-222222222222"
) -> AppLifecycleEvent {
    AppLifecycleEvent(
        eventID: eventID,
        type: .versionSeen,
        occurredAt: AppLifecycleLaunchPlanner.timestamp(fixedDate),
        app: build21,
        previous: build20,
        target: nil
    )
}

private func eventID(in request: URLRequest) -> String? {
    if let value = request.value(forHTTPHeaderField: "Idempotency-Key") { return value }
    guard let body = request.httpBody,
          let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
        return nil
    }
    return object["event_id"] as? String
}

private func acknowledgementBody(
    eventID: String,
    duplicate: Bool = false
) -> Data {
    try! JSONSerialization.data(withJSONObject: [
        "ok": true,
        "duplicate": duplicate,
        "event_id": eventID,
    ])
}

@main
private enum AppLifecycleTelemetryTests {
    static func main() throws {
        if CommandLine.arguments.count == 3,
           CommandLine.arguments[1] == "--hold-lifecycle-lock" {
            let stateURL = URL(fileURLWithPath: CommandLine.arguments[2])
            guard let store = AtomicAppLifecycleTelemetryStateStore.exclusive(fileURL: stateURL) else {
                Darwin.exit(2)
            }
            FileHandle.standardOutput.write(Data("LOCKED\n".utf8))
            withExtendedLifetime(store) {
                Thread.sleep(forTimeInterval: 30)
            }
            return
        }

        testFreshAndExistingBootstrap()
        testUpdateCompletionAndRollback()
        testPendingUpdatePersistenceAndCancellation()
        try testAtomicStore()
        try testCrossProcessLock()
        testOfflineRetry()
        testRetryableStatusesRemainQueued()
        testTransientFailureSurvivesRestart()
        testSameBuildLaunchFlushesPersistedQueue()
        testLostAckPersistenceRetriesSameEvent()
        testApplicationLevelAcknowledgements()
        testInvalidAcknowledgementsSurviveRestart()
        testPermanentFailureQuarantinesAndAdvances()
        testQuarantinePersistenceFailureRetriesSameEvent()
        testRedirectsAreRejected()
        testConcurrentFlushIsSingleFlight()
        testEndpointValidation()
        print("AppLifecycleTelemetryTests: PASS")
    }

    private static func testFreshAndExistingBootstrap() {
        let fresh = AppLifecycleLaunchPlanner.applyingSuccessfulLaunch(
            to: nil,
            current: build21,
            priorAppStateExists: false,
            now: fixedDate,
            makeUUID: UUIDSequence([
                "11111111-1111-4111-8111-111111111111",
                "22222222-2222-4222-8222-222222222222",
                "33333333-3333-4333-8333-333333333333",
            ]).next
        )!
        expect(fresh.events.map(\.type) == [.firstLaunch, .versionSeen],
               "a genuinely fresh successful launch records install and version once")
        expect(fresh.lastSeen == build21, "fresh launch records the current build")

        let existing = AppLifecycleLaunchPlanner.applyingSuccessfulLaunch(
            to: nil,
            current: build21,
            priorAppStateExists: true,
            now: fixedDate,
            makeUUID: UUIDSequence([
                "44444444-4444-4444-8444-444444444444",
                "55555555-5555-4555-8555-555555555555",
            ]).next
        )!
        expect(existing.events.map(\.type) == [.versionSeen],
               "telemetry rollout on an existing install does not fabricate first_launch")

        let sameBuild = AppLifecycleLaunchPlanner.applyingSuccessfulLaunch(
            to: existing,
            current: build21,
            priorAppStateExists: true,
            now: fixedDate.addingTimeInterval(60)
        )!
        expect(sameBuild.events == existing.events,
               "relaunching the same build does not duplicate version_seen")
    }

    private static func testUpdateCompletionAndRollback() {
        let pending = AppLifecyclePendingUpdate(
            source: build21,
            target: build22,
            markedAt: AppLifecycleLaunchPlanner.timestamp(fixedDate)
        )
        let updated = AppLifecycleLaunchPlanner.applyingSuccessfulLaunch(
            to: state(lastSeen: build21, pending: pending),
            current: build22,
            priorAppStateExists: true,
            now: fixedDate.addingTimeInterval(30),
            makeUUID: UUIDSequence([
                "66666666-6666-4666-8666-666666666666",
                "77777777-7777-4777-8777-777777777777",
            ]).next
        )!
        expect(updated.events.map(\.type) == [.versionSeen, .updateCompleted],
               "a matching next-launch target records one completed update")
        expect(updated.pendingUpdate == nil, "successful update consumes its marker")

        let rolledBack = AppLifecycleLaunchPlanner.applyingSuccessfulLaunch(
            to: state(lastSeen: build21, pending: pending),
            current: build20,
            priorAppStateExists: true,
            now: fixedDate.addingTimeInterval(60),
            makeUUID: UUIDSequence([
                "88888888-8888-4888-8888-888888888888",
            ]).next
        )!
        expect(rolledBack.events.map(\.type) == [.versionSeen],
               "a rollback is a version transition but never a completed update")
        expect(rolledBack.pendingUpdate == nil, "mismatched marker is consumed as unproven")

        let sameBuildDifferentVersion = AppLifecycleLaunchPlanner.applyingSuccessfulLaunch(
            to: state(lastSeen: build21, pending: pending),
            current: AppLifecycleBuild(version: "0.5.9", build: "22"),
            priorAppStateExists: true,
            now: fixedDate.addingTimeInterval(75),
            makeUUID: UUIDSequence([
                "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
            ]).next
        )!
        expect(sameBuildDifferentVersion.events.map(\.type) == [.versionSeen],
               "same build with a different version cannot prove the pending update completed")
        expect(sameBuildDifferentVersion.pendingUpdate == nil,
               "same-build different-version manual install consumes the unproven marker")

        let canceled = AppLifecycleLaunchPlanner.applyingSuccessfulLaunch(
            to: state(lastSeen: build21),
            current: build22,
            priorAppStateExists: true,
            now: fixedDate.addingTimeInterval(90),
            makeUUID: UUIDSequence([
                "99999999-9999-4999-8999-999999999999",
            ]).next
        )!
        expect(canceled.events.map(\.type) == [.versionSeen],
               "a canceled or failed install without a marker cannot record completion")
    }

    private static func testPendingUpdatePersistenceAndCancellation() {
        let store = MemoryLifecycleStore(state: state(lastSeen: build21))
        let controller = AppLifecycleTelemetryController(
            endpoint: nil,
            stateStore: store,
            session: testSession()
        )
        controller.markPendingUpdate(source: build21, target: build22, now: fixedDate)
        expect(controller.stateSnapshotForTesting()?.pendingUpdate?.target == build22,
               "will-install persists the exact target build marker")
        controller.clearPendingUpdate()
        expect(controller.stateSnapshotForTesting()?.pendingUpdate == nil,
               "cancel or install failure durably clears the pending update marker")
        controller.stop()
    }

    private static func testAtomicStore() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("diskout-lifecycle-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AtomicAppLifecycleTelemetryStateStore(
            fileURL: directory.appendingPathComponent("state.json")
        )
        let quarantinedEvent = queuedVersionEvent(
            eventID: "33333333-3333-4333-8333-333333333333"
        )
        let expected = state(
            lastSeen: build21,
            events: [queuedVersionEvent()],
            deadLetters: [AppLifecycleDeadLetter(
                event: quarantinedEvent,
                reason: .permanentHTTPResponse,
                httpStatus: 400,
                quarantinedAt: AppLifecycleLaunchPlanner.timestamp(fixedDate)
            )]
        )
        try store.save(expected)
        let loaded = try store.load()
        expect(loaded == expected,
               "atomic store round-trips the active queue and durable quarantine")
        let attributes = try FileManager.default.attributesOfItem(atPath: store.fileURL.path)
        expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600,
               "telemetry state is readable only by the current user")

        var legacyObject = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(state(lastSeen: build21, events: [queuedVersionEvent()]))
        ) as! [String: Any]
        legacyObject.removeValue(forKey: "dead_letters")
        try JSONSerialization.data(withJSONObject: legacyObject)
            .write(to: store.fileURL, options: [.atomic])
        let legacyState = try store.load()
        expect(legacyState?.deadLetters.isEmpty == true,
               "pre-quarantine schema-version-1 state loads with an empty dead-letter queue")
    }

    private static func testCrossProcessLock() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("diskout-lifecycle-lock-test-\(UUID().uuidString)",
                                    isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let stateURL = directory.appendingPathComponent("state.json")
        let child = Process()
        child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        child.arguments = ["--hold-lifecycle-lock", stateURL.path]
        let output = Pipe()
        child.standardOutput = output
        child.standardError = Pipe()
        defer {
            if child.isRunning {
                child.terminate()
                child.waitUntilExit()
            }
        }
        try child.run()
        let ready = output.fileHandleForReading.availableData
        expect(String(data: ready, encoding: .utf8) == "LOCKED\n",
               "child process acquires the telemetry lifetime lock")

        let competing = AtomicAppLifecycleTelemetryStateStore.exclusive(fileURL: stateURL)
        expect(competing == nil,
               "a second process fails closed instead of racing a lifecycle state write")

        child.terminate()
        child.waitUntilExit()
        let recovered = AtomicAppLifecycleTelemetryStateStore.exclusive(fileURL: stateURL)
        expect(recovered != nil,
               "the advisory lock is recoverable after the owning process exits")
        withExtendedLifetime(recovered) {}
    }

    private static func testOfflineRetry() {
        let firstAttempt = DispatchSemaphore(value: 0)
        LifecycleURLProtocol.reset { _, _ in .init(status: 503) }
        let store = MemoryLifecycleStore()
        let controller = AppLifecycleTelemetryController(
            endpoint: endpoint,
            stateStore: store,
            session: testSession(),
            onAttemptFinished: { _ in firstAttempt.signal() }
        )
        controller.recordSuccessfulLaunch(
            current: build21,
            priorAppStateExists: true,
            now: fixedDate
        )
        expect(firstAttempt.wait(timeout: .now() + 3) == .success,
               "offline attempt must finish without blocking the app")
        expect(controller.stateSnapshotForTesting()?.events.count == 1,
               "non-2xx keeps the event queued")

        let retryAttempt = DispatchSemaphore(value: 0)
        var retryObserved = false
        LifecycleURLProtocol.reset { _, request in
            retryObserved = true
            retryAttempt.signal()
            return .init(
                status: 200,
                body: acknowledgementBody(eventID: eventID(in: request)!)
            )
        }
        controller.flush()
        expect(retryAttempt.wait(timeout: .now() + 3) == .success,
               "manual retry reaches the endpoint")
        for _ in 0..<100 where controller.stateSnapshotForTesting()?.events.isEmpty != true {
            Thread.sleep(forTimeInterval: 0.01)
        }
        expect(retryObserved && controller.stateSnapshotForTesting()?.events.isEmpty == true,
               "2xx ACK removes the persisted event")
        controller.stop()
    }

    private static func testRetryableStatusesRemainQueued() {
        for status in [408, 425, 429, 500, 503] {
            let attemptFinished = DispatchSemaphore(value: 0)
            LifecycleURLProtocol.reset { _, _ in .init(status: status) }
            let controller = AppLifecycleTelemetryController(
                endpoint: endpoint,
                stateStore: MemoryLifecycleStore(
                    state: state(lastSeen: build21, events: [queuedVersionEvent()])
                ),
                session: testSession(),
                onAttemptFinished: { _ in attemptFinished.signal() }
            )
            controller.flush()
            expect(attemptFinished.wait(timeout: .now() + 3) == .success,
                   "retryable HTTP \(status) returns control")
            let snapshot = controller.stateSnapshotForTesting()
            expect(snapshot?.events.count == 1 && snapshot?.deadLetters.isEmpty == true,
                   "retryable HTTP \(status) retains the active event for a later attempt")
            controller.stop()
        }
    }

    private static func testTransientFailureSurvivesRestart() {
        let store = MemoryLifecycleStore(
            state: state(lastSeen: build21, events: [queuedVersionEvent()])
        )
        let firstAttempt = DispatchSemaphore(value: 0)
        LifecycleURLProtocol.reset { _, _ in
            .init(status: 503, error: URLError(.notConnectedToInternet))
        }
        let firstController = AppLifecycleTelemetryController(
            endpoint: endpoint,
            stateStore: store,
            session: testSession(),
            onAttemptFinished: { _ in firstAttempt.signal() }
        )
        firstController.flush()
        expect(firstAttempt.wait(timeout: .now() + 3) == .success,
               "transport failure returns control before restart")
        let firstID = LifecycleURLProtocol.requests.first.flatMap(eventID(in:))
        expect(firstController.stateSnapshotForTesting()?.events.count == 1,
               "transport failure remains durably active")
        firstController.stop()

        let secondAttempt = DispatchSemaphore(value: 0)
        LifecycleURLProtocol.reset { _, request in
            .init(
                status: 200,
                body: acknowledgementBody(eventID: eventID(in: request)!, duplicate: true)
            )
        }
        let restartedController = AppLifecycleTelemetryController(
            endpoint: endpoint,
            stateStore: store,
            session: testSession(),
            onAttemptFinished: { _ in secondAttempt.signal() }
        )
        restartedController.flush()
        expect(secondAttempt.wait(timeout: .now() + 3) == .success,
               "restart retries the persisted transport failure")
        expect(LifecycleURLProtocol.requests.first.flatMap(eventID(in:)) == firstID,
               "restart preserves the same event UUID")
        expect(restartedController.stateSnapshotForTesting()?.events.isEmpty == true,
               "matching ACK after restart durably drains the event")
        restartedController.stop()
    }

    private static func testSameBuildLaunchFlushesPersistedQueue() {
        let attemptFinished = DispatchSemaphore(value: 0)
        LifecycleURLProtocol.reset { _, request in
            .init(
                status: 200,
                body: acknowledgementBody(eventID: eventID(in: request)!)
            )
        }
        let controller = AppLifecycleTelemetryController(
            endpoint: endpoint,
            stateStore: MemoryLifecycleStore(
                state: state(lastSeen: build21, events: [queuedVersionEvent()])
            ),
            session: testSession(),
            onAttemptFinished: { _ in attemptFinished.signal() }
        )
        controller.recordSuccessfulLaunch(
            current: build21,
            priorAppStateExists: true,
            now: fixedDate
        )
        expect(attemptFinished.wait(timeout: .now() + 3) == .success,
               "a same-build relaunch retries a previously persisted event")
        expect(controller.stateSnapshotForTesting()?.events.isEmpty == true,
               "a matching ACK drains the persisted queue on relaunch")
        controller.stop()
    }

    private static func testLostAckPersistenceRetriesSameEvent() {
        let firstAttempt = DispatchSemaphore(value: 0)
        LifecycleURLProtocol.reset { _, request in
            .init(
                status: 200,
                body: acknowledgementBody(eventID: eventID(in: request)!)
            )
        }
        let store = MemoryLifecycleStore(failedSaveCalls: [2])
        let controller = AppLifecycleTelemetryController(
            endpoint: endpoint,
            stateStore: store,
            session: testSession(),
            onAttemptFinished: { _ in firstAttempt.signal() }
        )
        controller.recordSuccessfulLaunch(
            current: build21,
            priorAppStateExists: true,
            now: fixedDate
        )
        expect(firstAttempt.wait(timeout: .now() + 3) == .success,
               "ACK persistence failure returns control")
        let firstID = LifecycleURLProtocol.requests.first.flatMap(eventID(in:))
        expect(firstID != nil, "test transport captures the persisted event UUID")
        expect(controller.stateSnapshotForTesting()?.events.count == 1,
               "an ACK is not allowed to remove an event unless the new queue persists")

        store.allowAllSaves()
        let secondAttempt = DispatchSemaphore(value: 0)
        LifecycleURLProtocol.reset { _, request in
            secondAttempt.signal()
            return .init(
                status: 200,
                body: acknowledgementBody(eventID: eventID(in: request)!, duplicate: true)
            )
        }
        controller.flush()
        expect(secondAttempt.wait(timeout: .now() + 3) == .success,
               "lost local ACK state retries")
        let secondID = LifecycleURLProtocol.requests.first.flatMap(eventID(in:))
        expect(secondID == firstID, "retry preserves the same event UUID for server deduplication")
        for _ in 0..<100 where controller.stateSnapshotForTesting()?.events.isEmpty != true {
            Thread.sleep(forTimeInterval: 0.01)
        }
        expect(controller.stateSnapshotForTesting()?.events.isEmpty == true,
               "duplicate-safe retry eventually drains after a durable ACK removal")
        controller.stop()
    }

    private static func testApplicationLevelAcknowledgements() {
        let cases: [(name: String, body: (String) -> Data, acknowledged: Bool)] = [
            (
                "matching normal ACK",
                { acknowledgementBody(eventID: $0) },
                true
            ),
            (
                "matching duplicate ACK",
                { acknowledgementBody(eventID: $0, duplicate: true) },
                true
            ),
            (
                "mismatched event ID",
                { _ in acknowledgementBody(eventID: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa") },
                false
            ),
            (
                "broken JSON",
                { _ in Data("{".utf8) },
                false
            ),
        ]

        for testCase in cases {
            let attemptFinished = DispatchSemaphore(value: 0)
            LifecycleURLProtocol.reset { _, request in
                let identifier = eventID(in: request)!
                return .init(status: 200, body: testCase.body(identifier))
            }
            let controller = AppLifecycleTelemetryController(
                endpoint: endpoint,
                stateStore: MemoryLifecycleStore(
                    state: state(lastSeen: build21, events: [queuedVersionEvent()])
                ),
                session: testSession(),
                onAttemptFinished: { _ in attemptFinished.signal() }
            )
            controller.flush()
            expect(attemptFinished.wait(timeout: .now() + 3) == .success,
                   "\(testCase.name) returns control")
            let snapshot = controller.stateSnapshotForTesting()
            expect(snapshot?.events.isEmpty == testCase.acknowledged,
                   "\(testCase.name) has the expected active queue result")
            expect(snapshot?.deadLetters.isEmpty == true,
                   "\(testCase.name) never quarantines an uncertain 2xx response")
            controller.stop()
        }
    }

    private static func testInvalidAcknowledgementsSurviveRestart() {
        let invalidBodies: [(String, (String) -> Data)] = [
            (
                "mismatched event ID",
                { _ in acknowledgementBody(eventID: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa") }
            ),
            ("malformed JSON", { _ in Data("{".utf8) }),
        ]
        for (name, invalidBody) in invalidBodies {
            let store = MemoryLifecycleStore(
                state: state(lastSeen: build21, events: [queuedVersionEvent()])
            )
            let firstAttempt = DispatchSemaphore(value: 0)
            LifecycleURLProtocol.reset { _, request in
                .init(status: 200, body: invalidBody(eventID(in: request)!))
            }
            let firstController = AppLifecycleTelemetryController(
                endpoint: endpoint,
                stateStore: store,
                session: testSession(),
                onAttemptFinished: { _ in firstAttempt.signal() }
            )
            firstController.flush()
            expect(firstAttempt.wait(timeout: .now() + 3) == .success,
                   "\(name) returns control before restart")
            let firstID = LifecycleURLProtocol.requests.first.flatMap(eventID(in:))
            expect(firstController.stateSnapshotForTesting()?.events.count == 1,
                   "\(name) keeps the uncertain event active")
            firstController.stop()

            let retryAttempt = DispatchSemaphore(value: 0)
            LifecycleURLProtocol.reset { _, request in
                .init(
                    status: 200,
                    body: acknowledgementBody(eventID: eventID(in: request)!, duplicate: true)
                )
            }
            let restartedController = AppLifecycleTelemetryController(
                endpoint: endpoint,
                stateStore: store,
                session: testSession(),
                onAttemptFinished: { _ in retryAttempt.signal() }
            )
            restartedController.flush()
            expect(retryAttempt.wait(timeout: .now() + 3) == .success,
                   "\(name) is retried after restart")
            expect(LifecycleURLProtocol.requests.first.flatMap(eventID(in:)) == firstID,
                   "\(name) retry preserves the event UUID")
            expect(restartedController.stateSnapshotForTesting()?.events.isEmpty == true,
                   "\(name) retry drains only after a matching ACK")
            restartedController.stop()
        }
    }

    private static func testPermanentFailureQuarantinesAndAdvances() {
        let firstEvent = queuedVersionEvent()
        let secondEvent = queuedVersionEvent(
            eventID: "33333333-3333-4333-8333-333333333333"
        )
        let attemptsFinished = DispatchSemaphore(value: 0)
        LifecycleURLProtocol.reset { index, request in
            if index == 1 {
                return .init(status: 400, body: Data("{\"error\":\"invalid_event\"}".utf8))
            }
            return .init(
                status: 200,
                body: acknowledgementBody(eventID: eventID(in: request)!)
            )
        }
        let controller = AppLifecycleTelemetryController(
            endpoint: endpoint,
            stateStore: MemoryLifecycleStore(
                state: state(lastSeen: build21, events: [firstEvent, secondEvent])
            ),
            session: testSession(),
            onAttemptFinished: { _ in attemptsFinished.signal() }
        )
        controller.flush()
        expect(attemptsFinished.wait(timeout: .now() + 3) == .success,
               "permanent 4xx is durably classified")
        expect(attemptsFinished.wait(timeout: .now() + 3) == .success,
               "the event after a poison event is attempted")
        let snapshot = controller.stateSnapshotForTesting()
        expect(snapshot?.events.isEmpty == true,
               "a permanent poison event cannot block the following valid event")
        expect(snapshot?.deadLetters.count == 1 &&
               snapshot?.deadLetters.first?.event.eventID == firstEvent.eventID &&
               snapshot?.deadLetters.first?.reason == .permanentHTTPResponse &&
               snapshot?.deadLetters.first?.httpStatus == 400,
               "permanent 4xx moves the exact event to durable quarantine")
        expect(LifecycleURLProtocol.requests.count == 2,
               "queue advances exactly once after the quarantine write succeeds")
        controller.stop()
    }

    private static func testQuarantinePersistenceFailureRetriesSameEvent() {
        let firstAttempt = DispatchSemaphore(value: 0)
        LifecycleURLProtocol.reset { _, _ in .init(status: 422) }
        let store = MemoryLifecycleStore(
            state: state(lastSeen: build21, events: [queuedVersionEvent()]),
            failedSaveCalls: [1]
        )
        let controller = AppLifecycleTelemetryController(
            endpoint: endpoint,
            stateStore: store,
            session: testSession(),
            onAttemptFinished: { _ in firstAttempt.signal() }
        )
        controller.flush()
        expect(firstAttempt.wait(timeout: .now() + 3) == .success,
               "failed quarantine persistence returns control")
        let firstID = LifecycleURLProtocol.requests.first.flatMap(eventID(in:))
        let failedSnapshot = controller.stateSnapshotForTesting()
        expect(failedSnapshot?.events.count == 1 && failedSnapshot?.deadLetters.isEmpty == true,
               "failed atomic quarantine keeps the event active")

        store.allowAllSaves()
        let secondAttempt = DispatchSemaphore(value: 0)
        LifecycleURLProtocol.reset { _, _ in
            secondAttempt.signal()
            return .init(status: 422)
        }
        controller.flush()
        expect(secondAttempt.wait(timeout: .now() + 3) == .success,
               "failed quarantine is retried")
        for _ in 0..<100 where controller.stateSnapshotForTesting()?.deadLetters.count != 1 {
            Thread.sleep(forTimeInterval: 0.01)
        }
        let retryID = LifecycleURLProtocol.requests.first.flatMap(eventID(in:))
        let persistedSnapshot = controller.stateSnapshotForTesting()
        expect(retryID == firstID,
               "quarantine persistence retry preserves the same event UUID")
        expect(persistedSnapshot?.events.isEmpty == true &&
               persistedSnapshot?.deadLetters.count == 1,
               "successful retry atomically moves the event to quarantine")
        controller.stop()
    }

    private static func testRedirectsAreRejected() {
        let redirectTarget = URL(string: "https://redirect-target.example/v1/app-events")!
        for status in [307, 308] {
            let attemptFinished = DispatchSemaphore(value: 0)
            let redirectRejected = DispatchSemaphore(value: 0)
            LifecycleURLProtocol.reset { _, request in
                .init(
                    status: status,
                    body: acknowledgementBody(eventID: eventID(in: request)!),
                    redirectURL: redirectTarget
                )
            }
            let controller = AppLifecycleTelemetryController(
                endpoint: endpoint,
                stateStore: MemoryLifecycleStore(
                    state: state(lastSeen: build21, events: [queuedVersionEvent()])
                ),
                session: testSession(onRedirectRejected: { redirectRejected.signal() }),
                onAttemptFinished: { _ in attemptFinished.signal() }
            )
            controller.flush()
            expect(redirectRejected.wait(timeout: .now() + 3) == .success,
                   "HTTP \(status) invokes the lifecycle redirect rejection policy")
            expect(attemptFinished.wait(timeout: .now() + 3) == .success,
                   "HTTP \(status) redirect rejection returns control")
            let snapshot = controller.stateSnapshotForTesting()
            expect(snapshot?.events.count == 1 && snapshot?.deadLetters.isEmpty == true,
                   "HTTP \(status) redirect transport failure cannot ACK or remove the event")
            expect(LifecycleURLProtocol.requests.count == 1,
                   "HTTP \(status) never sends the lifecycle request to a redirect target")
            expect(LifecycleURLProtocol.requests.first?.url?.host == endpoint.host,
                   "HTTP \(status) keeps the install identifier on the configured origin")
            controller.stop()
        }
    }

    private static func testConcurrentFlushIsSingleFlight() {
        let deliveryGate = DispatchSemaphore(value: 0)
        let requestStarted = DispatchSemaphore(value: 0)
        let attemptFinished = DispatchSemaphore(value: 0)
        LifecycleURLProtocol.reset { _, request in
            requestStarted.signal()
            return .init(
                status: 200,
                body: acknowledgementBody(eventID: eventID(in: request)!),
                deliveryGate: deliveryGate
            )
        }
        let initial = state(lastSeen: build21, events: [queuedVersionEvent()])
        let controller = AppLifecycleTelemetryController(
            endpoint: endpoint,
            stateStore: MemoryLifecycleStore(state: initial),
            session: testSession(),
            onAttemptFinished: { _ in attemptFinished.signal() }
        )
        controller.flush()
        expect(requestStarted.wait(timeout: .now() + 3) == .success,
               "single-flight test starts its first request")
        DispatchQueue.concurrentPerform(iterations: 100) { _ in controller.flush() }
        _ = controller.stateSnapshotForTesting()
        expect(LifecycleURLProtocol.requests.count == 1,
               "concurrent flush calls cannot duplicate an in-flight event")
        deliveryGate.signal()
        expect(attemptFinished.wait(timeout: .now() + 3) == .success,
               "single in-flight request completes")
        controller.stop()
    }

    private static func testEndpointValidation() {
        expect(AppLifecycleTelemetryController.eventEndpoint(infoDictionary: [
            "SUFeedURL": "https://updates.example/appcast.xml?cache=1",
        ])?.absoluteString == "https://updates.example/v1/app-events",
        "telemetry endpoint stays on the configured HTTPS appcast origin")
        expect(AppLifecycleTelemetryController.eventEndpoint(infoDictionary: [
            "SUFeedURL": "http://updates.example/appcast.xml",
        ]) == nil, "non-HTTPS telemetry endpoint is rejected")
        expect(AppLifecycleTelemetryController.eventEndpoint(infoDictionary: [
            "SUFeedURL": "https://user:secret@updates.example/appcast.xml",
        ]) == nil, "userinfo is rejected from telemetry configuration")
    }
}

private final class UUIDSequence {
    private var values: [UUID]

    init(_ strings: [String]) {
        values = strings.compactMap(UUID.init(uuidString:))
    }

    func next() -> UUID {
        guard !values.isEmpty else {
            fatalError("UUIDSequence exhausted")
        }
        return values.removeFirst()
    }
}
