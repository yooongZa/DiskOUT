import Foundation
import os
import Darwin

private let lifecycleTelemetryLog = Logger(
    subsystem: "com.yongza.ejectdrives",
    category: "lifecycle-telemetry"
)

struct AppLifecycleBuild: Codable, Equatable {
    let version: String
    let build: String

    var isValid: Bool {
        Self.isValidComponent(version) && Self.isValidComponent(build)
    }

    private static func isValidComponent(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 64 else { return false }
        return value.unicodeScalars.allSatisfy { scalar in
            scalar.value >= 0x21 && scalar.value <= 0x7e
        }
    }
}

enum AppLifecycleEventType: String, Codable, CaseIterable {
    case firstLaunch = "first_launch"
    case versionSeen = "version_seen"
    case updateCompleted = "update_completed"
}

struct AppLifecycleEvent: Codable, Equatable {
    let eventID: String
    let type: AppLifecycleEventType
    let occurredAt: String
    let app: AppLifecycleBuild
    let previous: AppLifecycleBuild?
    let target: AppLifecycleBuild?

    enum CodingKeys: String, CodingKey {
        case eventID = "event_id"
        case type = "event_type"
        case occurredAt = "occurred_at"
        case app
        case previous
        case target
    }
}

struct AppLifecyclePendingUpdate: Codable, Equatable {
    let source: AppLifecycleBuild
    let target: AppLifecycleBuild
    let markedAt: String

    enum CodingKeys: String, CodingKey {
        case source
        case target
        case markedAt = "marked_at"
    }
}

enum AppLifecycleDeadLetterReason: String, Codable, Equatable {
    case permanentHTTPResponse = "permanent_http_response"
}

struct AppLifecycleDeadLetter: Codable, Equatable {
    let event: AppLifecycleEvent
    let reason: AppLifecycleDeadLetterReason
    let httpStatus: Int?
    let quarantinedAt: String

    enum CodingKeys: String, CodingKey {
        case event
        case reason
        case httpStatus = "http_status"
        case quarantinedAt = "quarantined_at"
    }
}

struct AppLifecycleTelemetryState: Codable, Equatable {
    static let schemaVersion = 1
    static let maximumQueuedEvents = 512
    static let maximumDeadLetters = 512

    let schemaVersion: Int
    let installationID: String
    var lastSeen: AppLifecycleBuild?
    var pendingUpdate: AppLifecyclePendingUpdate?
    var events: [AppLifecycleEvent]
    var deadLetters: [AppLifecycleDeadLetter]

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case installationID = "installation_id"
        case lastSeen = "last_seen"
        case pendingUpdate = "pending_update"
        case events
        case deadLetters = "dead_letters"
    }

    init(installationID: String) {
        schemaVersion = Self.schemaVersion
        self.installationID = installationID
        lastSeen = nil
        pendingUpdate = nil
        events = []
        deadLetters = []
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        installationID = try container.decode(String.self, forKey: .installationID)
        lastSeen = try container.decodeIfPresent(AppLifecycleBuild.self, forKey: .lastSeen)
        pendingUpdate = try container.decodeIfPresent(
            AppLifecyclePendingUpdate.self,
            forKey: .pendingUpdate
        )
        events = try container.decode([AppLifecycleEvent].self, forKey: .events)
        deadLetters = try container.decodeIfPresent(
            [AppLifecycleDeadLetter].self,
            forKey: .deadLetters
        ) ?? []
    }

    var isValid: Bool {
        guard schemaVersion == Self.schemaVersion,
              Self.isCanonicalUUIDv4(installationID),
              events.count <= Self.maximumQueuedEvents,
              deadLetters.count <= Self.maximumDeadLetters,
              lastSeen?.isValid != false,
              pendingUpdate?.source.isValid != false,
              pendingUpdate?.target.isValid != false,
              pendingUpdate.map({ Self.isCanonicalTimestamp($0.markedAt) }) != false else {
            return false
        }

        var identifiers = Set<String>()
        for event in events {
            guard Self.isCanonicalUUIDv4(event.eventID),
                  identifiers.insert(event.eventID).inserted,
                  Self.isCanonicalTimestamp(event.occurredAt),
                  event.app.isValid,
                  event.previous?.isValid != false,
                  event.target?.isValid != false else {
                return false
            }
        }
        for deadLetter in deadLetters {
            let event = deadLetter.event
            guard Self.isCanonicalUUIDv4(event.eventID),
                  identifiers.insert(event.eventID).inserted,
                  Self.isCanonicalTimestamp(event.occurredAt),
                  Self.isCanonicalTimestamp(deadLetter.quarantinedAt),
                  deadLetter.httpStatus.map({ (100...599).contains($0) }) != false,
                  event.app.isValid,
                  event.previous?.isValid != false,
                  event.target?.isValid != false else {
                return false
            }
        }
        return true
    }

    static func isCanonicalUUIDv4(_ value: String) -> Bool {
        guard let uuid = UUID(uuidString: value),
              uuid.uuidString.lowercased() == value.lowercased(),
              value.count == 36 else { return false }
        let characters = Array(value.lowercased())
        return characters[14] == "4" && "89ab".contains(characters[19])
    }

    static func isCanonicalTimestamp(_ value: String) -> Bool {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = formatter.date(from: value) else { return false }
        return formatter.string(from: date) == value
    }
}

