import CryptoKit
import Foundation

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

private final class MemoryBillingSecureStore: BillingSecureStore {
    private let lock = NSLock()
    private var values: [String: Data]
    private let failingAccounts: Set<String>
    private let failingRemovalAccounts: Set<String>
    private var _readAccounts: [String] = []
    private var _writtenAccounts: [String] = []
    private var _removedAccounts: [String] = []

    init(values: [String: Data] = [:],
         failingAccounts: Set<String> = [],
         failingRemovalAccounts: Set<String> = []) {
        self.values = values
        self.failingAccounts = failingAccounts
        self.failingRemovalAccounts = failingRemovalAccounts
    }

    func data(for account: String) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        _readAccounts.append(account)
        return values[account]
    }

    @discardableResult
    func set(_ data: Data, for account: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        _writtenAccounts.append(account)
        if failingAccounts.contains(account) { return false }
        values[account] = data
        return true
    }

    @discardableResult
    func remove(account: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        _removedAccounts.append(account)
        if failingRemovalAccounts.contains(account) { return false }
        values.removeValue(forKey: account)
        return true
    }

    var readAccounts: [String] {
        lock.lock()
        defer { lock.unlock() }
        return _readAccounts
    }

    var writtenAccounts: [String] {
        lock.lock()
        defer { lock.unlock() }
        return _writtenAccounts
    }

    var removedAccounts: [String] {
        lock.lock()
        defer { lock.unlock() }
        return _removedAccounts
    }
}

private final class StubURLProtocol: URLProtocol {
    private static let sessionHeaderName = "X-DiskOUT-Test-Session"

    struct Plan {
        let delay: TimeInterval
        let statusCode: Int
        let data: Data
        let deliveryGate: DispatchSemaphore?

        init(delay: TimeInterval = 0,
             statusCode: Int = 200,
             data: Data,
             deliveryGate: DispatchSemaphore? = nil) {
            self.delay = delay
            self.statusCode = statusCode
            self.data = data
            self.deliveryGate = deliveryGate
        }
    }

    private static let stateLock = NSLock()
    private static var responder: ((Int, URLRequest) -> Plan)?
    private static var _requestCount = 0
    private static var _deliveryAttemptCount = 0
    private static var _requests: [URLRequest] = []
    private static var _currentSessionID = ""
    private static var _responseGeneration = 0

    private let instanceLock = NSLock()
    private var stopped = false

    static var requestCount: Int {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _requestCount
    }

    static var deliveryAttemptCount: Int {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _deliveryAttemptCount
    }

    static var requests: [URLRequest] {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _requests
    }

    static var sessionHeaders: [AnyHashable: Any] {
        stateLock.withLock {
            _currentSessionID = UUID().uuidString
            _responseGeneration += 1
            _requestCount = 0
            _deliveryAttemptCount = 0
            _requests = []
            return [sessionHeaderName: _currentSessionID]
        }
    }

    static func reset(
        preservingSession: Bool = false,
        responder: @escaping (Int, URLRequest) -> Plan
    ) {
        stateLock.lock()
        defer { stateLock.unlock() }
        if !preservingSession {
            _currentSessionID = ""
        }
        _responseGeneration += 1
        self.responder = responder
        _requestCount = 0
        _deliveryAttemptCount = 0
        _requests = []
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
            while true {
                let readCount = stream.read(&buffer, maxLength: buffer.count)
                if readCount <= 0 { break }
                body.append(buffer, count: readCount)
            }
            capturedRequest.httpBody = body
            capturedRequest.httpBodyStream = nil
        }
        let entry: (Int, Int, (Int, URLRequest) -> Plan)? = Self.stateLock.withLock {
            guard capturedRequest.value(forHTTPHeaderField: Self.sessionHeaderName)
                    == Self._currentSessionID,
                  let responder = Self.responder else { return nil }
            let index = Self._requestCount
            Self._requestCount += 1
            Self._requests.append(capturedRequest)
            return (index, Self._responseGeneration, responder)
        }
        guard let (index, generation, responder) = entry else {
            client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable))
            return
        }
        let plan = responder(index, capturedRequest)

        DispatchQueue.global().asyncAfter(deadline: .now() + plan.delay) { [self] in
            plan.deliveryGate?.wait()
            Self.stateLock.withLock {
                if Self._responseGeneration == generation {
                    Self._deliveryAttemptCount += 1
                }
            }
            let wasStopped = instanceLock.withLock { stopped }
            guard !wasStopped else { return }

            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: plan.statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: plan.data)
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {
        instanceLock.withLock { stopped = true }
    }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}

private final class TestBillingScheduledAction: BillingScheduledAction {
    private(set) var isCancelled = false

    func cancel() {
        isCancelled = true
    }
}

private final class TestBillingScheduler: BillingScheduling {
    private struct Entry {
        let deadline: Date
        let sequence: Int
        let token: TestBillingScheduledAction
        let action: () -> Void
    }

    private var entries: [Entry] = []
    private var nextSequence = 0
    private(set) var now: Date

    init(now: Date) {
        self.now = now
    }

    @discardableResult
    func schedule(after delay: TimeInterval,
                  action: @escaping () -> Void) -> BillingScheduledAction {
        let token = TestBillingScheduledAction()
        entries.append(Entry(
            deadline: now.addingTimeInterval(max(0, delay)),
            sequence: nextSequence,
            token: token,
            action: action
        ))
        nextSequence += 1
        return token
    }

    var pendingActionCount: Int {
        entries.lazy.filter { !$0.token.isCancelled }.count
    }

    func advance(by interval: TimeInterval) {
        precondition(Thread.isMainThread)
        let target = now.addingTimeInterval(interval)

        while let nextIndex = entries.indices
            .filter({ !entries[$0].token.isCancelled && entries[$0].deadline <= target })
            .min(by: {
                let lhs = entries[$0]
                let rhs = entries[$1]
                if lhs.deadline == rhs.deadline { return lhs.sequence < rhs.sequence }
                return lhs.deadline < rhs.deadline
            }) {
            let entry = entries.remove(at: nextIndex)
            now = entry.deadline
            if !entry.token.isCancelled {
                entry.action()
            }
        }

        now = target
        entries.removeAll { $0.token.isCancelled }
    }
}

@main
private enum PaddleBillingControllerTests {
    private static let installationID = "11111111-2222-4333-8444-555555555555"
    private static let oneTimePriceID = "pri_abcdefghijklmnopqrstuvwxyz"

    private struct SignedEnvelope: Codable {
        var payload: String
        var signature: String
    }

