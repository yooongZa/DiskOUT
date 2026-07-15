import Foundation

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

@main
private enum DiskClassificationPolicyTests {
    static func main() {
        expect(ExternalMediaPolicy.shouldInclude(
            isInternal: false,
            busProtocol: "USB",
            isRemovable: false,
            isEjectable: true
        ), "external SSD remains included")

        expect(ExternalMediaPolicy.shouldInclude(
            isInternal: false,
            busProtocol: "Thunderbolt",
            isRemovable: nil,
            isEjectable: nil
        ), "external media remains included when optional flags are missing")

        expect(ExternalMediaPolicy.shouldInclude(
            isInternal: true,
            busProtocol: "Secure Digital",
            isRemovable: true,
            isEjectable: true
        ), "built-in SDXC reader media is included")

        expect(ExternalMediaPolicy.shouldInclude(
            isInternal: true,
            busProtocol: "Secure Digital",
            isRemovable: false,
            isEjectable: true
        ), "ejectable SD media is included when removable is false")

        expect(!ExternalMediaPolicy.shouldInclude(
            isInternal: true,
            busProtocol: "PCI",
            isRemovable: false,
            isEjectable: false
        ), "internal SSD remains excluded")

        expect(!ExternalMediaPolicy.shouldInclude(
            isInternal: true,
            busProtocol: "PCI",
            isRemovable: true,
            isEjectable: true
        ), "non-SD internal media remains excluded even with removable flags")

        expect(!ExternalMediaPolicy.shouldInclude(
            isInternal: true,
            busProtocol: "Secure Digital",
            isRemovable: false,
            isEjectable: false
        ), "non-removable Secure Digital device remains excluded")

        expect(!ExternalMediaPolicy.shouldInclude(
            isInternal: true,
            busProtocol: nil,
            isRemovable: nil,
            isEjectable: nil
        ), "internal media with missing attributes fails closed")

        print("DiskClassificationPolicyTests: PASS")
    }
}