enum AppLifecycleLaunchPlanner {
    static func applyingSuccessfulLaunch(
        to previousState: AppLifecycleTelemetryState?,
        current: AppLifecycleBuild,
        priorAppStateExists: Bool,
        now: Date,
        makeUUID: () -> UUID = UUID.init
    ) -> AppLifecycleTelemetryState? {
        guard current.isValid else { return previousState }
        var state = previousState ?? AppLifecycleTelemetryState(
            installationID: makeUUID().uuidString.lowercased()
        )
        guard state.isValid else { return previousState }

        let occurredAt = timestamp(now)
        if previousState == nil && !priorAppStateExists {
            _ = append(
                AppLifecycleEvent(
                    eventID: makeUUID().uuidString.lowercased(),
                    type: .firstLaunch,
                    occurredAt: occurredAt,
                    app: current,
                    previous: nil,
                    target: nil
                ),
                to: &state
            )
        }

        if state.lastSeen != current {
            let previous = state.lastSeen
            if append(
                AppLifecycleEvent(
                    eventID: makeUUID().uuidString.lowercased(),
                    type: .versionSeen,
                    occurredAt: occurredAt,
                    app: current,
                    previous: previous,
                    target: nil
                ),
                to: &state
            ) {
                state.lastSeen = current
            }
        }

        if let pending = state.pendingUpdate {
            let provesCompletedUpdate = pending.target == current &&
                pending.source.build != current.build
            if provesCompletedUpdate {
                let stored = append(
                    AppLifecycleEvent(
                        eventID: makeUUID().uuidString.lowercased(),
                        type: .updateCompleted,
                        occurredAt: occurredAt,
                        app: current,
                        previous: pending.source,
                        target: pending.target
                    ),
                    to: &state
                )
                if stored { state.pendingUpdate = nil }
            } else {
                // A cancel, failed install, manual relaunch of the old build, or rollback cannot
                // prove completion. Consume the stale marker without emitting update_completed.
                state.pendingUpdate = nil
            }
        }

        return state.isValid ? state : previousState
    }

    static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    @discardableResult
    private static func append(
        _ event: AppLifecycleEvent,
        to state: inout AppLifecycleTelemetryState
    ) -> Bool {
        guard state.events.count < AppLifecycleTelemetryState.maximumQueuedEvents else {
            return false
        }
        state.events.append(event)
        return true
    }
}

protocol AppLifecycleTelemetryStateStore: AnyObject {
    var exists: Bool { get }
    func load() throws -> AppLifecycleTelemetryState?
    func save(_ state: AppLifecycleTelemetryState) throws
}

enum AppLifecycleTelemetryStoreError: Error {
    case invalidState
}

private final class AppLifecycleTelemetryProcessLock {
    private let fileDescriptor: Int32

    private init(fileDescriptor: Int32) {
        self.fileDescriptor = fileDescriptor
    }

    static func acquire(fileURL: URL) -> AppLifecycleTelemetryProcessLock? {
        let descriptor = Darwin.open(
            fileURL.path,
            O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW,
            0o600
        )
        guard descriptor >= 0 else { return nil }
        guard Darwin.fchmod(descriptor, 0o600) == 0,
              Darwin.lockf(descriptor, F_TLOCK, 0) == 0 else {
            Darwin.close(descriptor)
            return nil
        }
        return AppLifecycleTelemetryProcessLock(fileDescriptor: descriptor)
    }

    deinit {
        _ = Darwin.lockf(fileDescriptor, F_ULOCK, 0)
        Darwin.close(fileDescriptor)
    }
}

final class AtomicAppLifecycleTelemetryStateStore: AppLifecycleTelemetryStateStore {
    let fileURL: URL
    private let fileManager: FileManager
    private let processLock: AppLifecycleTelemetryProcessLock?