    private static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        configuration.httpAdditionalHeaders = StubURLProtocol.sessionHeaders
        return URLSession(configuration: configuration)
    }

    private static func makeConfiguration(
        publicKey: Curve25519.Signing.PublicKey
    ) -> PaddleBillingConfiguration {
        PaddleBillingConfiguration(infoDictionary: [
            "DiskOUTBillingBaseURL": "https://billing.test",
            "DiskOUTPaddleOneTimePriceID": oneTimePriceID,
            "DiskOUTEntitlementPublicKey": publicKey.rawRepresentation.base64EncodedString(),
        ])
    }

    private static func makeStore(cachedEntitlement: Data? = nil) -> MemoryBillingSecureStore {
        var values = ["installation-id": Data(installationID.utf8)]
        if let cachedEntitlement {
            values["entitlement-envelope"] = cachedEntitlement
        }
        return MemoryBillingSecureStore(values: values)
    }

    private static func signedEnvelope(
        status: PremiumEntitlementStatus,
        key: Curve25519.Signing.PrivateKey,
        schemaVersion: Int = 2,
        installID: String = installationID,
        priceID: String = oneTimePriceID,
        entitlement: String = "perpetual",
        issuedAt: Date = Date(),
        expiresAt: Date = Date().addingTimeInterval(60)
    ) throws -> Data {
        let payload = PremiumAccessPayload(
            schemaVersion: schemaVersion,
            installID: installID,
            status: status,
            priceID: priceID,
            entitlement: entitlement,
            issuedAt: issuedAt,
            expiresAt: expiresAt
        )
        let payloadEncoder = JSONEncoder()
        payloadEncoder.outputFormatting = [.sortedKeys]
        payloadEncoder.dateEncodingStrategy = .custom { date, encoder in
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            var container = encoder.singleValueContainer()
            try container.encode(formatter.string(from: date))
        }
        let payloadData = try payloadEncoder.encode(payload)
        let signature = try key.signature(for: payloadData)
        return try JSONEncoder().encode(SignedEnvelope(
            payload: payloadData.base64EncodedString(),
            signature: signature.base64EncodedString()
        ))
    }

    private static func tamperingSignature(in data: Data) throws -> Data {
        var envelope = try JSONDecoder().decode(SignedEnvelope.self, from: data)
        var signature = Data(base64Encoded: envelope.signature)!
        signature[signature.startIndex] ^= 0x01
        envelope.signature = signature.base64EncodedString()
        return try JSONEncoder().encode(envelope)
    }

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    @discardableResult
    private static func waitUntil(
        timeout: TimeInterval = 2,
        _ condition: () -> Bool
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.005))
        }
        return condition()
    }

    private static func pumpMainRunLoop(for duration: TimeInterval) {
        let deadline = Date().addingTimeInterval(duration)
        while Date() < deadline {
            _ = RunLoop.main.run(mode: .default, before: min(deadline, Date().addingTimeInterval(0.005)))
        }
    }

    private static func testMissingConfigurationFailsClosedWithoutNetwork() {
        StubURLProtocol.reset { _, _ in
            StubURLProtocol.Plan(data: Data())
        }
        let session = makeSession()
        let store = makeStore()
        let controller = PaddleBillingController(
            configuration: PaddleBillingConfiguration(infoDictionary: [:]),
            secureStore: store,
            session: session,
            purchasePollDelays: [0.001]
        )
        var pollingChanges: [Bool] = []
        controller.onPurchasePollingChanged = { pollingChanges.append($0) }

        controller.start()
        controller.startPurchasePolling()
        pumpMainRunLoop(for: 0.03)

        expect(!controller.isConfigured, "missing billing configuration remains unconfigured")
        expect(!controller.hasPremiumAccess, "missing billing configuration fails closed")
        expect(StubURLProtocol.requestCount == 0, "missing billing configuration performs no request")
        expect(store.readAccounts.isEmpty, "disabled billing performs no Keychain reads")
        expect(store.writtenAccounts.isEmpty, "disabled billing performs no Keychain writes")
        expect(!controller.isPurchasePolling && pollingChanges.isEmpty,
               "disabled billing cannot enter purchase polling")
        controller.stop()
        session.invalidateAndCancel()
    }

    private static func testConfigurationRejectsMalformedPublicSettingsAndPreservesBasePath() {
        let key = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation.base64EncodedString()
        func configuration(baseURL: String, priceID: String = oneTimePriceID) -> PaddleBillingConfiguration {
            PaddleBillingConfiguration(infoDictionary: [
                "DiskOUTBillingBaseURL": baseURL,
                "DiskOUTPaddleOneTimePriceID": priceID,
                "DiskOUTEntitlementPublicKey": key,
            ])
        }

        let valid = configuration(baseURL: "https://billing.test/tenant/root/")
        expect(valid.isConfigured, "exact Paddle price ID and credential-free HTTPS base URL configure billing")
        expect(valid.entitlementURL()?.absoluteString ==
               "https://billing.test/tenant/root/v1/entitlement",
               "entitlement endpoint preserves the configured base path")
        expect(valid.restoreURL()?.absoluteString == "https://billing.test/tenant/root/v1/restore",
               "restore endpoint preserves the configured base path")
        expect(valid.portalURL()?.absoluteString == "https://billing.test/tenant/root/v1/portal",
               "portal endpoint preserves the configured base path")
        let checkout = valid.checkoutURL(
            installationID: installationID,
            bindingSecret: String(repeating: "B", count: 43)
        )
        expect(checkout?.path == "/tenant/root/checkout" && checkout?.query == nil,
               "checkout endpoint preserves the base path without putting credentials in the query")

        for invalidURL in [
            "http://billing.test/api",
            "https://user:password@billing.test/api",
            "https://billing.test/api?token=secret",
            "https://billing.test/api#secret",
        ] {
            expect(!configuration(baseURL: invalidURL).isConfigured,
                   "billing base URL rejects HTTP, credentials, query, and fragment: \(invalidURL)")
        }
        expect(configuration(baseURL: "http://localhost:8787/test").isConfigured,
               "localhost HTTP remains available for billing integration tests")

        for invalidPriceID in [
            "pri_",
            "pri_abcdefghijklmnopqrstuvwxy",
            "pri_abcdefghijklmnopqrstuvwxyz0",
            "pri_abcdefghijklmnopqrstuvw_y",
            "pri_ABCDEFGHIJKLMNOPQRSTUVWXY0",
            "REPLACE_WITH_PADDLE_ONE_TIME_PRICE_ID",
        ] {
            expect(!configuration(baseURL: "https://billing.test", priceID: invalidPriceID).isConfigured,
                   "malformed or placeholder Paddle price ID fails closed: \(invalidPriceID)")
        }
    }

    private static func testBindingCredentialPersistenceFailsClosed() {
        let key = Curve25519.Signing.PrivateKey()
        let store = MemoryBillingSecureStore(
            values: ["installation-id": Data(installationID.utf8)],
            failingAccounts: ["binding-secret"]
        )
        let session = makeSession()
        let controller = PaddleBillingController(
            configuration: makeConfiguration(publicKey: key.publicKey),
            secureStore: store,
            session: session
        )

        controller.start()
        expect(!controller.isConfigured, "binding credential persistence failure disables billing")
        expect(controller.checkoutURL == nil, "checkout is hidden when its binding credential cannot persist")
        expect(!controller.canOpenPurchaseDetails, "purchase details fail closed without a persisted credential")
        expect(StubURLProtocol.requestCount == 0, "binding credential failure performs no network request")
        controller.stop()
        session.invalidateAndCancel()
    }

    private static func testInstallationIDPersistenceFailsClosed() {
        StubURLProtocol.reset { _, _ in StubURLProtocol.Plan(data: Data()) }
        let key = Curve25519.Signing.PrivateKey()
        let store = MemoryBillingSecureStore(failingAccounts: ["installation-id"])
        let session = makeSession()
        let controller = PaddleBillingController(
            configuration: makeConfiguration(publicKey: key.publicKey),
            secureStore: store,
            session: session
        )

        controller.start()
        expect(!controller.isConfigured, "installation ID persistence failure disables billing")
        expect(controller.checkoutURL == nil, "unpersisted installation ID cannot enter checkout")
        expect(controller.recoveryCode == nil, "unpersisted installation ID exposes no recovery code")
        pumpMainRunLoop(for: 0.03)
        expect(StubURLProtocol.requestCount == 0, "installation ID failure performs no network request")
        controller.stop()
        session.invalidateAndCancel()
    }

    private static func testLegacyPortalCredentialCreatesFreshBindingWithoutDeletingLegacy() {
        let key = Curve25519.Signing.PrivateKey()
        let legacySecret = String(repeating: "L", count: 43)
        let store = MemoryBillingSecureStore(values: [
            "installation-id": Data(installationID.utf8),
            "portal-secret": Data(legacySecret.utf8),
        ])
        let session = makeSession()
        let controller = PaddleBillingController(
            configuration: makeConfiguration(publicKey: key.publicKey),
            secureStore: store,
            session: session
        )

        let bindingSecret = String(
            data: store.data(for: "binding-secret") ?? Data(),
            encoding: .utf8
        ) ?? ""
        expect(controller.isConfigured, "legacy installation receives a fresh v2 binding credential")
        expect(bindingSecret.count == 43 && bindingSecret != legacySecret,
               "legacy portal credential is never reused as the v2 binding credential")
        expect(store.data(for: "portal-secret") == Data(legacySecret.utf8),
               "legacy credential remains intact for subscription-era compatibility")
        expect(controller.recoveryCode == "DOUT1.\(bindingSecret)",
               "recovery code exposes only the newly generated v2 credential")
        expect(!store.removedAccounts.contains("portal-secret"),
               "legacy credential is never deleted during v2 credential creation")
        controller.stop()
        session.invalidateAndCancel()

        let copiedStore = MemoryBillingSecureStore(values: [
            "installation-id": Data(installationID.utf8),
            "binding-secret": Data(legacySecret.utf8),
            "portal-secret": Data(legacySecret.utf8),
        ])
        let copiedSession = makeSession()
        let repairedController = PaddleBillingController(
            configuration: makeConfiguration(publicKey: key.publicKey),
            secureStore: copiedStore,
            session: copiedSession
        )
        let repairedBinding = String(
            data: copiedStore.data(for: "binding-secret") ?? Data(),
            encoding: .utf8
        ) ?? ""
        expect(repairedController.isConfigured && repairedBinding.count == 43,
               "previously copied legacy credential is repaired with a valid v2 secret")
        expect(repairedBinding != legacySecret,
               "repair path also prevents legacy portal credential reuse")
        expect(copiedStore.data(for: "portal-secret") == Data(legacySecret.utf8),
               "repair path preserves the legacy credential")
        repairedController.stop()
        copiedSession.invalidateAndCancel()

        let failingCopiedStore = MemoryBillingSecureStore(
            values: [
                "installation-id": Data(installationID.utf8),
                "binding-secret": Data(legacySecret.utf8),
                "portal-secret": Data(legacySecret.utf8),
            ],
            failingAccounts: ["binding-secret"]
        )
        let failingCopiedSession = makeSession()
        let failedRepairController = PaddleBillingController(
            configuration: makeConfiguration(publicKey: key.publicKey),
            secureStore: failingCopiedStore,
            session: failingCopiedSession
        )
        expect(!failedRepairController.isConfigured,
               "failed rotation of an exactly copied legacy credential fails closed")
        expect(failingCopiedStore.data(for: "binding-secret") == Data(legacySecret.utf8),
               "failed rotation never pretends the legacy copy became a v2 credential")
        expect(failingCopiedStore.data(for: "portal-secret") == Data(legacySecret.utf8),
               "failed rotation still preserves the legacy credential")
        failedRepairController.stop()
        failingCopiedSession.invalidateAndCancel()
    }

    private static func testMissingInstallationRotatesSurvivingBindingSecret() throws {
        let key = Curve25519.Signing.PrivateKey()
        let oldSecret = String(repeating: "G", count: 43)
        let store = MemoryBillingSecureStore(values: [
            "binding-secret": Data(oldSecret.utf8),
        ])
        let session = makeSession()
        let controller = PaddleBillingController(
            configuration: makeConfiguration(publicKey: key.publicKey),
            secureStore: store,
            session: session
        )
        let newSecret = String(data: store.data(for: "binding-secret") ?? Data(), encoding: .utf8) ?? ""

        expect(controller.isConfigured, "missing installation ID creates a new persistent credential pair")
        expect(controller.installationID != installationID && UUID(uuidString: controller.installationID) != nil,
               "missing installation ID is replaced with a fresh UUID")
        expect(newSecret.count == 43 && newSecret != oldSecret,
               "surviving old binding secret rotates before pairing with the new installation")
        expect(controller.recoveryCode == "DOUT1.\(newSecret)",
               "current recovery code exposes only the rotated binding secret")

        let request = PaddleBillingController.makeRestoreRequest(
            url: URL(string: "https://billing.test/v1/restore")!,
            installationID: controller.installationID,
            sourceSecret: oldSecret,
            requestID: UUID().uuidString.lowercased(),
            currentBindingSecret: newSecret
        )!
        let body = try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any]
        expect(body?["new_credential_sha256"] as? String == sha256Hex(Data(newSecret.utf8)),
               "restore binds the rotated current credential hash")
        expect(body?["new_credential_sha256"] as? String != sha256Hex(Data(oldSecret.utf8)),
               "restore never sends an oldHash-equals-newHash request")
        controller.stop()
        session.invalidateAndCancel()
    }

    private static func testValidSignedActiveLeaseGrants() throws {
        let key = Curve25519.Signing.PrivateKey()
        let envelope = try signedEnvelope(status: .active, key: key)
        StubURLProtocol.reset { _, _ in StubURLProtocol.Plan(data: envelope) }
        let session = makeSession()
        let store = makeStore()
        let controller = PaddleBillingController(
            configuration: makeConfiguration(publicKey: key.publicKey),
            secureStore: store,
            session: session
        )
        var result: Bool?

        controller.refresh { result = $0 }
        expect(waitUntil { result != nil }, "signed active refresh completes")
        expect(result == true, "signed active response is accepted")
        expect(controller.hasPremiumAccess, "signed active lease grants Premium")
        expect(controller.entitlementStatus == .active, "active status is retained")
        expect(store.data(for: "entitlement-envelope") == envelope, "verified envelope is cached")
        expect(StubURLProtocol.requests.count == 1, "active refresh uses one request")
        let request = StubURLProtocol.requests[0]
        let bindingSecret = String(data: store.data(for: "binding-secret") ?? Data(), encoding: .utf8)
        expect(request.httpMethod == "POST", "entitlement refresh uses POST")
        expect(request.url?.path == "/v1/entitlement", "installation ID is absent from entitlement URL")
        expect(request.value(forHTTPHeaderField: "X-DiskOUT-Install-ID") == installationID,
               "entitlement refresh sends installation ID in a header")
        expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(bindingSecret ?? "")",
               "entitlement refresh authenticates with the persisted binding secret")
        expect(request.httpBody == nil, "entitlement refresh sends no raw credential body")
        controller.stop()
        session.invalidateAndCancel()
    }

    private static func testConcurrentRefreshIsSingleFlight() throws {
        let key = Curve25519.Signing.PrivateKey()
        let envelope = try signedEnvelope(status: .active, key: key)
        StubURLProtocol.reset { _, _ in StubURLProtocol.Plan(delay: 0.04, data: envelope) }
        let session = makeSession()
        let controller = PaddleBillingController(
            configuration: makeConfiguration(publicKey: key.publicKey),
            secureStore: makeStore(),
            session: session
        )
        var results: [Bool] = []

        controller.refresh { results.append($0) }
        controller.refresh { results.append($0) }

        expect(waitUntil { results.count == 2 }, "both coalesced refresh callbacks complete")
        expect(results == [true, true], "both coalesced refresh callbacks receive success")
        expect(StubURLProtocol.requestCount == 1, "concurrent refresh uses one network request")
        controller.stop()
        session.invalidateAndCancel()
    }

    private static func testTamperedRefreshPreservesCachedLease() throws {
        let key = Curve25519.Signing.PrivateKey()
        let cached = try signedEnvelope(status: .active, key: key)
        let tampered = try tamperingSignature(in: cached)
        StubURLProtocol.reset { _, _ in StubURLProtocol.Plan(data: tampered) }
        let session = makeSession()
        let store = makeStore(cachedEntitlement: cached)
        let controller = PaddleBillingController(
            configuration: makeConfiguration(publicKey: key.publicKey),
            secureStore: store,
            session: session
        )
        var joinedRefreshResult: Bool?

        controller.start()
        expect(controller.hasPremiumAccess, "valid cached lease grants synchronously at start")
        controller.refresh { joinedRefreshResult = $0 }

        expect(waitUntil { joinedRefreshResult != nil }, "tampered refresh completes")
        expect(joinedRefreshResult == false, "tampered response reports refresh failure")
        expect(controller.hasPremiumAccess, "tampered response preserves unexpired cached access")
        expect(controller.entitlementStatus == .active, "tampered response preserves cached status")
        expect(store.data(for: "entitlement-envelope") == cached, "tampered response is not cached")
        controller.stop()
        session.invalidateAndCancel()
    }

    private static func testSignedWrongBindingPreservesCachedLease() throws {
        let key = Curve25519.Signing.PrivateKey()
        let cached = try signedEnvelope(status: .active, key: key)
        let wrongInstall = try signedEnvelope(
            status: .active,
            key: key,
            installID: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
        )
        StubURLProtocol.reset { _, _ in StubURLProtocol.Plan(data: wrongInstall) }
        let session = makeSession()
        let store = makeStore(cachedEntitlement: cached)
        let controller = PaddleBillingController(
            configuration: makeConfiguration(publicKey: key.publicKey),
            secureStore: store,
            session: session
        )
        var result: Bool?

        controller.start()
        expect(controller.hasPremiumAccess, "cached bound lease starts granted")
        controller.refresh { result = $0 }

        expect(waitUntil { result != nil }, "wrong-binding refresh completes")
        expect(result == false, "signed response for another install is rejected")
        expect(controller.hasPremiumAccess, "wrong-binding response preserves cached access")
        expect(store.data(for: "entitlement-envelope") == cached,
               "wrong-binding response cannot replace the cached lease")
        controller.stop()
        session.invalidateAndCancel()
    }

    private static func testSignedInvalidV2PayloadsFailClosed() throws {
        let key = Curve25519.Signing.PrivateKey()
        let now = Date()
        let invalidPayloads: [(String, Data)] = [
            ("schema", try signedEnvelope(status: .active, key: key, schemaVersion: 1)),
            ("price", try signedEnvelope(status: .active, key: key, priceID: "pri_wrong_one_time")),
            ("entitlement", try signedEnvelope(status: .active, key: key, entitlement: "subscription")),
            ("issued_at", try signedEnvelope(
                status: .active,
                key: key,
                issuedAt: now.addingTimeInterval(5 * 60 + 1),
                expiresAt: now.addingTimeInterval(10 * 60)
            )),
            ("duration", try signedEnvelope(
                status: .active,
                key: key,
                issuedAt: now,
                expiresAt: now.addingTimeInterval(30 * 24 * 60 * 60 + 1)
            )),
        ]

        for (label, envelope) in invalidPayloads {
            StubURLProtocol.reset { _, _ in StubURLProtocol.Plan(data: envelope) }
            let session = makeSession()
            let store = makeStore()
            let controller = PaddleBillingController(
                configuration: makeConfiguration(publicKey: key.publicKey),
                secureStore: store,
                session: session
            )
            var result: Bool?

            controller.refresh { result = $0 }
            expect(waitUntil { result != nil }, "signed invalid \(label) refresh completes")
            expect(result == false, "signed invalid \(label) payload is rejected")
            expect(!controller.hasPremiumAccess, "signed invalid \(label) payload cannot grant")
            expect(store.data(for: "entitlement-envelope") == nil,
                   "signed invalid \(label) payload is not cached")
            controller.stop()
            session.invalidateAndCancel()
        }
    }

    private static func testSignedRefundedLeaseRevokes() throws {
        let key = Curve25519.Signing.PrivateKey()
        let cached = try signedEnvelope(status: .active, key: key)
        let refunded = try signedEnvelope(status: .refunded, key: key)
        StubURLProtocol.reset { _, _ in StubURLProtocol.Plan(data: refunded) }
        let session = makeSession()
        let controller = PaddleBillingController(
            configuration: makeConfiguration(publicKey: key.publicKey),
            secureStore: makeStore(cachedEntitlement: cached),
            session: session
        )
        var result: Bool?

        controller.start()
        expect(controller.hasPremiumAccess, "cached active lease starts granted")
        controller.refresh { result = $0 }

        expect(waitUntil { result != nil }, "signed refunded refresh completes")
        expect(result == true, "valid signed refunded response is a successful refresh")
        expect(!controller.hasPremiumAccess, "signed refunded response revokes Premium")
        expect(controller.entitlementStatus == .refunded, "refunded status is retained")
        controller.stop()
        session.invalidateAndCancel()
    }

    private static func testSignedChargebackLeaseRevokes() throws {
        let key = Curve25519.Signing.PrivateKey()
        let cached = try signedEnvelope(status: .active, key: key)
        let chargeback = try signedEnvelope(status: .chargeback, key: key)
        StubURLProtocol.reset { _, _ in StubURLProtocol.Plan(data: chargeback) }
        let session = makeSession()
        let controller = PaddleBillingController(
            configuration: makeConfiguration(publicKey: key.publicKey),
            secureStore: makeStore(cachedEntitlement: cached),
            session: session
        )
        var result: Bool?

        controller.start()
        expect(controller.hasPremiumAccess, "cached active lease starts granted before chargeback refresh")
        controller.refresh { result = $0 }

        expect(waitUntil { result != nil }, "signed chargeback refresh completes")
        expect(result == true, "valid signed chargeback is a successful denial refresh")
        expect(!controller.hasPremiumAccess, "signed chargeback revokes Premium")
        expect(controller.entitlementStatus == .chargeback, "chargeback status is retained")
        controller.stop()
        session.invalidateAndCancel()
    }

    private static func testDenialPersistenceFailureRemovesStaleGrant() throws {
        let key = Curve25519.Signing.PrivateKey()
        let cached = try signedEnvelope(status: .active, key: key)
        let refunded = try signedEnvelope(status: .refunded, key: key)
        StubURLProtocol.reset { _, _ in StubURLProtocol.Plan(data: refunded) }
        let session = makeSession()
        let store = MemoryBillingSecureStore(
            values: [
                "installation-id": Data(installationID.utf8),
                "entitlement-envelope": cached,
            ],
            failingAccounts: ["entitlement-envelope"]
        )
        let controller = PaddleBillingController(
            configuration: makeConfiguration(publicKey: key.publicKey),
            secureStore: store,
            session: session
        )

        controller.start()
        expect(controller.hasPremiumAccess, "cached active grant is applied before denial refresh")
        expect(waitUntil { !controller.hasPremiumAccess }, "signed refund revokes the current session")
        expect(store.removedAccounts.contains("entitlement-envelope"),
               "denial removes the stale active envelope before persistence")
        expect(store.data(for: "entitlement-envelope") == nil,
               "failed denial write cannot leave the old active envelope behind")
        controller.stop()
        session.invalidateAndCancel()

        StubURLProtocol.reset { _, _ in StubURLProtocol.Plan(statusCode: 503, data: Data()) }
        let relaunchSession = makeSession()
        let relaunched = PaddleBillingController(
            configuration: makeConfiguration(publicKey: key.publicKey),
            secureStore: store,
            session: relaunchSession
        )
        relaunched.start()
        expect(!relaunched.hasPremiumAccess,
               "relaunch cannot reactivate a stale cached grant after denial persistence failure")
        relaunched.stop()
        relaunchSession.invalidateAndCancel()
    }

    private static func testShortLeaseAutoExpires() throws {
        let key = Curve25519.Signing.PrivateKey()
        let envelope = try signedEnvelope(
            status: .active,
            key: key,
            expiresAt: Date().addingTimeInterval(0.35)
        )
        StubURLProtocol.reset { _, _ in StubURLProtocol.Plan(data: envelope) }
        let session = makeSession()
        let controller = PaddleBillingController(
            configuration: makeConfiguration(publicKey: key.publicKey),
            secureStore: makeStore(),
            session: session
        )
        var result: Bool?
        var accessChanges: [Bool] = []
        controller.onAccessChanged = { accessChanges.append($0) }

        controller.refresh { result = $0 }
        expect(waitUntil { result != nil }, "short lease refresh completes")
        expect(result == true && controller.hasPremiumAccess, "short valid lease initially grants")
        expect(waitUntil(timeout: 1.5) { !controller.hasPremiumAccess }, "short lease auto-expires")
        expect(controller.entitlementStatus == .free, "auto-expired lease resets status to free")
        expect(accessChanges == [true, false], "short lease emits one grant and one revocation")
        controller.stop()
        session.invalidateAndCancel()
    }

    private static func testAutomaticRenewalExtendsActiveLease() throws {
        let key = Curve25519.Signing.PrivateKey()
        let base = Date(timeIntervalSince1970: 2_000_000_000)
        let scheduler = TestBillingScheduler(now: base)
        let initial = try signedEnvelope(
            status: .active,
            key: key,
            issuedAt: base,
            expiresAt: base.addingTimeInterval(100)
        )
        let renewed = try signedEnvelope(
            status: .active,
            key: key,
            issuedAt: base.addingTimeInterval(50),
            expiresAt: base.addingTimeInterval(200)
        )
        StubURLProtocol.reset { index, _ in
            StubURLProtocol.Plan(data: index == 0 ? initial : renewed)
        }
        let session = makeSession()
        let store = makeStore()
        let controller = PaddleBillingController(
            configuration: makeConfiguration(publicKey: key.publicKey),
            secureStore: store,
            session: session,
            scheduler: scheduler,
            refreshSchedule: PaddleBillingRefreshSchedule(
                renewalLeadFraction: 0.5,
                maximumRenewalLeadTime: 100,
                minimumRenewalDelay: 0.1,
                renewalRetryDelays: [1],
                expiredRecoveryDelays: [1]
            )
        )
        var initialResult: Bool?

        controller.refresh { initialResult = $0 }
        expect(waitUntil { initialResult != nil }, "initial lease refresh completes")
        expect(controller.hasPremiumAccess, "initial lease grants before renewal")
        scheduler.advance(by: 49.9)
        expect(StubURLProtocol.requestCount == 1, "renewal does not run before its deadline")

        scheduler.advance(by: 0.1)
        expect(waitUntil { StubURLProtocol.requestCount == 2 }, "renewal runs before lease expiry")
        expect(waitUntil { store.data(for: "entitlement-envelope") == renewed },
               "renewal stores the extended signed lease")
        expect(controller.hasPremiumAccess, "successful renewal keeps Premium continuously granted")

        controller.stop()
        session.invalidateAndCancel()
    }

    private static func testPerpetualLeaseRefreshesEveryTwentyFourHours() throws {
        let key = Curve25519.Signing.PrivateKey()
        let base = Date(timeIntervalSince1970: 2_000_100_000)
        let scheduler = TestBillingScheduler(now: base)
        let initial = try signedEnvelope(
            status: .active,
            key: key,
            issuedAt: base,
            expiresAt: base.addingTimeInterval(30 * 24 * 60 * 60)
        )
        let renewed = try signedEnvelope(
            status: .active,
            key: key,
            issuedAt: base.addingTimeInterval(24 * 60 * 60),
            expiresAt: base.addingTimeInterval(31 * 24 * 60 * 60)
        )
        StubURLProtocol.reset { index, _ in
            StubURLProtocol.Plan(data: index == 0 ? initial : renewed)
        }
        let session = makeSession()
        let store = makeStore()
        let controller = PaddleBillingController(
            configuration: makeConfiguration(publicKey: key.publicKey),
            secureStore: store,
            session: session,
            scheduler: scheduler
        )
        var initialResult: Bool?

        controller.refresh { initialResult = $0 }
        expect(waitUntil { initialResult != nil }, "30-day perpetual lease refresh completes")
        scheduler.advance(by: 24 * 60 * 60 - 0.001)
        expect(StubURLProtocol.requestCount == 1, "daily refresh does not run before 24 hours")
        scheduler.advance(by: 0.002)
        expect(waitUntil { StubURLProtocol.requestCount == 2 }, "daily refund check runs at 24 hours")
        expect(waitUntil { store.data(for: "entitlement-envelope") == renewed },
               "daily refresh persists the renewed perpetual lease")
        expect(controller.hasPremiumAccess, "daily renewal keeps access continuous")
        controller.stop()
        session.invalidateAndCancel()
    }

    private static func testRenewalFailuresKeepAccessUntilExactExpiry() throws {
        let key = Curve25519.Signing.PrivateKey()
        let base = Date(timeIntervalSince1970: 2_000_100_000)
        let scheduler = TestBillingScheduler(now: base)
        let initial = try signedEnvelope(
            status: .active,
            key: key,
            issuedAt: base,
            expiresAt: base.addingTimeInterval(10)
        )
        StubURLProtocol.reset { index, _ in
            index == 0
                ? StubURLProtocol.Plan(data: initial)
                : StubURLProtocol.Plan(statusCode: 503, data: Data())
        }
        let session = makeSession()
        let controller = PaddleBillingController(
            configuration: makeConfiguration(publicKey: key.publicKey),
            secureStore: makeStore(),
            session: session,
            scheduler: scheduler,
            refreshSchedule: PaddleBillingRefreshSchedule(
                renewalLeadFraction: 0.5,
                maximumRenewalLeadTime: 10,
                minimumRenewalDelay: 0.25,
                renewalRetryDelays: [1, 2],
                expiredRecoveryDelays: [2]
            )
        )
        var initialResult: Bool?

        controller.refresh { initialResult = $0 }
        expect(waitUntil { initialResult != nil }, "failure test initial lease refresh completes")

        scheduler.advance(by: 5)
        expect(waitUntil { StubURLProtocol.requestCount == 2 }, "automatic renewal attempt runs")
        expect(waitUntil { scheduler.pendingActionCount == 2 }, "first failure schedules retry plus expiry")
        expect(controller.hasPremiumAccess, "first network failure preserves unexpired access")

        scheduler.advance(by: 1)
        expect(waitUntil { StubURLProtocol.requestCount == 3 }, "first backoff retry runs")
        expect(waitUntil { scheduler.pendingActionCount == 2 }, "second failure advances backoff")
        scheduler.advance(by: 2)
        expect(waitUntil { StubURLProtocol.requestCount == 4 }, "second backoff retry runs")
        expect(waitUntil { scheduler.pendingActionCount == 2 },
               "another retry remains bounded before signed expiry")

        scheduler.advance(by: 1.9)
        expect(waitUntil { scheduler.pendingActionCount == 1 }, "retry scheduling never crosses signed expiry")
        expect(controller.hasPremiumAccess, "repeated failures do not revoke before expiry")
        scheduler.advance(by: 0.1)
        expect(!controller.hasPremiumAccess, "signed lease revokes exactly at expiry")
        expect(controller.entitlementStatus == .free, "expired failed lease returns to free status")

        controller.stop()
        session.invalidateAndCancel()
    }

    private static func testExpiredLeaseRecoversAtLowFrequency() throws {
        let key = Curve25519.Signing.PrivateKey()
        let base = Date(timeIntervalSince1970: 2_000_200_000)
        let scheduler = TestBillingScheduler(now: base)
        let initial = try signedEnvelope(
            status: .active,
            key: key,
            issuedAt: base,
            expiresAt: base.addingTimeInterval(4)
        )
        let recovered = try signedEnvelope(
            status: .active,
            key: key,
            issuedAt: base.addingTimeInterval(5),
            expiresAt: base.addingTimeInterval(105)
        )
        let renewalDeliveryGate = DispatchSemaphore(value: 0)
        StubURLProtocol.reset { index, _ in
            switch index {
            case 0: return StubURLProtocol.Plan(data: initial)
            case 1:
                return StubURLProtocol.Plan(
                    statusCode: 503,
                    data: Data(),
                    deliveryGate: renewalDeliveryGate
                )
            default: return StubURLProtocol.Plan(data: recovered)
            }
        }
        let session = makeSession()
        let controller = PaddleBillingController(
            configuration: makeConfiguration(publicKey: key.publicKey),
            secureStore: makeStore(),
            session: session,
            scheduler: scheduler,
            refreshSchedule: PaddleBillingRefreshSchedule(
                renewalLeadFraction: 0.5,
                maximumRenewalLeadTime: 4,
                minimumRenewalDelay: 2,
                renewalRetryDelays: [10],
                expiredRecoveryDelays: [1, 2]
            )
        )
        var accessChanges: [Bool] = []
        controller.onAccessChanged = { accessChanges.append($0) }
        var initialResult: Bool?

        controller.refresh { initialResult = $0 }
        expect(waitUntil { initialResult != nil }, "recovery test initial lease refresh completes")
        scheduler.advance(by: 2)
        // The renewal task is created synchronously by the test scheduler. Join that in-flight
        // refresh so virtual time cannot reach expiry before its URLSession callback is handled.
        var renewalResult: Bool?
        controller.refresh { renewalResult = $0 }
        renewalDeliveryGate.signal()
        expect(waitUntil { renewalResult != nil }, "pre-expiry renewal completes")
        expect(
            renewalResult == false,
            "failed pre-expiry renewal is reported (result=\(String(describing: renewalResult)), requests=\(StubURLProtocol.requestCount), deliveries=\(StubURLProtocol.deliveryAttemptCount))"
        )
        expect(StubURLProtocol.requestCount == 2, "pre-expiry renewal is attempted once")
        expect(waitUntil { scheduler.pendingActionCount == 1 }, "failed near-expiry renewal leaves expiry timer")

        scheduler.advance(by: 2)
        expect(!controller.hasPremiumAccess, "recovery starts only after access expires")
        expect(StubURLProtocol.requestCount == 2, "expired recovery respects its initial low-frequency delay")
        scheduler.advance(by: 1)
        expect(waitUntil { StubURLProtocol.requestCount == 3 }, "expired recovery performs a bounded retry")
        expect(waitUntil { controller.hasPremiumAccess }, "valid renewed lease restores Premium after expiry")
        expect(accessChanges == [true, false, true], "expiry and recovery each emit one access transition")

        controller.stop()
        session.invalidateAndCancel()
    }

    private static func testExpiredRecoveryStopsAtConfiguredBound() throws {
        let key = Curve25519.Signing.PrivateKey()
        let base = Date(timeIntervalSince1970: 2_000_250_000)
        let scheduler = TestBillingScheduler(now: base)
        let initial = try signedEnvelope(
            status: .active,
            key: key,
            issuedAt: base,
            expiresAt: base.addingTimeInterval(2)
        )
        StubURLProtocol.reset { index, _ in
            index == 0
                ? StubURLProtocol.Plan(data: initial)
                : StubURLProtocol.Plan(statusCode: 503, data: Data())
        }
        let session = makeSession()
        let controller = PaddleBillingController(
            configuration: makeConfiguration(publicKey: key.publicKey),
            secureStore: makeStore(),
            session: session,
            scheduler: scheduler,
            refreshSchedule: PaddleBillingRefreshSchedule(
                renewalLeadFraction: 0,
                maximumRenewalLeadTime: 0,
                minimumRenewalDelay: 0.1,
                renewalRetryDelays: [1],
                expiredRecoveryDelays: [1, 2]
            )
        )
        var initialResult: Bool?

        controller.refresh { initialResult = $0 }
        expect(waitUntil { initialResult != nil }, "bounded recovery initial lease refresh completes")
        scheduler.advance(by: 2)
        expect(!controller.hasPremiumAccess, "bounded recovery begins from an expired lease")

        scheduler.advance(by: 1)
        expect(waitUntil { StubURLProtocol.requestCount == 2 }, "first expired recovery attempt runs")
        expect(waitUntil { scheduler.pendingActionCount == 1 }, "failed recovery schedules its next delay")
        scheduler.advance(by: 2)
        expect(waitUntil { StubURLProtocol.requestCount == 3 }, "final configured recovery attempt runs")
        expect(waitUntil { scheduler.pendingActionCount == 0 }, "recovery exhausts its finite schedule")
        scheduler.advance(by: 100)
        expect(StubURLProtocol.requestCount == 3, "expired recovery performs no unbounded requests")

        controller.stop()
        session.invalidateAndCancel()
    }

    private static func testPurchasePollAndRenewalShareSingleFlight() throws {
        let key = Curve25519.Signing.PrivateKey()
        let base = Date(timeIntervalSince1970: 2_000_300_000)
        let scheduler = TestBillingScheduler(now: base)
        let initial = try signedEnvelope(
            status: .active,
            key: key,
            issuedAt: base,
            expiresAt: base.addingTimeInterval(10)
        )
        let renewed = try signedEnvelope(
            status: .active,
            key: key,
            issuedAt: base.addingTimeInterval(5),
            expiresAt: base.addingTimeInterval(105)
        )
        StubURLProtocol.reset { index, _ in
            StubURLProtocol.Plan(delay: index == 0 ? 0 : 0.04, data: index == 0 ? initial : renewed)
        }
        let session = makeSession()
        let controller = PaddleBillingController(
            configuration: makeConfiguration(publicKey: key.publicKey),
            secureStore: makeStore(),
            session: session,
            scheduler: scheduler,
            refreshSchedule: PaddleBillingRefreshSchedule(
                renewalLeadFraction: 0.5,
                maximumRenewalLeadTime: 10,
                minimumRenewalDelay: 0.1,
                renewalRetryDelays: [1],
                expiredRecoveryDelays: [1]
            ),
            purchasePollDelays: [5]
        )
        var initialResult: Bool?

        controller.refresh { initialResult = $0 }
        expect(waitUntil { initialResult != nil }, "overlap test initial lease refresh completes")
        controller.startPurchasePolling()
        scheduler.advance(by: 5)

        expect(waitUntil { StubURLProtocol.requestCount == 2 },
               "purchase poll and renewal trigger one shared network request")
        expect(waitUntil { controller.hasPremiumAccess && scheduler.pendingActionCount == 2 },
               "shared renewal installs one new lease lifecycle")
        pumpMainRunLoop(for: 0.08)
        expect(StubURLProtocol.requestCount == 2, "overlapping triggers do not create a trailing request")

        controller.stop()
        session.invalidateAndCancel()
    }

    private static func testStopCancelsAllScheduledBillingWork() throws {
        let key = Curve25519.Signing.PrivateKey()
        let base = Date(timeIntervalSince1970: 2_000_400_000)
        let scheduler = TestBillingScheduler(now: base)
        let active = try signedEnvelope(
            status: .active,
            key: key,
            issuedAt: base,
            expiresAt: base.addingTimeInterval(10)
        )
        StubURLProtocol.reset { _, _ in StubURLProtocol.Plan(data: active) }
        let session = makeSession()
        let controller = PaddleBillingController(
            configuration: makeConfiguration(publicKey: key.publicKey),
            secureStore: makeStore(),
            session: session,
            scheduler: scheduler,
            refreshSchedule: PaddleBillingRefreshSchedule(
                renewalLeadFraction: 0.5,
                maximumRenewalLeadTime: 10,
                minimumRenewalDelay: 0.1,
                renewalRetryDelays: [1],
                expiredRecoveryDelays: [1]
            ),
            purchasePollDelays: [3]
        )
        var initialResult: Bool?
        var pollingChanges: [Bool] = []
        controller.onPurchasePollingChanged = { pollingChanges.append($0) }

        controller.refresh { initialResult = $0 }
        expect(waitUntil { initialResult != nil }, "stop test initial lease refresh completes")
        controller.startPurchasePolling()
        expect(controller.isPurchasePolling && pollingChanges == [true],
               "purchase polling publishes one start transition")
        expect(scheduler.pendingActionCount == 3, "renewal, expiry, and purchase timers are scheduled")

        controller.stop()
        expect(!controller.isPurchasePolling && pollingChanges == [true, false],
               "stop publishes one polling end transition")
        expect(scheduler.pendingActionCount == 0, "stop cancels every scheduled billing timer")
        scheduler.advance(by: 100)
        pumpMainRunLoop(for: 0.05)
        expect(StubURLProtocol.requestCount == 1, "late canceled timers cannot start network work")
        expect(controller.hasPremiumAccess, "stop does not invent a billing revocation")

        session.invalidateAndCancel()
    }

    private static func testDefaultPurchasePollingCoversDelayedWebhooksButIsBounded() {
        let delays = PaddleBillingController.defaultPurchasePollDelays
        expect(delays.reduce(0, +) >= 12 * 60,
               "default purchase polling covers at least twelve minutes")
        expect(delays.count <= 12, "default purchase polling remains request-count bounded")
    }

    private static func testCancelPurchasePollingIsImmediateIdempotentAndRestartable() {
        StubURLProtocol.reset { _, _ in StubURLProtocol.Plan(data: Data()) }
        let key = Curve25519.Signing.PrivateKey()
        let scheduler = TestBillingScheduler(now: Date(timeIntervalSince1970: 2_000_500_000))
        let session = makeSession()
        let controller = PaddleBillingController(
            configuration: makeConfiguration(publicKey: key.publicKey),
            secureStore: makeStore(),
            session: session,
            scheduler: scheduler,
            purchasePollDelays: [5]
        )
        var pollingChanges: [Bool] = []
        controller.onPurchasePollingChanged = { pollingChanges.append($0) }

        controller.startPurchasePolling()
        expect(controller.isPurchasePolling && scheduler.pendingActionCount == 1,
               "purchase polling starts with one bounded timer")
        controller.cancelPurchasePolling()
        controller.cancelPurchasePolling()
        expect(!controller.isPurchasePolling && pollingChanges == [true, false],
               "explicit polling cancellation is immediate and idempotent")
        expect(scheduler.pendingActionCount == 0, "explicit cancellation removes the pending timer")
        scheduler.advance(by: 100)
        expect(StubURLProtocol.requestCount == 0, "canceled purchase timer cannot start a request")

        controller.startPurchasePolling()
        expect(controller.isPurchasePolling && pollingChanges == [true, false, true],
               "purchase polling can restart after explicit cancellation")
        controller.stop()
        expect(!controller.isPurchasePolling && pollingChanges == [true, false, true, false],
               "stop ends a restarted poll without duplicate state transitions")
        expect(scheduler.pendingActionCount == 0, "stop cancels the restarted purchase timer")
        session.invalidateAndCancel()
    }

    private static func testCancelPurchasePollingWinsReentrancyAndLateRefreshRace() throws {
        let key = Curve25519.Signing.PrivateKey()
        let free = try signedEnvelope(status: .free, key: key)
        let deliveryGate = DispatchSemaphore(value: 0)
        StubURLProtocol.reset { _, _ in
            StubURLProtocol.Plan(data: free, deliveryGate: deliveryGate)
        }
        let scheduler = TestBillingScheduler(now: Date(timeIntervalSince1970: 2_000_600_000))
        let session = makeSession()
        let controller = PaddleBillingController(
            configuration: makeConfiguration(publicKey: key.publicKey),
            secureStore: makeStore(),
            session: session,
            scheduler: scheduler,
            purchasePollDelays: [1, 1]
        )
        var pollingChanges: [Bool] = []
        controller.onPurchasePollingChanged = { pollingChanges.append($0) }

        controller.startPurchasePolling()
        scheduler.advance(by: 1)
        expect(waitUntil { StubURLProtocol.requestCount == 1 }, "purchase poll refresh starts")
        controller.cancelPurchasePolling()
        expect(!controller.isPurchasePolling && pollingChanges == [true, false],
               "explicit cancellation wins while a poll refresh is in flight")
        deliveryGate.signal()
        expect(waitUntil { StubURLProtocol.deliveryAttemptCount == 1 }, "late poll response is delivered")
        pumpMainRunLoop(for: 0.05)
        scheduler.advance(by: 10)
        expect(StubURLProtocol.requestCount == 1,
               "late refresh completion cannot schedule another poll after cancellation")
        expect(!controller.isPurchasePolling && pollingChanges == [true, false],
               "late refresh completion cannot reactivate or duplicate polling state")

        var canceledReentrantly = false
        controller.onPurchasePollingChanged = { polling in
            pollingChanges.append(polling)
            if polling && !canceledReentrantly {
                canceledReentrantly = true
                controller.cancelPurchasePolling()
            }
        }
        controller.startPurchasePolling()
        expect(!controller.isPurchasePolling,
               "cancellation from the start-state callback wins before a timer is scheduled")
        expect(scheduler.pendingActionCount == 0,
               "reentrant cancellation leaves no hidden purchase timer")
        expect(pollingChanges == [true, false, true, false],
               "reentrant cancellation emits one balanced transition pair")

        controller.stop()
        session.invalidateAndCancel()
    }

    private static func testPurchasePollingStopsAfterBoundedFreeResponses() throws {
        let key = Curve25519.Signing.PrivateKey()
        let free = try signedEnvelope(status: .free, key: key)
        StubURLProtocol.reset { _, _ in StubURLProtocol.Plan(data: free) }
        let session = makeSession()
        let controller = PaddleBillingController(
            configuration: makeConfiguration(publicKey: key.publicKey),
            secureStore: makeStore(),
            session: session,
            purchasePollDelays: [0.01, 0.01, 0.01]
        )
        var pollingChanges: [Bool] = []
        controller.onPurchasePollingChanged = { pollingChanges.append($0) }

        controller.startPurchasePolling()
        expect(controller.isPurchasePolling && pollingChanges == [true],
               "bounded polling publishes one start transition")
        expect(waitUntil { StubURLProtocol.requestCount == 3 }, "purchase polling reaches configured bound")
        pumpMainRunLoop(for: 0.08)
        expect(StubURLProtocol.requestCount == 3, "free purchase polling performs no request beyond its bound")
        expect(!controller.hasPremiumAccess, "bounded free polling does not unlock Premium")
        expect(!controller.isPurchasePolling && pollingChanges == [true, false],
               "bounded polling exhaustion publishes one end transition")
        controller.stop()
        session.invalidateAndCancel()
    }

    private static func testPurchasePollingStopsWhenWebhookBecomesActive() throws {
        let key = Curve25519.Signing.PrivateKey()
        let free = try signedEnvelope(status: .free, key: key)
        let active = try signedEnvelope(status: .active, key: key)
        StubURLProtocol.reset { index, _ in
            StubURLProtocol.Plan(data: index == 0 ? free : active)
        }
        let session = makeSession()
        let controller = PaddleBillingController(
            configuration: makeConfiguration(publicKey: key.publicKey),
            secureStore: makeStore(),
            session: session,
            purchasePollDelays: [0.01, 0.01, 0.01, 0.01]
        )
        var pollingChanges: [Bool] = []
        controller.onPurchasePollingChanged = { pollingChanges.append($0) }

        controller.startPurchasePolling()
        controller.startPurchasePolling()
        expect(controller.isPurchasePolling && pollingChanges == [true],
               "polling restart does not duplicate the active transition")
        expect(waitUntil { controller.hasPremiumAccess }, "delayed webhook transitions free to active")
        pumpMainRunLoop(for: 0.08)
        expect(StubURLProtocol.requestCount == 2, "active webhook stops further purchase polling")
        expect(controller.entitlementStatus == .active, "active webhook status is retained")
        expect(!controller.isPurchasePolling && pollingChanges == [true, false],
               "signed grant publishes one polling end transition")
        controller.stop()
        session.invalidateAndCancel()
    }

    private static func testRestoreSuccessUsesHashedCurrentCredentialAndSignedRefresh() throws {
        let key = Curve25519.Signing.PrivateKey()
        let active = try signedEnvelope(status: .active, key: key)
        let restored = #"{"ok":true,"result":"restored"}"#.data(using: .utf8)!
        let restoreGate = DispatchSemaphore(value: 0)
        StubURLProtocol.reset { index, _ in
            index == 0
                ? StubURLProtocol.Plan(data: restored, deliveryGate: restoreGate)
                : StubURLProtocol.Plan(data: active)
        }
        let session = makeSession()
        let store = makeStore()
        let controller = PaddleBillingController(
            configuration: makeConfiguration(publicKey: key.publicKey),
            secureStore: store,
            session: session
        )
        let oldSecret = String(repeating: "A", count: 43)
        var result: Bool?

        controller.restorePurchase(using: "DOUT1.\(oldSecret)") { result = $0 }
        expect(waitUntil { StubURLProtocol.requestCount == 1 }, "restore request starts")
        let attemptData = store.data(for: "restore-attempt") ?? Data()
        let attempt = try JSONSerialization.jsonObject(with: attemptData) as? [String: Any]
        let requestID = attempt?["request_id"] as? String ?? ""
        restoreGate.signal()
        expect(waitUntil { result != nil }, "restore and signed entitlement refresh complete")
        expect(result == true && controller.hasPremiumAccess,
               "restore succeeds only after a signed active lease")
        expect(StubURLProtocol.requests.count == 2, "restore performs one rebind and one entitlement request")
        expect(store.data(for: "restore-attempt") == nil,
               "signed active restore removes its completed idempotency record")

        let restoreRequest = StubURLProtocol.requests[0]
        let bindingSecret = String(data: store.data(for: "binding-secret") ?? Data(), encoding: .utf8)!
        let inspectableRequest = PaddleBillingController.makeRestoreRequest(
            url: restoreRequest.url!,
            installationID: installationID,
            sourceSecret: oldSecret,
            requestID: requestID,
            currentBindingSecret: bindingSecret
        )!
        let body = inspectableRequest.httpBody ?? Data()
        let object = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        expect(restoreRequest.url?.path == "/v1/restore", "restore uses the dedicated endpoint")
        expect(restoreRequest.httpMethod == "POST", "restore uses POST")
        expect(restoreRequest.value(forHTTPHeaderField: "Authorization") == "Bearer \(oldSecret)",
               "old recovery secret is carried only as bearer authorization")
        expect(restoreRequest.value(forHTTPHeaderField: "X-DiskOUT-Install-ID") == installationID,
               "restore binds the current installation in a header")
        expect(object?["new_credential_sha256"] as? String == sha256Hex(Data(bindingSecret.utf8)),
               "restore sends only the current credential hash")
        expect((object?["request_id"] as? String).flatMap(UUID.init(uuidString:)) != nil,
               "restore persists a UUID request ID")
        expect(!String(data: body, encoding: .utf8)!.contains(bindingSecret),
               "restore body never contains the current raw binding secret")
        expect(!String(data: body, encoding: .utf8)!.contains(oldSecret),
               "restore body never contains the old raw recovery secret")

        let entitlementRequest = StubURLProtocol.requests[1]
        expect(entitlementRequest.url?.path == "/v1/entitlement",
               "restore acknowledgement is followed by a separate entitlement request")
        expect(entitlementRequest.value(forHTTPHeaderField: "Authorization") == "Bearer \(bindingSecret)",
               "post-restore entitlement uses the current binding credential")

        StubURLProtocol.reset(preservingSession: true) { _, _ in
            StubURLProtocol.Plan(statusCode: 503, data: Data("{}".utf8))
        }
        var laterResult: Bool?
        controller.restorePurchase(using: "DOUT1.\(oldSecret)") { laterResult = $0 }
        expect(waitUntil { laterResult != nil }, "later transfer attempt completes")
        let laterAttempt = try JSONSerialization.jsonObject(
            with: store.data(for: "restore-attempt") ?? Data()
        ) as? [String: Any]
        expect(laterAttempt?["request_id"] as? String != requestID,
               "a later transfer receives a fresh request ID after the prior signed success")
        controller.stop()
        session.invalidateAndCancel()
    }

    private static func testRestoreFailureAndIdempotentRetryReuseRequestID() throws {
        let key = Curve25519.Signing.PrivateKey()
        let active = try signedEnvelope(status: .active, key: key)
        let alreadyRestored = #"{"ok":true,"result":"already_restored"}"#.data(using: .utf8)!
        let retryGate = DispatchSemaphore(value: 0)
        StubURLProtocol.reset { index, _ in
            switch index {
            case 0: return StubURLProtocol.Plan(statusCode: 503, data: Data("{}".utf8))
            case 1: return StubURLProtocol.Plan(data: alreadyRestored, deliveryGate: retryGate)
            default: return StubURLProtocol.Plan(data: active)
            }
        }
        let session = makeSession()
        let store = makeStore()
        let controller = PaddleBillingController(
            configuration: makeConfiguration(publicKey: key.publicKey),
            secureStore: store,
            session: session
        )
        let oldSecret = String(repeating: "B", count: 43)
        var invalidResult: Bool?
        controller.restorePurchase(using: " DOUT1.\(oldSecret)") { invalidResult = $0 }
        expect(invalidResult == false, "restore input rejects surrounding whitespace")
        expect(StubURLProtocol.requestCount == 0, "malformed recovery code performs no network request")

        var firstResult: Bool?
        controller.restorePurchase(using: "DOUT1.\(oldSecret)") { firstResult = $0 }
        expect(waitUntil { firstResult != nil }, "failed restore attempt completes")
        expect(firstResult == false && !controller.hasPremiumAccess,
               "HTTP restore failure cannot unlock Premium")
        let firstAttempt = try JSONSerialization.jsonObject(
            with: store.data(for: "restore-attempt") ?? Data()
        ) as? [String: Any]

        var retryResult: Bool?
        controller.restorePurchase(using: "DOUT1.\(oldSecret)") { retryResult = $0 }
        expect(waitUntil { StubURLProtocol.requestCount == 2 }, "idempotent restore retry starts")
        let retryAttempt = try JSONSerialization.jsonObject(
            with: store.data(for: "restore-attempt") ?? Data()
        ) as? [String: Any]
        retryGate.signal()
        expect(waitUntil { retryResult != nil }, "idempotent restore retry completes")
        expect(retryResult == true && controller.hasPremiumAccess,
               "already-restored acknowledgement still requires and receives a signed lease")

        let restoreRequests = StubURLProtocol.requests.filter { $0.url?.path == "/v1/restore" }
        expect(restoreRequests.count == 2, "retry performs exactly two restore requests")
        expect(firstAttempt?["request_id"] as? String == retryAttempt?["request_id"] as? String,
               "same recovery code reuses its persisted idempotency request ID")
        expect(firstAttempt?["source_secret_hash"] as? String == retryAttempt?["source_secret_hash"] as? String,
               "idempotent retry remains bound to the same recovery credential")
        expect(store.data(for: "restore-attempt") == nil,
               "successful retry removes the completed idempotency record")
        controller.stop()
        session.invalidateAndCancel()
    }

    private static func testRestoreAcknowledgementRefreshFailureRetainsRequestID() throws {
        let key = Curve25519.Signing.PrivateKey()
        let active = try signedEnvelope(status: .active, key: key)
        let restored = #"{"ok":true,"result":"restored"}"#.data(using: .utf8)!
        let alreadyRestored = #"{"ok":true,"result":"already_restored"}"#.data(using: .utf8)!
        let retryGate = DispatchSemaphore(value: 0)
        StubURLProtocol.reset { index, _ in
            switch index {
            case 0: return StubURLProtocol.Plan(data: restored)
            case 1: return StubURLProtocol.Plan(statusCode: 503, data: Data())
            case 2: return StubURLProtocol.Plan(data: alreadyRestored, deliveryGate: retryGate)
            default: return StubURLProtocol.Plan(data: active)
            }
        }
        let session = makeSession()
        let store = makeStore()
        let controller = PaddleBillingController(
            configuration: makeConfiguration(publicKey: key.publicKey),
            secureStore: store,
            session: session
        )
        let oldSecret = String(repeating: "R", count: 43)

        var firstResult: Bool?
        controller.restorePurchase(using: "DOUT1.\(oldSecret)") { firstResult = $0 }
        expect(waitUntil { firstResult != nil }, "acknowledged restore with failed refresh completes")
        expect(firstResult == false && !controller.hasPremiumAccess,
               "restore acknowledgement without a signed active lease remains locked")
        let firstAttempt = try JSONSerialization.jsonObject(
            with: store.data(for: "restore-attempt") ?? Data()
        ) as? [String: Any]

        var retryResult: Bool?
        controller.restorePurchase(using: "DOUT1.\(oldSecret)") { retryResult = $0 }
        expect(waitUntil { StubURLProtocol.requestCount == 3 }, "retry after failed entitlement refresh starts")
        let retryAttempt = try JSONSerialization.jsonObject(
            with: store.data(for: "restore-attempt") ?? Data()
        ) as? [String: Any]
        expect(firstAttempt?["request_id"] as? String == retryAttempt?["request_id"] as? String,
               "acknowledgement followed by refresh failure retains the idempotency request ID")
        retryGate.signal()
        expect(waitUntil { retryResult != nil }, "retained-ID restore retry completes")
        expect(retryResult == true && controller.hasPremiumAccess,
               "retry still requires a separately signed active lease")
        expect(store.data(for: "restore-attempt") == nil,
               "successful signed retry removes the retained idempotency record")

        controller.stop()
        session.invalidateAndCancel()
    }

    private static func testRestoreAttemptCleanupFailurePreservesSignedSuccess() throws {
        let key = Curve25519.Signing.PrivateKey()
        let active = try signedEnvelope(status: .active, key: key)
        let restored = #"{"ok":true,"result":"restored"}"#.data(using: .utf8)!
        let restoreGate = DispatchSemaphore(value: 0)
        StubURLProtocol.reset { index, _ in
            index == 0
                ? StubURLProtocol.Plan(data: restored, deliveryGate: restoreGate)
                : StubURLProtocol.Plan(data: active)
        }
        let session = makeSession()
        let store = MemoryBillingSecureStore(
            values: ["installation-id": Data(installationID.utf8)],
            failingRemovalAccounts: ["restore-attempt"]
        )
        let controller = PaddleBillingController(
            configuration: makeConfiguration(publicKey: key.publicKey),
            secureStore: store,
            session: session
        )
        var result: Bool?

        controller.restorePurchase(using: "DOUT1.\(String(repeating: "S", count: 43))") {
            result = $0
        }
        expect(waitUntil { StubURLProtocol.requestCount == 1 }, "cleanup-failure restore starts")
        let appliedAttempt = try JSONSerialization.jsonObject(
            with: store.data(for: "restore-attempt") ?? Data()
        ) as? [String: Any]
        restoreGate.signal()
        expect(waitUntil { result != nil }, "restore with cleanup failure completes")
        expect(result == true && controller.hasPremiumAccess,
               "Keychain cleanup failure cannot revoke a verified signed active lease")
        expect(store.removedAccounts.contains("restore-attempt"),
               "successful restore attempts best-effort idempotency record cleanup")
        expect(store.data(for: "restore-attempt") != nil,
               "failed cleanup leaves a fallback idempotency record")
        let replacementAttempt = try JSONSerialization.jsonObject(
            with: store.data(for: "restore-attempt") ?? Data()
        ) as? [String: Any]
        expect(replacementAttempt?["request_id"] as? String != appliedAttempt?["request_id"] as? String,
               "cleanup failure rotates away from the already-applied request ID")
        expect((replacementAttempt?["request_id"] as? String).flatMap(UUID.init(uuidString:)) != nil,
               "cleanup fallback remains a valid fresh idempotency request ID")

        controller.stop()
        session.invalidateAndCancel()
    }

    private static func testRestoreTargetChangeRotatesRequestID() throws {
        let key = Curve25519.Signing.PrivateKey()
        let oldRecoverySecret = String(repeating: "J", count: 43)
        let firstBinding = String(repeating: "K", count: 43)
        let secondBinding = String(repeating: "M", count: 43)
        let store = MemoryBillingSecureStore(values: [
            "installation-id": Data(installationID.utf8),
            "binding-secret": Data(firstBinding.utf8),
        ])
        StubURLProtocol.reset { _, _ in StubURLProtocol.Plan(statusCode: 503, data: Data("{}".utf8)) }
        let firstSession = makeSession()
        let firstController = PaddleBillingController(
            configuration: makeConfiguration(publicKey: key.publicKey),
            secureStore: store,
            session: firstSession
        )
        var firstResult: Bool?
        firstController.restorePurchase(using: "DOUT1.\(oldRecoverySecret)") { firstResult = $0 }
        expect(waitUntil { firstResult != nil }, "first target restore attempt completes")
        let firstAttempt = try JSONSerialization.jsonObject(
            with: store.data(for: "restore-attempt") ?? Data()
        ) as? [String: Any]
        firstController.stop()
        firstSession.invalidateAndCancel()

        expect(store.set(Data(secondBinding.utf8), for: "binding-secret"),
               "test rotates the current binding credential")
        StubURLProtocol.reset { _, _ in StubURLProtocol.Plan(statusCode: 503, data: Data("{}".utf8)) }
        let secondSession = makeSession()
        let secondController = PaddleBillingController(
            configuration: makeConfiguration(publicKey: key.publicKey),
            secureStore: store,
            session: secondSession
        )
        var secondResult: Bool?
        secondController.restorePurchase(using: "DOUT1.\(oldRecoverySecret)") { secondResult = $0 }
        expect(waitUntil { secondResult != nil }, "changed target restore attempt completes")
        let secondAttempt = try JSONSerialization.jsonObject(
            with: store.data(for: "restore-attempt") ?? Data()
        ) as? [String: Any]

        expect(firstAttempt?["request_id"] as? String != secondAttempt?["request_id"] as? String,
               "changed restore target receives a new idempotency request ID")
        expect(firstAttempt?["target_credential_hash"] as? String !=
               secondAttempt?["target_credential_hash"] as? String,
               "persisted restore attempt binds its exact current credential hash")
        secondController.stop()
        secondSession.invalidateAndCancel()
    }

    private static func testRestoreForcesFreshEntitlementAfterStaleRefresh() throws {
        let key = Curve25519.Signing.PrivateKey()
        let staleFree = try signedEnvelope(status: .free, key: key)
        let active = try signedEnvelope(status: .active, key: key)
        let restored = #"{"ok":true,"result":"restored"}"#.data(using: .utf8)!
        let staleGate = DispatchSemaphore(value: 0)
        StubURLProtocol.reset { index, _ in
            switch index {
            case 0: return StubURLProtocol.Plan(data: staleFree, deliveryGate: staleGate)
            case 1: return StubURLProtocol.Plan(data: restored)
            default: return StubURLProtocol.Plan(data: active)
            }
        }
        let session = makeSession()
        let controller = PaddleBillingController(
            configuration: makeConfiguration(publicKey: key.publicKey),
            secureStore: makeStore(),
            session: session
        )
        var oldRefreshResult: Bool?
        controller.refresh { oldRefreshResult = $0 }
        expect(waitUntil { StubURLProtocol.requestCount == 1 }, "pre-restore entitlement request starts")

        var restoreResult: Bool?
        controller.restorePurchase(using: "DOUT1.\(String(repeating: "C", count: 43))") {
            restoreResult = $0
        }
        expect(waitUntil { restoreResult != nil }, "restore starts a fresh post-rebind entitlement request")
        expect(oldRefreshResult == false, "restore cancels the pre-rebind refresh completion")
        expect(restoreResult == true && controller.hasPremiumAccess,
               "fresh post-restore signed lease grants access")
        expect(StubURLProtocol.requests.filter { $0.url?.path == "/v1/entitlement" }.count == 2,
               "restore does not join the stale pre-rebind entitlement request")

        staleGate.signal()
        pumpMainRunLoop(for: 0.05)
        expect(controller.hasPremiumAccess, "late stale signed-free response cannot revoke restored access")
        controller.stop()
        session.invalidateAndCancel()
    }

    private static func testNewRestoreCancelsOlderRestoreGeneration() throws {
        let key = Curve25519.Signing.PrivateKey()
        let active = try signedEnvelope(status: .active, key: key)
        let restored = #"{"ok":true,"result":"restored"}"#.data(using: .utf8)!
        let oldGate = DispatchSemaphore(value: 0)
        StubURLProtocol.reset { index, _ in
            switch index {
            case 0: return StubURLProtocol.Plan(data: restored, deliveryGate: oldGate)
            case 1: return StubURLProtocol.Plan(data: restored)
            default: return StubURLProtocol.Plan(data: active)
            }
        }
        let session = makeSession()
        let controller = PaddleBillingController(
            configuration: makeConfiguration(publicKey: key.publicKey),
            secureStore: makeStore(),
            session: session
        )
        var oldResults: [Bool] = []
        controller.restorePurchase(using: "DOUT1.\(String(repeating: "E", count: 43))") {
            oldResults.append($0)
        }
        expect(waitUntil { StubURLProtocol.requestCount == 1 }, "older restore request starts")

        var newResult: Bool?
        controller.restorePurchase(using: "DOUT1.\(String(repeating: "F", count: 43))") {
            newResult = $0
        }
        expect(oldResults == [false], "new restore completes the older lifecycle once with failure")
        expect(waitUntil { newResult != nil }, "new restore generation completes")
        expect(newResult == true && controller.hasPremiumAccess,
               "new restore generation owns the signed entitlement result")

        oldGate.signal()
        pumpMainRunLoop(for: 0.05)
        expect(oldResults == [false], "late older restore acknowledgement cannot complete again")
        expect(controller.hasPremiumAccess, "late older restore acknowledgement cannot overwrite new access")
        controller.stop()
        session.invalidateAndCancel()
    }

    private static func testStopIgnoresDelayedRestoreAcknowledgement() {
        let key = Curve25519.Signing.PrivateKey()
        let restored = #"{"ok":true,"result":"restored"}"#.data(using: .utf8)!
        let deliveryGate = DispatchSemaphore(value: 0)
        StubURLProtocol.reset { _, _ in StubURLProtocol.Plan(data: restored, deliveryGate: deliveryGate) }
        let session = makeSession()
        let controller = PaddleBillingController(
            configuration: makeConfiguration(publicKey: key.publicKey),
            secureStore: makeStore(),
            session: session
        )
        var results: [Bool] = []

        controller.restorePurchase(using: "DOUT1.\(String(repeating: "D", count: 43))") {
            results.append($0)
        }
        expect(waitUntil { StubURLProtocol.requestCount == 1 }, "delayed restore request starts")
        controller.stop()
        expect(results == [false], "stop completes restore exactly once with failure")
        deliveryGate.signal()
        expect(waitUntil { StubURLProtocol.deliveryAttemptCount == 1 }, "delayed restore transport reaches delivery")
        pumpMainRunLoop(for: 0.05)
        expect(results == [false], "late restore acknowledgement cannot complete twice")
        expect(!controller.hasPremiumAccess, "late restore acknowledgement cannot grant access")
        expect(StubURLProtocol.requestCount == 1, "late restore acknowledgement cannot start entitlement refresh")
        session.invalidateAndCancel()
    }

    private static func testPurchaseDetailsUsesPostAndValidatesPaddleHost() throws {
        let key = Curve25519.Signing.PrivateKey()
        let active = try signedEnvelope(status: .active, key: key)
        StubURLProtocol.reset { _, _ in StubURLProtocol.Plan(data: active) }
        let session = makeSession()
        let store = makeStore()
        let controller = PaddleBillingController(
            configuration: makeConfiguration(publicKey: key.publicKey),
            secureStore: store,
            session: session
        )
        var refreshResult: Bool?
        controller.refresh { refreshResult = $0 }
        expect(waitUntil { refreshResult != nil }, "active lease is ready before portal request")
        expect(controller.canOpenPurchaseDetails, "active lease enables one-time purchase details")
        let bindingSecret = String(data: store.data(for: "binding-secret") ?? Data(), encoding: .utf8)
        expect(bindingSecret?.count == 43, "binding credential is a persisted 256-bit base64url value")
        let checkoutURL = controller.checkoutURL
        let fragmentItems = URLComponents(string: "?\(checkoutURL?.fragment ?? "")")?.queryItems ?? []
        let fragmentValues = Dictionary(uniqueKeysWithValues: fragmentItems.map { ($0.name, $0.value ?? "") })
        expect(checkoutURL?.query == nil, "checkout binding values never use the request query")
        expect(fragmentValues["install_id"] == installationID,
               "checkout carries the installation ID only in the fragment")
        expect(fragmentValues["binding_secret"] == bindingSecret,
               "checkout carries the raw binding credential only in the fragment")
        expect(controller.recoveryCode == "DOUT1.\(bindingSecret ?? "")",
               "recovery code uses the versioned strict format")

        let validPortal = #"{"url":"https://customer-portal.paddle.com/session/test"}"#.data(using: .utf8)!
        StubURLProtocol.reset(preservingSession: true) { _, _ in
            StubURLProtocol.Plan(data: validPortal)
        }
        var portalDidComplete = false
        var portalURL: URL?
        controller.requestPurchaseDetailsURL {
            portalURL = $0
            portalDidComplete = true
        }

        expect(waitUntil { portalDidComplete }, "portal session request completes")
        expect(portalURL?.host == "customer-portal.paddle.com", "validated Paddle portal URL is returned")
        expect(StubURLProtocol.requests.count == 1, "portal uses one request")
        let request = StubURLProtocol.requests[0]
        expect(request.httpMethod == "POST", "portal session uses POST")
        expect(request.url?.path == "/v1/portal", "installation ID is absent from the portal URL path")
        expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(bindingSecret ?? "")",
               "separate binding credential is sent as bearer authorization")
        expect(request.value(forHTTPHeaderField: "X-DiskOUT-Install-ID") == installationID,
               "installation ID is sent separately from the binding credential")

        let invalidPortal = #"{"url":"https://portal.attacker.test/session"}"#.data(using: .utf8)!
        StubURLProtocol.reset(preservingSession: true) { _, _ in
            StubURLProtocol.Plan(data: invalidPortal)
        }
        portalDidComplete = false
        portalURL = URL(string: "https://placeholder.test")
        controller.requestPurchaseDetailsURL {
            portalURL = $0
            portalDidComplete = true
        }
        expect(waitUntil { portalDidComplete }, "invalid-host portal response completes")
        expect(portalURL == nil, "non-Paddle portal host is rejected")

        controller.stop()
        session.invalidateAndCancel()
    }

    private static func testStopIgnoresDelayedRefresh() throws {
        let key = Curve25519.Signing.PrivateKey()
        let active = try signedEnvelope(status: .active, key: key)
        StubURLProtocol.reset { _, _ in StubURLProtocol.Plan(delay: 0.15, data: active) }
        let session = makeSession()
        let controller = PaddleBillingController(
            configuration: makeConfiguration(publicKey: key.publicKey),
            secureStore: makeStore(),
            session: session
        )
        var completionResults: [Bool] = []

        controller.refresh { completionResults.append($0) }
        expect(waitUntil { StubURLProtocol.requestCount == 1 }, "delayed refresh starts")
        controller.stop()

        expect(completionResults == [false], "stop completes pending refresh once with failure")
        expect(waitUntil { StubURLProtocol.deliveryAttemptCount == 1 }, "delayed transport reaches its response time")
        pumpMainRunLoop(for: 0.05)
        expect(completionResults == [false], "late canceled result cannot complete callbacks twice")
        expect(!controller.hasPremiumAccess, "late canceled result cannot grant Premium")
        session.invalidateAndCancel()
    }

    static func main() throws {
        precondition(Thread.isMainThread)
        testMissingConfigurationFailsClosedWithoutNetwork()
        testConfigurationRejectsMalformedPublicSettingsAndPreservesBasePath()
        testBindingCredentialPersistenceFailsClosed()
        testInstallationIDPersistenceFailsClosed()
        testLegacyPortalCredentialCreatesFreshBindingWithoutDeletingLegacy()
        try testMissingInstallationRotatesSurvivingBindingSecret()
        try testValidSignedActiveLeaseGrants()
        try testConcurrentRefreshIsSingleFlight()
        try testTamperedRefreshPreservesCachedLease()
        try testSignedWrongBindingPreservesCachedLease()
        try testSignedInvalidV2PayloadsFailClosed()
        try testSignedRefundedLeaseRevokes()
        try testSignedChargebackLeaseRevokes()
        try testDenialPersistenceFailureRemovesStaleGrant()
        try testShortLeaseAutoExpires()
        try testAutomaticRenewalExtendsActiveLease()
        try testPerpetualLeaseRefreshesEveryTwentyFourHours()
        try testRenewalFailuresKeepAccessUntilExactExpiry()
        try testExpiredLeaseRecoversAtLowFrequency()
        try testExpiredRecoveryStopsAtConfiguredBound()
        try testPurchasePollAndRenewalShareSingleFlight()
        try testStopCancelsAllScheduledBillingWork()
        testDefaultPurchasePollingCoversDelayedWebhooksButIsBounded()
        testCancelPurchasePollingIsImmediateIdempotentAndRestartable()
        try testCancelPurchasePollingWinsReentrancyAndLateRefreshRace()
        try testPurchasePollingStopsAfterBoundedFreeResponses()
        try testPurchasePollingStopsWhenWebhookBecomesActive()
        try testRestoreSuccessUsesHashedCurrentCredentialAndSignedRefresh()
        try testRestoreFailureAndIdempotentRetryReuseRequestID()
        try testRestoreAcknowledgementRefreshFailureRetainsRequestID()
        try testRestoreAttemptCleanupFailurePreservesSignedSuccess()
        try testRestoreTargetChangeRotatesRequestID()
        try testRestoreForcesFreshEntitlementAfterStaleRefresh()
        try testNewRestoreCancelsOlderRestoreGeneration()
        testStopIgnoresDelayedRestoreAcknowledgement()
        try testPurchaseDetailsUsesPostAndValidatesPaddleHost()
        try testStopIgnoresDelayedRefresh()
        print("PaddleBillingControllerTests: PASS")
    }
}
