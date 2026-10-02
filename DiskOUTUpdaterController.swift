import AppKit
import Sparkle

/// Keep Sparkle's standard prompts and progress UI; continue after an explicit Install choice.
@MainActor final class DiskOUTUpdateUserDriver: SPUStandardUserDriver {
    private var consent = UpdateInstallationConsent()

    override func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState,
                                  reply: @escaping (SPUUserUpdateChoice) -> Void) {
        let session = consent.begin()
        super.showUpdateFound(with: appcastItem, state: state) { [weak self] choice in
            self?.consent.record(install: choice == .install, for: session)
            reply(choice)
        }
    }

    override func showDownloadInitiated(cancellation: @escaping () -> Void) {
        let session = consent.session
        super.showDownloadInitiated { [weak self] in
            if let session { self?.consent.invalidate(session: session) }
            cancellation()
        }
    }

    override func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        if consent.consumeInstallRequest() {
            reply(.install)
        } else {
            super.showReady(toInstallAndRelaunch: reply)
        }
    }

    override func dismissUpdateInstallation() {
        consent.invalidate()
        super.dismissUpdateInstallation()
    }
}

/// SPUStandardUpdaterController cannot accept a custom user driver, so compose its public APIs.
@preconcurrency @MainActor final class DiskOUTUpdaterController {
    let updater: SPUUpdater
    let userDriver: DiskOUTUpdateUserDriver

    init(updaterDelegate: SPUUpdaterDelegate?, userDriverDelegate: SPUStandardUserDriverDelegate?) {
        userDriver = DiskOUTUpdateUserDriver(hostBundle: .main, delegate: userDriverDelegate)
        updater = SPUUpdater(hostBundle: .main, applicationBundle: .main,
                             userDriver: userDriver, delegate: updaterDelegate)
    }

    func checkForUpdates(_ sender: Any?) {
        updater.checkForUpdates()
    }
}