    init(fileURL: URL, fileManager: FileManager = .default) {
        self.fileURL = fileURL
        self.fileManager = fileManager
        processLock = nil
    }

    private init(
        fileURL: URL,
        fileManager: FileManager,
        processLock: AppLifecycleTelemetryProcessLock
    ) {
        self.fileURL = fileURL
        self.fileManager = fileManager
        self.processLock = processLock
    }

    static func live(fileManager: FileManager = .default) -> AtomicAppLifecycleTelemetryStateStore? {
        guard let support = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else { return nil }
        return exclusive(
            fileURL: support
                .appendingPathComponent("DiskOUT", isDirectory: true)
                .appendingPathComponent("app-lifecycle-telemetry-v1.json"),
            fileManager: fileManager
        )
    }

    static func exclusive(
        fileURL: URL,
        fileManager: FileManager = .default
    ) -> AtomicAppLifecycleTelemetryStateStore? {
        let directory = fileURL.deletingLastPathComponent()
        do {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try fileManager.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: directory.path
            )
        } catch {
            return nil
        }
        guard let processLock = AppLifecycleTelemetryProcessLock.acquire(
            fileURL: directory.appendingPathComponent("app-lifecycle-telemetry-v1.lock")
        ) else { return nil }
        return AtomicAppLifecycleTelemetryStateStore(
            fileURL: fileURL,
            fileManager: fileManager,
            processLock: processLock
        )
    }

    var exists: Bool {
        fileManager.fileExists(atPath: fileURL.path)
    }

    func load() throws -> AppLifecycleTelemetryState? {
        guard exists else { return nil }
        let data = try Data(contentsOf: fileURL, options: [.mappedIfSafe])
        let state = try JSONDecoder().decode(AppLifecycleTelemetryState.self, from: data)
        guard state.isValid else { throw AppLifecycleTelemetryStoreError.invalidState }
        return state
    }

    func save(_ state: AppLifecycleTelemetryState) throws {
        guard state.isValid else { throw AppLifecycleTelemetryStoreError.invalidState }
        let directory = fileURL.deletingLastPathComponent()
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(state)
        try data.write(to: fileURL, options: [.atomic])
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }
}

private struct AppLifecycleEventRequest: Encodable {
    let schemaVersion = 1
    let eventID: String
    let installationID: String
    let eventType: String
    let occurredAt: String
    let appVersion: String
    let appBuild: String
    let previousVersion: String?
    let previousBuild: String?
    let targetVersion: String?
    let targetBuild: String?

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case eventID = "event_id"
        case installationID = "install_id"
        case eventType = "event_type"
        case occurredAt = "occurred_at"
        case appVersion = "app_version"
        case appBuild = "app_build"
        case previousVersion = "previous_version"
        case previousBuild = "previous_build"
        case targetVersion = "target_version"
        case targetBuild = "target_build"
    }

    init(event: AppLifecycleEvent, installationID: String) {
        eventID = event.eventID
        self.installationID = installationID
        eventType = event.type.rawValue
        occurredAt = event.occurredAt
        appVersion = event.app.version
        appBuild = event.app.build
        previousVersion = event.previous?.version
        previousBuild = event.previous?.build
        targetVersion = event.target?.version
        targetBuild = event.target?.build
    }
}

private struct AppLifecycleEventAcknowledgement: Decodable {
    let ok: Bool
    let eventID: String

    enum CodingKeys: String, CodingKey {
        case ok
        case eventID = "event_id"
    }
}

private enum AppLifecycleAttemptOutcome {
    case acknowledged
    case retryable
    case quarantine(reason: AppLifecycleDeadLetterReason, httpStatus: Int?)
}

final class AppLifecycleTelemetrySessionDelegate: NSObject, URLSessionTaskDelegate {
    private let onRedirectRejected: (() -> Void)?

    init(onRedirectRejected: (() -> Void)? = nil) {
        self.onRedirectRejected = onRedirectRejected
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        onRedirectRejected?()
        completionHandler(nil)
    }
}

final class AppLifecycleTelemetryController {
    private static let permanentValidationHTTPStatusCodes: Set<Int> = [400, 405, 413, 415, 422]

    private let endpoint: URL?
    private let stateStore: AppLifecycleTelemetryStateStore?
    private let session: URLSession
    private let workQueue: DispatchQueue
    private let onAttemptFinished: ((Bool) -> Void)?
    private var state: AppLifecycleTelemetryState?
    private var didLoadState = false
    private var isDisabled = false
    private var isStopped = false
    private var inFlightEventID: String?
    private var inFlightTask: URLSessionDataTask?

