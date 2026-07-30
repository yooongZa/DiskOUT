import Foundation

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

@main
private enum DiskActivityPolicyTests {
    static func main() {
        testInactiveGraceAndClear()
        testReactivationResetsGrace()
        testLowVolumeIOOnlySustainsExistingActivity()
        testDirectionsAndDisksRemainIndependent()
        testMultipleDisksRemainIndependent()
        testRemovedDiskClearsImmediately()
        testResetClearsAllState()
        testActivityMediaClassification()
        print("DiskActivityPolicyTests: PASS")
    }

    private static func testInactiveGraceAndClear() {
        var state = DiskActivityState(inactivePollLimit: 3)
        let present: Set<String> = ["disk6"]

        var snapshot = state.update(
            detectedWriting: ["disk6"],
            detectedReading: [],
            observedWriting: ["disk6"],
            observedReading: [],
            presentDisks: present
        )
        expect(snapshot.writing == ["disk6"], "detected write activates immediately")

        snapshot = state.update(
            detectedWriting: [], detectedReading: [],
            observedWriting: [], observedReading: [],
            presentDisks: present
        )
        expect(snapshot.writing == ["disk6"], "first inactive poll preserves activity")
        snapshot = state.update(
            detectedWriting: [], detectedReading: [],
            observedWriting: [], observedReading: [],
            presentDisks: present
        )
        expect(snapshot.writing == ["disk6"], "second inactive poll preserves activity")
        snapshot = state.update(
            detectedWriting: [], detectedReading: [],
            observedWriting: [], observedReading: [],
            presentDisks: present
        )
        expect(snapshot == .inactive, "third inactive poll clears activity")
    }

    private static func testReactivationResetsGrace() {
        var state = DiskActivityState(inactivePollLimit: 3)
        let present: Set<String> = ["disk6"]

        _ = state.update(
            detectedWriting: ["disk6"], detectedReading: [],
            observedWriting: ["disk6"], observedReading: [],
            presentDisks: present
        )
        _ = state.update(
            detectedWriting: [], detectedReading: [],
            observedWriting: [], observedReading: [],
            presentDisks: present
        )
        _ = state.update(
            detectedWriting: [], detectedReading: [],
            observedWriting: [], observedReading: [],
            presentDisks: present
        )
        _ = state.update(
            detectedWriting: ["disk6"], detectedReading: [],
            observedWriting: ["disk6"], observedReading: [],
            presentDisks: present
        )
        _ = state.update(
            detectedWriting: [], detectedReading: [],
            observedWriting: [], observedReading: [],
            presentDisks: present
        )
        let snapshot = state.update(
            detectedWriting: [], detectedReading: [],
            observedWriting: [], observedReading: [],
            presentDisks: present
        )

        expect(snapshot.writing == ["disk6"], "new activity resets the inactive countdown")
    }

    private static func testLowVolumeIOOnlySustainsExistingActivity() {
        var state = DiskActivityState(inactivePollLimit: 3)
        let present: Set<String> = ["disk6"]

        var snapshot = state.update(
            detectedWriting: [],
            detectedReading: [],
            observedWriting: ["disk6"],
            observedReading: [],
            presentDisks: present
        )
        expect(snapshot == .inactive, "sub-threshold I/O does not activate an idle disk")

        _ = state.update(
            detectedWriting: ["disk6"],
            detectedReading: [],
            observedWriting: ["disk6"],
            observedReading: [],
            presentDisks: present
        )
        _ = state.update(
            detectedWriting: [], detectedReading: [],
            observedWriting: [], observedReading: [],
            presentDisks: present
        )
        _ = state.update(
            detectedWriting: [], detectedReading: [],
            observedWriting: [], observedReading: [],
            presentDisks: present
        )
        snapshot = state.update(
            detectedWriting: [],
            detectedReading: [],
            observedWriting: ["disk6"],
            observedReading: [],
            presentDisks: present
        )
        expect(snapshot.writing == ["disk6"], "sub-threshold I/O sustains an active disk")

        _ = state.update(
            detectedWriting: [], detectedReading: [],
            observedWriting: [], observedReading: [],
            presentDisks: present
        )
        snapshot = state.update(
            detectedWriting: [], detectedReading: [],
            observedWriting: [], observedReading: [],
            presentDisks: present
        )
        expect(snapshot.writing == ["disk6"], "sustain signal resets the inactive countdown")
    }

