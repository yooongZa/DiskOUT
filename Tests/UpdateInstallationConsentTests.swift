import Foundation

@main enum UpdateInstallationConsentTests {
    static func check(_ value: @autoclosure () -> Bool, _ message: String) {
        guard value() else { fatalError(message) }
        print("PASS: \(message)")
    }

    static func main() {
        var consent = UpdateInstallationConsent()
        check(!consent.consumeInstallRequest(), "background download requires confirmation")
        var session = consent.begin()
        check(!consent.consumeInstallRequest(), "showing an update is not install consent")
        for install in [false, true] {
            session = consent.begin()
            consent.record(install: install, for: session)
            check(consent.consumeInstallRequest() == install, "only explicit Install continues (\(install))")
            check(!consent.consumeInstallRequest(), "consent can be consumed only once (\(install))")
        }
        session = consent.begin()
        consent.record(install: true, for: session)
        consent.invalidate(session: session)
        consent.record(install: true, for: session)
        check(!consent.consumeInstallRequest(), "cancellation revokes consent and ignores late response")
        session = consent.begin()
        consent.record(install: true, for: session)
        let newSession = consent.begin()
        consent.record(install: true, for: session)
        check(!consent.consumeInstallRequest(), "another version cannot inherit earlier Install")
        session = consent.begin()
        consent.record(install: true, for: session)
        consent.invalidate()
        check(!consent.consumeInstallRequest(), "error or session end revokes consent")
        let current = consent.begin()
        consent.record(install: true, for: current)
        consent.invalidate(session: newSession)
        check(consent.consumeInstallRequest(), "stale cancellation cannot cancel the current update")
        var relaunched = UpdateInstallationConsent()
        check(!relaunched.consumeInstallRequest(), "app relaunch starts without consent")
    }
}
