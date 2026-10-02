import Foundation

/// Consent belongs to one update presentation and never survives cancellation or relaunch.
struct UpdateInstallationConsent {
    private(set) var session: UUID?
    private var requestedInstall = false

    mutating func begin() -> UUID {
        let token = UUID()
        session = token
        requestedInstall = false
        return token
    }

    mutating func record(install: Bool, for token: UUID) {
        guard session == token else { return }
        requestedInstall = install
    }

    mutating func invalidate(session token: UUID? = nil) {
        if let token, session != token { return }
        session = nil
        requestedInstall = false
    }

    mutating func consumeInstallRequest() -> Bool {
        let shouldInstall = session != nil && requestedInstall
        invalidate()
        return shouldInstall
    }
}