    private static func testDirectionsAndDisksRemainIndependent() {
        var state = DiskActivityState(inactivePollLimit: 3)
        let present: Set<String> = ["disk6", "disk8"]

        _ = state.update(
            detectedWriting: ["disk6"],
            detectedReading: ["disk8"],
            observedWriting: ["disk6"],
            observedReading: ["disk8"],
            presentDisks: present
        )
        _ = state.update(
            detectedWriting: [], detectedReading: ["disk8"],
            observedWriting: [], observedReading: ["disk8"],
            presentDisks: present
        )
        _ = state.update(
            detectedWriting: [], detectedReading: ["disk8"],
            observedWriting: [], observedReading: ["disk8"],
            presentDisks: present
        )
        let snapshot = state.update(
            detectedWriting: [],
            detectedReading: ["disk8"],
            observedWriting: [],
            observedReading: ["disk8"],
            presentDisks: present
        )

        expect(snapshot.writing.isEmpty, "idle writing disk clears independently")
        expect(snapshot.reading == ["disk8"], "active reading disk remains independently")
    }

    private static func testMultipleDisksRemainIndependent() {
        var state = DiskActivityState(inactivePollLimit: 3)
        let present: Set<String> = ["disk6", "disk8"]

        _ = state.update(
            detectedWriting: ["disk6", "disk8"],
            detectedReading: [],
            observedWriting: ["disk6", "disk8"],
            observedReading: [],
            presentDisks: present
        )
        for _ in 0..<3 {
            _ = state.update(
                detectedWriting: [],
                detectedReading: [],
                observedWriting: ["disk6"],
                observedReading: [],
                presentDisks: present
            )
        }
        let snapshot = state.update(
            detectedWriting: [],
            detectedReading: [],
            observedWriting: ["disk6"],
            observedReading: [],
            presentDisks: present
        )

        expect(snapshot.writing == ["disk6"], "one idle disk does not clear another active disk")
    }

    private static func testRemovedDiskClearsImmediately() {
        var state = DiskActivityState(inactivePollLimit: 3)
        _ = state.update(
            detectedWriting: ["disk6"],
            detectedReading: ["disk6"],
            observedWriting: ["disk6"],
            observedReading: ["disk6"],
            presentDisks: ["disk6"]
        )
        let snapshot = state.update(
            detectedWriting: [],
            detectedReading: [],
            observedWriting: [],
            observedReading: [],
            presentDisks: []
        )

        expect(snapshot == .inactive, "removed disk bypasses inactivity grace")
    }

    private static func testResetClearsAllState() {
        var state = DiskActivityState(inactivePollLimit: 3)
        _ = state.update(
            detectedWriting: ["disk6"],
            detectedReading: ["disk8"],
            observedWriting: ["disk6"],
            observedReading: ["disk8"],
            presentDisks: ["disk6", "disk8"]
        )

        expect(state.reset() == .inactive, "explicit reset clears every disk and direction")
    }

    private static func testActivityMediaClassification() {
        expect(DiskActivityMediaPolicy.shouldInclude(
            physicalLocation: "External",
            busProtocol: "USB",
            isRemovable: false,
            isEjectable: false
        ), "external SSD remains included")

        expect(DiskActivityMediaPolicy.shouldInclude(
            physicalLocation: "Internal",
            busProtocol: "Secure Digital",
            isRemovable: true,
            isEjectable: true
        ), "built-in SDXC media is included")

        expect(!DiskActivityMediaPolicy.shouldInclude(
            physicalLocation: "Internal",
            busProtocol: "PCI",
            isRemovable: false,
            isEjectable: false
        ), "internal SSD remains excluded")

        expect(!DiskActivityMediaPolicy.shouldInclude(
            physicalLocation: "File",
            busProtocol: "Virtual Interface",
            isRemovable: true,
            isEjectable: true
        ), "disk image remains excluded")

        expect(!DiskActivityMediaPolicy.shouldInclude(
            physicalLocation: nil,
            busProtocol: "USB",
            isRemovable: true,
            isEjectable: true
        ), "missing location fails closed")
    }
}