    init(
        endpoint: URL?,
        stateStore: AppLifecycleTelemetryStateStore?,
        session: URLSession,
        workQueue: DispatchQueue = DispatchQueue(
            label: "com.yongza.ejectdrives.lifecycle-telemetry",
            qos: .utility
        ),
        onAttemptFinished: ((Bool) -> Void)? = nil
    ) {
        self.endpoint = endpoint
        self.stateStore = stateStore
        self.session = session
        self.workQueue = workQueue
        self.onAttemptFinished = onAttemptFinished
    }

    static func live(
        infoDictionary: [String: Any] = Bundle.main.infoDictionary ?? [:]
    ) -> AppLifecycleTelemetryController {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 5
        config.timeoutIntervalForResource = 8
        config.waitsForConnectivity = false
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return AppLifecycleTelemetryController(
            endpoint: eventEndpoint(infoDictionary: infoDictionary),
            stateStore: AtomicAppLifecycleTelemetryStateStore.live(),
            session: URLSession(
                configuration: config,
                delegate: AppLifecycleTelemetrySessionDelegate(),
                delegateQueue: nil
            )
        )
    }

    static func currentBuild(
        infoDictionary: [String: Any] = Bundle.main.infoDictionary ?? [:]
    ) -> AppLifecycleBuild? {
        guard let version = infoDictionary["CFBundleShortVersionString"] as? String,
              let build = infoDictionary["CFBundleVersion"] as? String else { return nil }
        let value = AppLifecycleBuild(version: version, build: build)
        return value.isValid ? value : nil
    }

    static func eventEndpoint(infoDictionary: [String: Any]) -> URL? {
        guard let feed = infoDictionary["SUFeedURL"] as? String,
              let url = URL(string: feed),
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "https",
              components.host != nil,
              components.user == nil,
              components.password == nil else { return nil }
        components.path = "/v1/app-events"
        components.query = nil
        components.fragment = nil
        return components.url
    }

    func priorAppStateExists(
        bundleIdentifier: String? = Bundle.main.bundleIdentifier,
        defaults: UserDefaults = .standard
    ) -> Bool {
        if stateStore?.exists == true { return true }
        guard let bundleIdentifier else { return true }
        return !(defaults.persistentDomain(forName: bundleIdentifier) ?? [:]).isEmpty
    }

    func recordSuccessfulLaunch(
        current: AppLifecycleBuild,
        priorAppStateExists: Bool,
        now: Date = Date()
    ) {
        workQueue.async { [weak self] in
            guard let self, !self.isStopped, self.loadStateIfNeeded() else { return }
            let next = AppLifecycleLaunchPlanner.applyingSuccessfulLaunch(
                to: self.state,
                current: current,
                priorAppStateExists: priorAppStateExists,
                now: now
            )
            guard let next else { return }
            if next != self.state, !self.persist(next) { return }
            self.flushNextIfNeeded()
        }
    }

    func markPendingUpdate(
        source: AppLifecycleBuild,
        target: AppLifecycleBuild,
        now: Date = Date()
    ) {
        guard source.isValid, target.isValid, source.build != target.build else { return }
        workQueue.async { [weak self] in
            guard let self, !self.isStopped, self.loadStateIfNeeded(), var next = self.state else {
                return
            }
            next.pendingUpdate = AppLifecyclePendingUpdate(
                source: source,
                target: target,
                markedAt: AppLifecycleLaunchPlanner.timestamp(now)
            )
            _ = self.persist(next)
        }
    }

    func clearPendingUpdate() {
        workQueue.async { [weak self] in
            guard let self, !self.isStopped, self.loadStateIfNeeded(), var next = self.state,
                  next.pendingUpdate != nil else { return }
            next.pendingUpdate = nil
            _ = self.persist(next)
        }
    }

    func flush() {
        workQueue.async { [weak self] in
            guard let self, !self.isStopped, self.loadStateIfNeeded() else { return }
            self.flushNextIfNeeded()
        }
    }

    func stop() {
        workQueue.sync {
            guard !isStopped else { return }
            isStopped = true
            inFlightTask?.cancel()
            inFlightTask = nil
            inFlightEventID = nil
            session.invalidateAndCancel()
        }
    }

    func stateSnapshotForTesting() -> AppLifecycleTelemetryState? {
        workQueue.sync {
            guard loadStateIfNeeded() else { return nil }
            return state
        }
    }

