import CryptoKit
import Foundation
import os
import Security

private let billingLog = Logger(subsystem: "com.yongza.ejectdrives", category: "billing")

struct PaddleBillingConfiguration {
    static let oneTimePriceUSD = "4.99"

    let baseURL: URL?
    let oneTimePriceID: String
    let entitlementPublicKey: Data?

    init(infoDictionary: [String: Any] = Bundle.main.infoDictionary ?? [:]) {
        oneTimePriceID = (infoDictionary["DiskOUTPaddleOneTimePriceID"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        let baseString = (infoDictionary["DiskOUTBillingBaseURL"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if let candidate = URL(string: baseString), Self.isAllowedBillingURL(candidate) {
            baseURL = candidate
        } else {
            baseURL = nil
        }

        let publicKeyString = (infoDictionary["DiskOUTEntitlementPublicKey"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        entitlementPublicKey = Data(base64Encoded: publicKeyString)
    }

    var isConfigured: Bool {
        baseURL != nil && Self.isValidPaddlePriceID(oneTimePriceID) && entitlementPublicKey?.count == 32
    }

    func checkoutURL(installationID: String, bindingSecret: String) -> URL? {
        guard let url = endpoint(path: "/checkout"),
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        // URL fragments are not sent in HTTP requests or Worker request logs. Checkout JavaScript
        // removes both binding values from browser history before passing them to Paddle custom data.
        var fragment = URLComponents()
        fragment.queryItems = [
            URLQueryItem(name: "install_id", value: installationID),
            URLQueryItem(name: "binding_secret", value: bindingSecret),
        ]
        components.percentEncodedFragment = fragment.percentEncodedQuery
        return components.url
    }

    func entitlementURL() -> URL? {
        endpoint(path: "/v1/entitlement")
    }

    func restoreURL() -> URL? {
        endpoint(path: "/v1/restore")
    }

    func portalURL() -> URL? {
        endpoint(path: "/v1/portal")
    }

    private func endpoint(path: String) -> URL? {
        guard isConfigured, let baseURL,
              var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else { return nil }
        let basePath = components.path.hasSuffix("/") ? String(components.path.dropLast()) : components.path
        components.path = basePath + path
        return components.url
    }

    private static func isAllowedBillingURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(),
              let host = url.host?.lowercased(),
              url.user == nil,
              url.password == nil,
              url.query == nil,
              url.fragment == nil else { return false }
        if scheme == "https" { return true }
        return scheme == "http" && (host == "localhost" || host == "127.0.0.1" || host == "::1")
    }

    private static func isValidPaddlePriceID(_ value: String) -> Bool {
        let prefix = "pri_"
        guard value.hasPrefix(prefix), value.utf8.count == prefix.utf8.count + 26 else { return false }
        return value.utf8.dropFirst(prefix.utf8.count).allSatisfy { byte in
            (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(byte) ||
                (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
        }
    }
}

private struct SignedPremiumEntitlement: Codable {
    let payload: String
    let signature: String
}

private struct PaddlePortalSessionResponse: Codable {
    let url: String
}

private struct PaddleRestoreRequest: Codable {
    let requestID: String
    let newCredentialSHA256: String

    enum CodingKeys: String, CodingKey {
        case requestID = "request_id"
        case newCredentialSHA256 = "new_credential_sha256"
    }
}

private struct PaddleRestoreResponse: Codable {
    let ok: Bool
    let result: String

    var isSuccessful: Bool {
        ok && (result == "restored" || result == "already_restored")
    }
}

private struct PersistedRestoreAttempt: Codable {
    let sourceSecretHash: String
    let targetInstallationID: String
    let targetCredentialHash: String
    let requestID: String

    enum CodingKeys: String, CodingKey {
        case sourceSecretHash = "source_secret_hash"
        case targetInstallationID = "target_installation_id"
        case targetCredentialHash = "target_credential_hash"
        case requestID = "request_id"
    }
}

private struct BillingBindingCredentials {
    let installationID: String
    let bindingSecret: String
}

protocol BillingSecureStore {
    func data(for account: String) -> Data?
    @discardableResult func set(_ data: Data, for account: String) -> Bool
    @discardableResult func remove(account: String) -> Bool
}

protocol BillingScheduledAction: AnyObject {
    func cancel()
}

protocol BillingScheduling: AnyObject {
    var now: Date { get }

    @discardableResult
    func schedule(after delay: TimeInterval,
                  action: @escaping () -> Void) -> BillingScheduledAction
}

private final class MainQueueBillingScheduledAction: BillingScheduledAction {
    private var timer: DispatchSourceTimer?

    init(delay: TimeInterval, action: @escaping () -> Void) {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        self.timer = timer
        timer.schedule(deadline: .now() + max(0, delay))
        timer.setEventHandler { [weak self] in
            guard let self, self.timer != nil else { return }
            self.timer?.setEventHandler {}
            self.timer?.cancel()
            self.timer = nil
            action()
        }
        timer.resume()
    }

    func cancel() {
        timer?.setEventHandler {}
        timer?.cancel()
        timer = nil
    }

    deinit {
        cancel()
    }
}

private final class MainQueueBillingScheduler: BillingScheduling {
    var now: Date { Date() }

    func schedule(after delay: TimeInterval,
                  action: @escaping () -> Void) -> BillingScheduledAction {
        MainQueueBillingScheduledAction(delay: delay, action: action)
    }
}

struct PaddleBillingRefreshSchedule {
    /// A fresh lease is renewed no later than the active refresh interval, or earlier when its
    /// signed expiry window requires it. The one-second floor prevents a stale, non-extending
    /// response from causing a tight request loop close to expiry.
    let renewalLeadFraction: Double
    let maximumRenewalLeadTime: TimeInterval
    let minimumRenewalDelay: TimeInterval
    /// A perpetual purchase still checks for a signed refund/revocation at least daily while the
    /// app and network are available. Offline access remains bounded by the signed 30-day lease.
    let maximumActiveRefreshInterval: TimeInterval
    /// Failures repeat at the final interval until the signed lease actually expires.
    let renewalRetryDelays: [TimeInterval]
    /// Once access has expired, recovery is deliberately finite and low-frequency. A later app
    /// launch still performs the normal startup refresh.
    let expiredRecoveryDelays: [TimeInterval]

    init(renewalLeadFraction: Double = 0.25,
         maximumRenewalLeadTime: TimeInterval = 12 * 60 * 60,
         minimumRenewalDelay: TimeInterval = 1,
         maximumActiveRefreshInterval: TimeInterval = 24 * 60 * 60,
         renewalRetryDelays: [TimeInterval] = [15, 30, 60, 120, 300, 600, 1_800, 3_600],
         expiredRecoveryDelays: [TimeInterval] = [60, 300, 900, 3_600, 10_800, 21_600]) {
        self.renewalLeadFraction = min(max(renewalLeadFraction, 0), 1)
        self.maximumRenewalLeadTime = max(0, maximumRenewalLeadTime)
        self.minimumRenewalDelay = max(0.001, minimumRenewalDelay)
        self.maximumActiveRefreshInterval = max(0.001, maximumActiveRefreshInterval)
        self.renewalRetryDelays = renewalRetryDelays.map { max(0.001, $0) }
        self.expiredRecoveryDelays = expiredRecoveryDelays.map { max(0.001, $0) }
    }
}

final class KeychainBillingSecureStore: BillingSecureStore {
    private let service = "com.yongza.ejectdrives.paddle-billing"

    func data(for account: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    @discardableResult
    func set(_ data: Data, for account: String) -> Bool {
        let key: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let updateStatus = SecItemUpdate(
            key as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if updateStatus == errSecSuccess { return true }
        guard updateStatus == errSecItemNotFound else { return false }

        var insert = key
        insert[kSecValueData as String] = data
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(insert as CFDictionary, nil) == errSecSuccess
    }

    @discardableResult
    func remove(account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}

/// Paddle client state is main-thread confined. Checkout success never unlocks the app directly:
/// only a backend lease signed with the configured Ed25519 key can grant premium access.
final class PaddleBillingController {
    private static let installationAccount = "installation-id"
    private static let entitlementAccount = "entitlement-envelope"
    private static let bindingSecretAccount = "binding-secret"
    private static let legacyPortalSecretAccount = "portal-secret"
    private static let restoreAttemptAccount = "restore-attempt"
    /// Twelve bounded minutes cover normal webhook delays without leaving a permanent poller.
    static let defaultPurchasePollDelays: [TimeInterval] = [2, 4, 8, 16, 30, 60, 120, 180, 300]

    private let configuration: PaddleBillingConfiguration
    private let secureStore: BillingSecureStore
    private let session: URLSession
    private let scheduler: BillingScheduling
    private let refreshSchedule: PaddleBillingRefreshSchedule
    private let purchasePollDelays: [TimeInterval]
    private(set) var installationID: String
    private let bindingSecret: String?
    private(set) var hasPremiumAccess = false
    private(set) var entitlementStatus: PremiumEntitlementStatus = .free
    private(set) var isPurchasePolling = false

    var onAccessChanged: ((Bool) -> Void)?
    var onPurchasePollingChanged: ((Bool) -> Void)?

    private var refreshTask: URLSessionDataTask?
    private var portalTask: URLSessionDataTask?
    private var restoreTask: URLSessionDataTask?
    private var refreshGeneration = 0
    private var portalGeneration = 0
    private var restoreGeneration = 0
    private var refreshCompletions: [(Bool) -> Void] = []
    private var portalCompletion: ((URL?) -> Void)?
    private var restoreCompletion: ((Bool) -> Void)?
    private var purchasePollGeneration = 0
    private var leaseGeneration = 0
    private var purchasePollTask: BillingScheduledAction?
    private var leaseRenewalTask: BillingScheduledAction?
    private var leaseExpiryTask: BillingScheduledAction?
    private var expiredRecoveryTask: BillingScheduledAction?
    private var currentPremiumLeaseExpiration: Date?
    private var hasPreviouslyGrantedLease = false
    private var isStopped = false

    init(configuration: PaddleBillingConfiguration = PaddleBillingConfiguration(),
         secureStore: BillingSecureStore = KeychainBillingSecureStore(),
         session: URLSession = .shared,
         scheduler: BillingScheduling = MainQueueBillingScheduler(),
         refreshSchedule: PaddleBillingRefreshSchedule = PaddleBillingRefreshSchedule(),
         purchasePollDelays: [TimeInterval] = PaddleBillingController.defaultPurchasePollDelays) {
        self.configuration = configuration
        self.secureStore = secureStore
        self.session = session
        self.scheduler = scheduler
        self.refreshSchedule = refreshSchedule
        self.purchasePollDelays = purchasePollDelays
        if configuration.isConfigured {
            let credentials = Self.loadOrCreateBindingCredentials(store: secureStore)
            self.installationID = credentials?.installationID ?? ""
            self.bindingSecret = credentials?.bindingSecret
        } else {
            // Billing is deliberately disabled until every public configuration value is
            // present. Avoid unnecessary Keychain work on the main thread in that state.
            self.installationID = ""
            self.bindingSecret = nil
        }
    }

    /// Public configuration and both persistent local binding credentials are required. This
    /// prevents an orphan purchase tied to an installation identifier that disappears on relaunch.
    var isConfigured: Bool {
        configuration.isConfigured && !installationID.isEmpty && bindingSecret != nil
    }

    var checkoutURL: URL? {
        guard isConfigured, let bindingSecret else { return nil }
        return configuration.checkoutURL(installationID: installationID, bindingSecret: bindingSecret)
    }

    var canOpenPurchaseDetails: Bool {
        hasPremiumAccess && isConfigured && configuration.portalURL() != nil
    }

    var recoveryCode: String? {
        guard isConfigured, let bindingSecret else { return nil }
        return "DOUT1.\(bindingSecret)"
    }

    // Compatibility shims for AppDelegate builds that still use the subscription-era names.
    var canManageSubscription: Bool { canOpenPurchaseDetails }
    var subscriptionStatus: PremiumEntitlementStatus { entitlementStatus }

    func start() {
        precondition(Thread.isMainThread)
        guard isConfigured else { return }
        isStopped = false
        if let cached = secureStore.data(for: Self.entitlementAccount),
           let payload = verifiedPayload(from: cached) {
            apply(payload: payload)
        }
        refresh()
    }

    func refresh(completion: ((Bool) -> Void)? = nil) {
        precondition(Thread.isMainThread)
        if let completion { refreshCompletions.append(completion) }
        guard !isStopped else {
            finishRefresh(success: false)
            return
        }
        guard refreshTask == nil else { return }
        guard isConfigured,
              let bindingSecret,
              let url = configuration.entitlementURL() else {
            finishRefresh(success: false)
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.timeoutInterval = 10
        request.setValue("Bearer \(bindingSecret)", forHTTPHeaderField: "Authorization")
        request.setValue(installationID, forHTTPHeaderField: "X-DiskOUT-Install-ID")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        refreshGeneration += 1
        let generation = refreshGeneration
        let task = session.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let self, self.refreshGeneration == generation else { return }
                self.refreshTask = nil
                guard error == nil,
                      let http = response as? HTTPURLResponse,
                      http.statusCode == 200,
                      let data,
                      data.count <= 16_384,
                      let payload = self.verifiedPayload(from: data) else {
                    billingLog.error("Entitlement refresh failed; keeping the last unexpired verified lease")
                    self.finishRefresh(success: false)
                    return
                }

                if payload.status != .active,
                   !self.secureStore.remove(account: Self.entitlementAccount) {
                    billingLog.error("Could not remove the stale granted entitlement from Keychain")
                }
                if !self.secureStore.set(data, for: Self.entitlementAccount) {
                    billingLog.error("Could not persist verified entitlement in Keychain")
                }
                self.apply(payload: payload)
                self.finishRefresh(success: true)
            }
        }
        refreshTask = task
        task.resume()
    }

    /// Called after the checkout browser opens. A canceled checkout simply exhausts this bounded
    /// polling schedule and leaves the existing access state unchanged; another click starts fresh.
    func startPurchasePolling() {
        precondition(Thread.isMainThread)
        guard !isStopped, isConfigured else { return }
        purchasePollGeneration += 1
        let generation = purchasePollGeneration
        purchasePollTask?.cancel()
        purchasePollTask = nil
        setPurchasePolling(true)
        schedulePurchasePoll(index: 0, generation: generation)
    }

    /// Stops checkout polling immediately. An entitlement request that is already shared with
    /// another billing lifecycle may still finish, but its late polling completion cannot enqueue
    /// another poll or reactivate the polling UI state.
    func cancelPurchasePolling() {
        precondition(Thread.isMainThread)
        purchasePollGeneration += 1
        purchasePollTask?.cancel()
        purchasePollTask = nil
        setPurchasePolling(false)
    }

    func requestPurchaseDetailsURL(completion: @escaping (URL?) -> Void) {
        precondition(Thread.isMainThread)
        guard !isStopped else {
            completion(nil)
            return
        }
        guard portalTask == nil else { return }
        guard canOpenPurchaseDetails,
              let bindingSecret,
              let url = configuration.portalURL() else {
            completion(nil)
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.timeoutInterval = 10
        request.setValue("Bearer \(bindingSecret)", forHTTPHeaderField: "Authorization")
        request.setValue(installationID, forHTTPHeaderField: "X-DiskOUT-Install-ID")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        portalCompletion = completion
        portalGeneration += 1
        let generation = portalGeneration
        let task = session.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let self, self.portalGeneration == generation else { return }
                self.portalTask = nil
                guard error == nil,
                      let http = response as? HTTPURLResponse,
                      http.statusCode == 200,
                      let data,
                      data.count <= 4_096,
                      let payload = try? JSONDecoder().decode(PaddlePortalSessionResponse.self, from: data),
                      let portalURL = URL(string: payload.url),
                      Self.isAllowedPaddlePortalURL(portalURL) else {
                    self.finishPortal(url: nil)
                    return
                }
                self.finishPortal(url: portalURL)
            }
        }
        portalTask = task
        task.resume()
    }

    func requestPortalURL(completion: @escaping (URL?) -> Void) {
        requestPurchaseDetailsURL(completion: completion)
    }

    func restorePurchase(using recoveryCode: String, completion: @escaping (Bool) -> Void) {
        precondition(Thread.isMainThread)
        guard !isStopped,
              isConfigured,
              let sourceSecret = Self.bindingSecret(fromRecoveryCode: recoveryCode),
              let bindingSecret,
              let url = configuration.restoreURL(),
              let requestID = persistedRestoreRequestID(for: sourceSecret) else {
            completion(false)
            return
        }

        guard let request = Self.makeRestoreRequest(
            url: url,
            installationID: installationID,
            sourceSecret: sourceSecret,
            requestID: requestID,
            currentBindingSecret: bindingSecret
        ) else {
            completion(false)
            return
        }

        // A newer restore request owns the shared completion. Build its immutable request first,
        // then replace the prior lifecycle. The old completion runs only after the new task is
        // installed so callback reentrancy can cancel the correct task without state overwrite.
        restoreGeneration += 1
        let generation = restoreGeneration
        restoreTask?.cancel()
        restoreTask = nil
        let previousCompletion = restoreCompletion
        restoreCompletion = completion

        let task = session.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let self,
                      !self.isStopped,
                      self.restoreGeneration == generation else { return }
                self.restoreTask = nil
                guard error == nil,
                      let http = response as? HTTPURLResponse,
                      http.statusCode == 200,
                      let data,
                      data.count <= 4_096,
                      let responsePayload = try? JSONDecoder().decode(PaddleRestoreResponse.self, from: data),
                      responsePayload.isSuccessful else {
                    self.finishRestore(generation: generation, success: false)
                    return
                }

                // Restore acknowledgement is not an entitlement. Only the separately fetched,
                // Ed25519-signed lease may change Premium access.
                self.forceRefreshAfterRestore { [weak self] refreshSucceeded in
                    guard let self,
                          !self.isStopped,
                          self.restoreGeneration == generation else { return }
                    let restored = refreshSucceeded && self.hasPremiumAccess
                    if restored {
                        self.retireCompletedRestoreAttempt()
                    }
                    self.finishRestore(generation: generation, success: restored)
                }
            }
        }
        restoreTask = task
        task.resume()
        previousCompletion?(false)
    }

    /// Internal request factory kept deterministic so security-sensitive body/header placement can
    /// be tested without relying on URLProtocol, which strips upload bodies on some macOS releases.
    static func makeRestoreRequest(
        url: URL,
        installationID: String,
        sourceSecret: String,
        requestID: String,
        currentBindingSecret: String
    ) -> URLRequest? {
        let payload = PaddleRestoreRequest(
            requestID: requestID,
            newCredentialSHA256: sha256Hex(Data(currentBindingSecret.utf8))
        )
        guard let body = try? JSONEncoder().encode(payload) else { return nil }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.timeoutInterval = 10
        request.setValue("Bearer \(sourceSecret)", forHTTPHeaderField: "Authorization")
        request.setValue(installationID, forHTTPHeaderField: "X-DiskOUT-Install-ID")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    func stop() {
        precondition(Thread.isMainThread)
        isStopped = true
        refreshGeneration += 1
        refreshTask?.cancel()
        refreshTask = nil
        portalGeneration += 1
        portalTask?.cancel()
        portalTask = nil
        portalCompletion = nil
        restoreGeneration += 1
        restoreTask?.cancel()
        restoreTask = nil
        let restoreCompletion = self.restoreCompletion
        self.restoreCompletion = nil
        restoreCompletion?(false)
        let completions = refreshCompletions
        refreshCompletions.removeAll()
        completions.forEach { $0(false) }
        cancelPurchasePolling()
        leaseGeneration += 1
        cancelLeaseTasks()
        currentPremiumLeaseExpiration = nil
    }

    private static func isAllowedPaddlePortalURL(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased() else { return false }
        return host.hasSuffix(".paddle.com")
    }

    private func finishPortal(url: URL?) {
        let completion = portalCompletion
        portalCompletion = nil
        completion?(url)
    }

    private func finishRestore(generation: Int, success: Bool) {
        guard restoreGeneration == generation else { return }
        let completion = restoreCompletion
        restoreCompletion = nil
        completion?(success)
    }

    private func schedulePurchasePoll(index: Int, generation: Int) {
        guard !isStopped, purchasePollGeneration == generation else { return }
        guard index < purchasePollDelays.count else {
            setPurchasePolling(false)
            return
        }
        purchasePollTask = scheduler.schedule(after: purchasePollDelays[index]) { [weak self] in
            guard let self,
                  !self.isStopped,
                  self.purchasePollGeneration == generation else { return }
            self.purchasePollTask = nil
            self.refresh { [weak self] _ in
                guard let self,
                      !self.isStopped,
                      self.purchasePollGeneration == generation else { return }
                if self.hasPremiumAccess {
                    self.purchasePollGeneration += 1
                    self.purchasePollTask?.cancel()
                    self.purchasePollTask = nil
                } else {
                    self.schedulePurchasePoll(index: index + 1, generation: generation)
                }
            }
        }
    }

    private func verifiedPayload(from envelopeData: Data) -> PremiumAccessPayload? {
        guard isConfigured,
              let publicKeyData = configuration.entitlementPublicKey,
              let envelope = try? JSONDecoder().decode(SignedPremiumEntitlement.self, from: envelopeData),
              let payloadData = Data(base64Encoded: envelope.payload),
              let signatureData = Data(base64Encoded: envelope.signature),
              let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKeyData),
              publicKey.isValidSignature(signatureData, for: payloadData),
              let payload = try? Self.payloadDecoder().decode(PremiumAccessPayload.self, from: payloadData),
              PremiumAccessPolicy.acceptsLease(
                  payload: payload,
                  expectedInstallID: installationID,
                  expectedPriceID: configuration.oneTimePriceID,
                  now: scheduler.now
              ) else {
            return nil
        }
        return payload
    }

    private func apply(payload: PremiumAccessPayload) {
        entitlementStatus = payload.status
        let granted = PremiumAccessPolicy.grantsPremium(
            payload: payload,
            expectedInstallID: installationID,
            expectedPriceID: configuration.oneTimePriceID,
            now: scheduler.now
        )
        setAccess(granted)

        leaseGeneration += 1
        let generation = leaseGeneration
        cancelLeaseTasks()

        guard granted else {
            currentPremiumLeaseExpiration = nil
            hasPreviouslyGrantedLease = false
            return
        }

        hasPreviouslyGrantedLease = true
        currentPremiumLeaseExpiration = payload.expiresAt
        stopPurchasePollingAfterGrant()
        scheduleLeaseExpiry(at: payload.expiresAt, generation: generation)
        scheduleLeaseRenewal(for: payload, generation: generation)
    }

    private func scheduleLeaseRenewal(for payload: PremiumAccessPayload, generation: Int) {
        let now = scheduler.now
        let remaining = payload.expiresAt.timeIntervalSince(now)
        guard remaining > refreshSchedule.minimumRenewalDelay else { return }

        let leaseDuration = payload.expiresAt.timeIntervalSince(payload.issuedAt)
        let renewalLead = min(
            refreshSchedule.maximumRenewalLeadTime,
            max(0, leaseDuration * refreshSchedule.renewalLeadFraction)
        )
        let desiredDelay = payload.expiresAt
            .addingTimeInterval(-renewalLead)
            .timeIntervalSince(now)
        let expirationDrivenDelay = max(refreshSchedule.minimumRenewalDelay, desiredDelay)
        let delay = min(refreshSchedule.maximumActiveRefreshInterval, expirationDrivenDelay)
        guard delay < remaining else { return }

        leaseRenewalTask = scheduler.schedule(after: delay) { [weak self] in
            guard let self,
                  !self.isStopped,
                  self.leaseGeneration == generation else { return }
            self.leaseRenewalTask = nil
            self.refresh { [weak self] success in
                guard let self,
                      !self.isStopped,
                      self.leaseGeneration == generation else { return }
                if !success {
                    self.scheduleLeaseRenewalRetry(index: 0, generation: generation)
                }
            }
        }
    }

    private func scheduleLeaseRenewalRetry(index: Int, generation: Int) {
        guard leaseGeneration == generation,
              let expiration = currentPremiumLeaseExpiration else { return }
        let remaining = expiration.timeIntervalSince(scheduler.now)
        guard remaining > 0 else {
            expireLease(generation: generation)
            return
        }
        guard !refreshSchedule.renewalRetryDelays.isEmpty else { return }

        let configuredDelay = refreshSchedule.renewalRetryDelays[
            min(index, refreshSchedule.renewalRetryDelays.count - 1)
        ]
        // When a failure happens very close to expiry, retain a small chance to recover without
        // ever allowing a retry to postpone revocation beyond the signed deadline.
        let delay = max(
            refreshSchedule.minimumRenewalDelay,
            min(configuredDelay, remaining / 2)
        )
        guard delay < remaining else { return }

        leaseRenewalTask?.cancel()
        leaseRenewalTask = scheduler.schedule(after: delay) { [weak self] in
            guard let self,
                  !self.isStopped,
                  self.leaseGeneration == generation else { return }
            self.leaseRenewalTask = nil
            self.refresh { [weak self] success in
                guard let self,
                      !self.isStopped,
                      self.leaseGeneration == generation else { return }
                if !success {
                    self.scheduleLeaseRenewalRetry(index: index + 1, generation: generation)
                }
            }
        }
    }

    private func scheduleLeaseExpiry(at expiration: Date, generation: Int) {
        leaseExpiryTask = scheduler.schedule(
            after: max(0, expiration.timeIntervalSince(scheduler.now))
        ) { [weak self] in
            guard let self,
                  !self.isStopped,
                  self.leaseGeneration == generation else { return }
            self.leaseExpiryTask = nil

            let remaining = expiration.timeIntervalSince(self.scheduler.now)
            if remaining > 0 {
                self.scheduleLeaseExpiry(at: expiration, generation: generation)
            } else {
                self.expireLease(generation: generation)
            }
        }
    }

    private func expireLease(generation: Int) {
        guard leaseGeneration == generation,
              currentPremiumLeaseExpiration != nil else { return }
        // Invalidate a renewal timer that was already enqueued at the same moment as expiry.
        // A signed response from an in-flight request may still install a new lease via apply(),
        // but its old lifecycle completion cannot schedule more retries.
        leaseGeneration += 1
        let recoveryGeneration = leaseGeneration
        currentPremiumLeaseExpiration = nil
        leaseRenewalTask?.cancel()
        leaseRenewalTask = nil
        setAccess(false)
        entitlementStatus = .free

        if hasPreviouslyGrantedLease {
            scheduleExpiredRecovery(index: 0, generation: recoveryGeneration)
        }
    }

    private func scheduleExpiredRecovery(index: Int, generation: Int) {
        guard !isStopped,
              leaseGeneration == generation,
              hasPreviouslyGrantedLease,
              index < refreshSchedule.expiredRecoveryDelays.count else { return }

        expiredRecoveryTask?.cancel()
        expiredRecoveryTask = scheduler.schedule(
            after: refreshSchedule.expiredRecoveryDelays[index]
        ) { [weak self] in
            guard let self,
                  !self.isStopped,
                  self.leaseGeneration == generation else { return }
            self.expiredRecoveryTask = nil
            self.refresh { [weak self] success in
                guard let self,
                      !self.isStopped,
                      self.leaseGeneration == generation else { return }
                if !success {
                    self.scheduleExpiredRecovery(index: index + 1, generation: generation)
                }
            }
        }
    }

    private func stopPurchasePollingAfterGrant() {
        cancelPurchasePolling()
    }

    private func cancelLeaseTasks() {
        leaseRenewalTask?.cancel()
        leaseRenewalTask = nil
        leaseExpiryTask?.cancel()
        leaseExpiryTask = nil
        expiredRecoveryTask?.cancel()
        expiredRecoveryTask = nil
    }

    private func setAccess(_ granted: Bool) {
        guard hasPremiumAccess != granted else { return }
        hasPremiumAccess = granted
        onAccessChanged?(granted)
    }

    private func setPurchasePolling(_ polling: Bool) {
        guard isPurchasePolling != polling else { return }
        isPurchasePolling = polling
        onPurchasePollingChanged?(polling)
    }

    private func finishRefresh(success: Bool) {
        let completions = refreshCompletions
        refreshCompletions.removeAll()
        completions.forEach { $0(success) }
    }

    /// A restore rebind changes the authoritative credential mapping. Never join an entitlement
    /// request that started before the restore acknowledgement because its signed-free response
    /// may be a valid snapshot of the old mapping.
    private func forceRefreshAfterRestore(completion: @escaping (Bool) -> Void) {
        precondition(Thread.isMainThread)
        refreshGeneration += 1
        refreshTask?.cancel()
        refreshTask = nil
        finishRefresh(success: false)
        refresh(completion: completion)
    }

    private static func loadOrCreateBindingCredentials(
        store: BillingSecureStore
    ) -> BillingBindingCredentials? {
        if let data = store.data(for: installationAccount),
           let string = String(data: data, encoding: .utf8),
           isValidUUIDv4(string),
           let uuid = UUID(uuidString: string) {
            guard let secret = loadOrCreateBindingSecretForExistingInstallation(store: store) else {
                return nil
            }
            return BillingBindingCredentials(
                installationID: uuid.uuidString.lowercased(),
                bindingSecret: secret
            )
        }

        // If only the old secret survived, reusing it with a new install ID would make restore send
        // oldHash == newHash. Rotate and persist the new secret first; an installation write failure
        // then remains fail-closed on this and subsequent launches instead of committing that pair.
        guard let secret = generateBindingSecret(),
              store.set(Data(secret.utf8), for: bindingSecretAccount) else {
            billingLog.error("Could not persist the rotated billing binding credential in Keychain")
            return nil
        }
        let installationID = UUID().uuidString.lowercased()
        guard store.set(Data(installationID.utf8), for: installationAccount) else {
            billingLog.error("Could not persist the billing installation identifier in Keychain")
            return nil
        }
        return BillingBindingCredentials(installationID: installationID, bindingSecret: secret)
    }

    private static func loadOrCreateBindingSecretForExistingInstallation(
        store: BillingSecureStore
    ) -> String? {
        if let data = store.data(for: bindingSecretAccount),
           let string = String(data: data, encoding: .utf8),
           isValidBindingSecret(string) {
            // Repair credentials copied by an unreleased subscription-to-v2 migration. A normal
            // v2 credential differs from the retained legacy portal secret and remains stable.
            if let legacyData = store.data(for: legacyPortalSecretAccount),
               let legacy = String(data: legacyData, encoding: .utf8),
               isValidBindingSecret(legacy),
               legacy == string {
                guard let rotated = generateBindingSecret(),
                      store.set(Data(rotated.utf8), for: bindingSecretAccount) else {
                    billingLog.error("Could not rotate the legacy billing binding credential")
                    return nil
                }
                return rotated
            }
            return string
        }

        // A subscription-era portal credential is not a v2 recovery credential. Always generate
        // a fresh binding secret and leave the legacy Keychain item untouched for compatibility.
        guard let created = generateBindingSecret(),
              store.set(Data(created.utf8), for: bindingSecretAccount) else {
            billingLog.error("Could not persist the billing binding credential in Keychain")
            return nil
        }
        return created
    }

    private static func generateBindingSecret() -> String? {
        var bytes = [UInt8](repeating: 0, count: 32)
        let randomStatus = bytes.withUnsafeMutableBytes { buffer in
            guard let baseAddress = buffer.baseAddress else { return errSecParam }
            return SecRandomCopyBytes(kSecRandomDefault, buffer.count, baseAddress)
        }
        guard randomStatus == errSecSuccess else {
            billingLog.error("Could not generate the billing binding credential")
            return nil
        }
        let created = Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return isValidBindingSecret(created) ? created : nil
    }

    private func persistedRestoreRequestID(for sourceSecret: String) -> String? {
        guard let bindingSecret else { return nil }
        let sourceHash = Self.sha256Hex(Data(sourceSecret.utf8))
        let targetHash = Self.sha256Hex(Data(bindingSecret.utf8))
        if let data = secureStore.data(for: Self.restoreAttemptAccount),
           let attempt = try? JSONDecoder().decode(PersistedRestoreAttempt.self, from: data),
           attempt.sourceSecretHash == sourceHash,
           attempt.targetInstallationID == installationID,
           attempt.targetCredentialHash == targetHash,
           Self.isValidUUIDv4(attempt.requestID) {
            return attempt.requestID.lowercased()
        }

        let requestID = UUID().uuidString.lowercased()
        let attempt = PersistedRestoreAttempt(
            sourceSecretHash: sourceHash,
            targetInstallationID: installationID,
            targetCredentialHash: targetHash,
            requestID: requestID
        )
        guard let data = try? JSONEncoder().encode(attempt),
              secureStore.set(data, for: Self.restoreAttemptAccount) else {
            billingLog.error("Could not persist the idempotent purchase restore request")
            return nil
        }
        return requestID
    }

    private func retireCompletedRestoreAttempt() {
        guard !secureStore.remove(account: Self.restoreAttemptAccount) else { return }
        // The signed active lease remains authoritative, so cleanup failure cannot revoke access.
        // Rotate the persisted request ID as a fallback: if the same source and target participate
        // in a later transfer cycle, the already-applied idempotency key is never reused.
        billingLog.error("Could not remove the completed purchase restore request")
        guard let data = secureStore.data(for: Self.restoreAttemptAccount),
              let attempt = try? JSONDecoder().decode(PersistedRestoreAttempt.self, from: data) else {
            return
        }
        let replacement = PersistedRestoreAttempt(
            sourceSecretHash: attempt.sourceSecretHash,
            targetInstallationID: attempt.targetInstallationID,
            targetCredentialHash: attempt.targetCredentialHash,
            requestID: UUID().uuidString.lowercased()
        )
        guard let replacementData = try? JSONEncoder().encode(replacement),
              secureStore.set(replacementData, for: Self.restoreAttemptAccount) else {
            billingLog.error("Could not rotate the completed purchase restore request")
            return
        }
    }

    private static func bindingSecret(fromRecoveryCode value: String) -> String? {
        let prefix = "DOUT1."
        guard value.hasPrefix(prefix) else { return nil }
        let secret = String(value.dropFirst(prefix.count))
        return isValidBindingSecret(secret) ? secret : nil
    }

    private static func isValidBindingSecret(_ value: String) -> Bool {
        value.count == 43 && value.allSatisfy {
            $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_")
        }
    }

    private static func isValidUUIDv4(_ value: String) -> Bool {
        guard value.count == 36,
              UUID(uuidString: value) != nil else { return false }
        let characters = Array(value.lowercased())
        return characters[14] == "4" && "89ab".contains(characters[19])
    }

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func payloadDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let value = try decoder.singleValueContainer().decode(String.self)
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = fractional.date(from: value) { return date }
            let standard = ISO8601DateFormatter()
            guard let date = standard.date(from: value) else {
                throw DecodingError.dataCorruptedError(
                    in: try decoder.singleValueContainer(),
                    debugDescription: "Invalid RFC 3339 date"
                )
            }
            return date
        }
        return decoder
    }
}
