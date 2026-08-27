import Foundation

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

@main
private enum CrashReportParsingTests {
    private static let expectedBundleID = "com.yongza.ejectdrives"
    private static let fixtureDirectory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/CrashReports", isDirectory: true)

    static func main() throws {
        try testMalformedThenNormalReport()
        try testNegativeFaultingThreadFallsBackToFirstThread()
        try testNegativeImageIndexUsesUnknownBinaryAndContinues()
        print("CrashReportParsingTests: PASS")
    }

    private static func fixture(named name: String) throws -> String {
        try String(
            contentsOf: fixtureDirectory.appendingPathComponent(name),
            encoding: .utf8
        )
    }

    private static func document(named name: String) throws -> CrashReportDocument {
        let raw = try fixture(named: name)
        guard let document = CrashReportParsing.document(
            from: raw,
            expectedBundleID: expectedBundleID
        ) else {
            fputs("FAIL: expected valid fixture \(name)\n", stderr)
            exit(1)
        }
        return document
    }

    private static func testMalformedThenNormalReport() throws {
        let malformed = try fixture(named: "malformed.ips")
        expect(
            CrashReportParsing.document(from: malformed, expectedBundleID: expectedBundleID) == nil,
            "a malformed body must be skipped"
        )

        let normal = try document(named: "normal.ips")
        expect(normal.header["incident_id"] as? String == "11111111-2222-3333-4444-555555555555",
               "normal report incident identity must be preserved")
        expect(normal.header["app_version"] as? String == "0.5.7",
               "normal report app version must be preserved")
        let osVersion = normal.body["osVersion"] as? [String: Any]
        expect(osVersion?["train"] as? String == "macOS 15.6",
               "normal report OS train must be preserved")

        let trace = CrashReportParsing.backtrace(from: normal.body, topFrameLimit: 20)
        expect(trace.topAppSymbol == "DiskOUT.handleEject()",
               "positive faultingThread must select the original app frame")
        expect(trace.frames == [
            "DiskOUT  DiskOUT.handleEject()",
            "libsystem_kernel.dylib  __pthread_kill",
        ], "normal frame lines must remain unchanged")
    }

    private static func testNegativeFaultingThreadFallsBackToFirstThread() throws {
        let report = try document(named: "negative-faulting-thread.ips")
        let trace = CrashReportParsing.backtrace(from: report.body, topFrameLimit: 20)

        expect(trace.topAppSymbol == "DiskOUT.firstThreadFallback()",
               "negative faultingThread must fall back to the first thread")
        expect(trace.frames == ["DiskOUT  DiskOUT.firstThreadFallback()"],
               "negative faultingThread fallback must preserve the first thread frames")
    }

    private static func testNegativeImageIndexUsesUnknownBinaryAndContinues() throws {
        let report = try document(named: "negative-image-index.ips")
        let trace = CrashReportParsing.backtrace(from: report.body, topFrameLimit: 20)

        expect(trace.topAppSymbol == "DiskOUT.validFrameAfterInvalidIndex()",
               "a later valid app frame must still become the top app symbol")
        expect(trace.frames == [
            "?  invalidImageReference",
            "DiskOUT  DiskOUT.validFrameAfterInvalidIndex()",
        ], "negative imageIndex must use an unknown binary and continue")
    }
}