    private func loadStateIfNeeded() -> Bool {
        guard !isDisabled else { return false }
        if didLoadState { return true }
        didLoadState = true
        guard let stateStore else {
            isDisabled = true
            return false
        }
        do {
            state = try stateStore.load()
            return true
        } catch {
            isDisabled = true
            lifecycleTelemetryLog.error("Lifecycle telemetry state could not be loaded; telemetry disabled for this run")
            return false
        }
    }

    @discardableResult
    private func persist(_ next: AppLifecycleTelemetryState) -> Bool {
        guard let stateStore else { return false }
        do {
            try stateStore.save(next)
            state = next
            return true
        } catch {
            lifecycleTelemetryLog.error("Lifecycle telemetry state could not be saved")
            return false
        }
    }

    private func flushNextIfNeeded() {
        guard !isStopped,
              inFlightEventID == nil,
              let endpoint,
              let state,
              let event = state.events.first else { return }

        let payload = AppLifecycleEventRequest(event: event, installationID: state.installationID)
        guard let body = try? JSONEncoder().encode(payload) else { return }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        request.setValue(event.eventID, forHTTPHeaderField: "Idempotency-Key")
        request.httpBody = body
        request.timeoutInterval = 8

        inFlightEventID = event.eventID
        let task = session.dataTask(with: request) { [weak self] data, response, error in
            self?.workQueue.async { [weak self] in
                self?.finishAttempt(
                    eventID: event.eventID,
                    data: data,
                    response: response as? HTTPURLResponse,
                    error: error
                )
            }
        }
        inFlightTask = task
        task.resume()
    }

    private func finishAttempt(
        eventID: String,
        data: Data?,
        response: HTTPURLResponse?,
        error: Error?
    ) {
        guard !isStopped, inFlightEventID == eventID else { return }
        inFlightTask = nil
        inFlightEventID = nil

        let acknowledgement = data.flatMap { body -> AppLifecycleEventAcknowledgement? in
            guard body.count <= 1_024 else { return nil }
            return try? JSONDecoder().decode(AppLifecycleEventAcknowledgement.self, from: body)
        }
        let outcome = attemptOutcome(
            eventID: eventID,
            acknowledgement: acknowledgement,
            response: response,
            error: error
        )
        var removedAfterAcknowledgement = false
        var advancedQueue = false
        switch outcome {
        case .acknowledged:
            if var next = state,
               let index = next.events.firstIndex(where: { $0.eventID == eventID }) {
                next.events.remove(at: index)
                removedAfterAcknowledgement = persist(next)
                advancedQueue = removedAfterAcknowledgement
            }
        case .retryable:
            break
        case let .quarantine(reason, httpStatus):
            advancedQueue = quarantine(
                eventID: eventID,
                reason: reason,
                httpStatus: httpStatus,
                now: Date()
            )
        }
        onAttemptFinished?(removedAfterAcknowledgement)

        if advancedQueue {
            flushNextIfNeeded()
        }
    }

    private func attemptOutcome(
        eventID: String,
        acknowledgement: AppLifecycleEventAcknowledgement?,
        response: HTTPURLResponse?,
        error: Error?
    ) -> AppLifecycleAttemptOutcome {
        guard error == nil, let response else { return .retryable }
        let statusCode = response.statusCode
        if (200...299).contains(statusCode),
           acknowledgement?.ok == true,
           acknowledgement?.eventID == eventID {
            return .acknowledged
        }
        if Self.permanentValidationHTTPStatusCodes.contains(statusCode) {
            return .quarantine(reason: .permanentHTTPResponse, httpStatus: statusCode)
        }
        return .retryable
    }

    private func quarantine(
        eventID: String,
        reason: AppLifecycleDeadLetterReason,
        httpStatus: Int?,
        now: Date
    ) -> Bool {
        guard var next = state,
              let index = next.events.firstIndex(where: { $0.eventID == eventID }) else {
            return false
        }
        let event = next.events.remove(at: index)
        if next.deadLetters.count >= AppLifecycleTelemetryState.maximumDeadLetters {
            next.deadLetters.removeFirst(
                next.deadLetters.count - AppLifecycleTelemetryState.maximumDeadLetters + 1
            )
        }
        next.deadLetters.append(AppLifecycleDeadLetter(
            event: event,
            reason: reason,
            httpStatus: httpStatus,
            quarantinedAt: AppLifecycleLaunchPlanner.timestamp(now)
        ))
        let persisted = persist(next)
        if persisted {
            lifecycleTelemetryLog.error("Lifecycle telemetry event moved to durable quarantine")
        }
        return persisted
    }
}
