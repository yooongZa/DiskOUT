// Appended to an isolated copy of AppDelegate.swift by scripts/test-manual-disk-integration.py.
// The normal app entry point is never run. No real unmount, mount, or sleep is submitted.
private func qaExpect(_ value: @autoclosure () -> Bool, _ message: String) {
    guard value() else { fputs("FAIL: \(message)\n", stderr); exit(1) }
}

extension AppDelegate {
    fileprivate func verifyManualCommandIntegration(output: URL) throws {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        defer { statusCharacterAnimator.invalidate(); NSStatusBar.system.removeStatusItem(statusItem) }
        let context = beginManualDiskCommand(title: "QA")!
        qaExpect(beginManualDiskCommand(title: "duplicate") == nil, "a reserved command rejects a second command")
        mountAll(caller: "qa-blocked")
        ejectAll(caller: "qa-blocked")
        ejectAndSleep(caller: "qa-blocked")
        qaExpect(manualDiskCommands.isBusy, "public actions cannot take over the current reservation")
        sleepUnmountActivityTracker.begin()
        finishManualDiskCommand(context)
        qaExpect(manualDiskCommands.isBusy, "a waiter return must retain ownership while macOS is pending")
        sleepUnmountActivityTracker.finish()
        qaExpect(!manualDiskCommands.isBusy, "terminal request completion releases ownership")
        manualEjectAndSleepCommandInFlight = true
        qaExpect(beginManualDiskCommand(title: "mount") == nil, "sleep transaction blocks new mount commands")
        manualEjectAndSleepCommandInFlight = false

        startManualEject(url: URL(fileURLWithPath: "/Volumes/DiskOUT-QA-NOT-A-DISK"), name: "QA", expected: nil)
        qaExpect(!manualDiskCommands.isBusy, "legacy notification without identity is rejected and releases its reservation")

        // An impossible physical identity guarantees the real pmset launch closure is denied.
        let fake = EjectAndSleepDiskIdentity(wholeDiskBSD: "disk999999QA", physicalGeneration: UInt64.max,
                                             mediaRegistryEntryID: UInt64.max)
        manualEjectAndSleepCommandInFlight = true
        let attempt = beginManualEjectAndSleepAttempt(targets: [fake], startedAtNanoseconds: DispatchTime.now().uptimeNanoseconds)!
        let owner = LibraryAppRelaunchOwner(rawValue: "qa-no-apps")
        let nonce = armManualEjectAndSleep(attemptID: attempt, targets: [fake], operationID: "qa", libraryOwner: owner)!
        let sleep = requestSystemSleep(nonce: nonce)
        qaExpect(!sleep.launched && !sleep.success && sleep.errorMessage != nil, "changed media rejects process launch with an actionable error")
        qaExpect(cancelArmedManualEjectAndSleep(nonce: nonce, reason: "qa"), "failed final validation can disarm the transaction")
        qaExpect(!manualEjectAndSleepCommandInFlight, "final validation failure does not strand the sleep reservation")

        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        for theme in [NSAppearance.Name.aqua, .darkAqua] {
            NSApp.appearance = NSAppearance(named: theme)
            for outcome in [ManualDiskOutcome.pending, .ejected, .forced, .mounted, .absent, .failed] {
                manualOperationTitle = outcome.title
                manualOperationDetail = "QA disk: \(outcome.title)"
                let menu = NSMenu()
                populateMenu(menu, snapshot: DiskMenuSnapshot(drives: [], unmounted: [], createdAt: Date(), refreshError: nil), isRefreshing: false)
                qaExpect(menu.items.contains { $0.title == outcome.title && !$0.isEnabled }, "result remains in the native menu with notifications off")
                qaExpect(menu.size.width < 700, "localized result fits the native menu")
            }
            let onboarding = OnboardingWindowController(onClosed: {})
            let window = onboarding.window!
            window.appearance = NSAppearance(named: theme)
            let view = window.contentView!
            view.wantsLayer = true
            window.appearance!.performAsCurrentDrawingAppearance {
                view.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
            }
            window.orderFrontRegardless()
            view.layoutSubtreeIfNeeded()
            window.display()
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            func checkLabels(_ parent: NSView) {
                for child in parent.subviews {
                    if let field = child as? NSTextField, !field.stringValue.isEmpty {
                        let required = field.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: field.bounds.width, height: 10000)).height ?? 0
                        qaExpect(required <= field.bounds.height + 2, "onboarding label is not vertically clipped: \(field.stringValue)")
                    }
                    checkLabels(child)
                }
            }
            checkLabels(view)
            let image = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
            window.appearance!.performAsCurrentDrawingAppearance {
                view.cacheDisplay(in: view.bounds, to: image)
            }
            window.orderOut(nil)
            try image.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent("onboarding-\(theme.rawValue).png"))
        }
        print("ManualDiskAppIntegration: PASS (entry guards, pending ownership, stale retry, sleep preflight, 12 menu states, 2 onboarding themes)")
    }
}

@main
private enum ManualDiskQAMain {
    static func main() throws {
        let domain = Bundle.main.bundleIdentifier!
        defer { UserDefaults.standard.removePersistentDomain(forName: domain) }
        UserDefaults.standard.set(false, forKey: "settings.notifications.enabled")
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        let app = AppDelegate()
        try app.verifyManualCommandIntegration(output: URL(fileURLWithPath: CommandLine.arguments[1]))
    }
}
