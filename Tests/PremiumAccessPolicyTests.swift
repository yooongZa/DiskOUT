import Foundation

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

@main
private enum PremiumAccessPolicyTests {
    private static let now = Date(timeIntervalSince1970: 2_000_000_000)

    private static func payload(
        schemaVersion: Int = 2,
        status: PremiumEntitlementStatus = .active,
        installID: String = "this-install",
        priceID: String = "pri_abcdefghijklmnopqrstuvwxyz",
        entitlement: String = "perpetual",
        issuedAt: Date = now,
        expiresAt: Date? = nil
    ) -> PremiumAccessPayload {
        let defaultDuration = status == .active ? 30 * 24 * 60 * 60 : 15 * 60
        return PremiumAccessPayload(
            schemaVersion: schemaVersion,
            installID: installID,
            status: status,
            priceID: priceID,
            entitlement: entitlement,
            issuedAt: issuedAt,
            expiresAt: expiresAt ?? now.addingTimeInterval(TimeInterval(defaultDuration))
        )
    }

    private static func grants(_ payload: PremiumAccessPayload) -> Bool {
        PremiumAccessPolicy.grantsPremium(
            payload: payload,
            expectedInstallID: "this-install",
            expectedPriceID: "pri_abcdefghijklmnopqrstuvwxyz",
            now: now
        )
    }

    private static func accepts(_ payload: PremiumAccessPayload) -> Bool {
        PremiumAccessPolicy.acceptsLease(
            payload: payload,
            expectedInstallID: "this-install",
            expectedPriceID: "pri_abcdefghijklmnopqrstuvwxyz",
            now: now
        )
    }

    static func main() throws {
        expect(grants(payload(status: .active)), "active one-time entitlement grants access")

        for status in [
            PremiumEntitlementStatus.free,
            .refunded,
            .chargeback,
            .suspended,
            .revoked,
            .unknown("new_worker_state"),
        ] {
            expect(!grants(payload(status: status)), "\(status) denies access")
            expect(accepts(payload(status: status)), "\(status) denial is cacheable for 15 minutes")
        }

        expect(!accepts(payload(schemaVersion: 1)), "legacy schema fails closed")
        expect(!grants(payload(installID: "another-install")),
               "lease is bound to the expected install")
        expect(!accepts(payload(installID: "another-install")),
               "another installation is not an acceptable lease")
        expect(!grants(payload(priceID: "pri_another_product")),
               "lease is bound to the configured one-time price")
        expect(!grants(payload(entitlement: "subscription")),
               "non-perpetual entitlement fails closed")
        expect(grants(payload(issuedAt: now.addingTimeInterval(5 * 60))),
               "issued-at exactly five minutes ahead is within clock skew")
        expect(!grants(payload(issuedAt: now.addingTimeInterval(5 * 60 + 0.001))),
               "issued-at beyond five minutes ahead is rejected")
        expect(grants(payload(expiresAt: now.addingTimeInterval(0.001))),
               "lease grants access immediately before expiry")
        expect(!grants(payload(expiresAt: now)),
               "lease denies access at the exact expiry instant")
        expect(!grants(payload(expiresAt: now.addingTimeInterval(-0.001))),
               "expired lease denies access")
        expect(accepts(payload(expiresAt: now.addingTimeInterval(30 * 24 * 60 * 60))),
               "an active lease at the 30-day server limit is accepted")
        expect(!accepts(payload(expiresAt: now.addingTimeInterval(30 * 24 * 60 * 60 + 0.001))),
               "an active lease beyond 30 days is rejected")
        expect(accepts(payload(status: .refunded, expiresAt: now.addingTimeInterval(15 * 60))),
               "a denial lease at the 15-minute server limit is accepted")
        expect(!accepts(payload(status: .refunded,
                                expiresAt: now.addingTimeInterval(15 * 60 + 0.001))),
               "a denial lease beyond 15 minutes is rejected")
        expect(!accepts(payload(issuedAt: now.addingTimeInterval(60), expiresAt: now.addingTimeInterval(60))),
               "a zero-length lease is rejected")

        let encoder = JSONEncoder()
        let encoded = try encoder.encode(payload(status: .active))
        let object = try JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        expect(object?["schema_version"] as? Int == 2, "payload encodes schema_version")
        expect(object?["install_id"] as? String == "this-install", "payload encodes install_id")
        expect(object?["price_id"] as? String == "pri_abcdefghijklmnopqrstuvwxyz", "payload encodes price_id")
        expect(object?["entitlement"] as? String == "perpetual", "payload encodes perpetual entitlement")
        expect(object?["status"] as? String == "active", "payload encodes normalized active status")
        expect(object?["issued_at"] != nil && object?["expires_at"] != nil,
               "payload encodes snake-case lease timestamps")
        expect(object?["installID"] == nil && object?["priceID"] == nil,
               "payload does not leak camel-case wire keys")

        let unknownJSON = """
        {
          "schema_version": 2,
          "install_id": "this-install",
          "status": "new_paddle_state",
          "price_id": "pri_abcdefghijklmnopqrstuvwxyz",
          "entitlement": "perpetual",
          "issued_at": 0,
          "expires_at": 60
        }
        """.data(using: .utf8)!
        let decodedUnknown = try JSONDecoder().decode(PremiumAccessPayload.self, from: unknownJSON)
        expect(decodedUnknown.status == .unknown("new_paddle_state"),
               "unknown Paddle status decodes without losing its wire value")
        expect(!PremiumAccessPolicy.grantsPremium(
            payload: decodedUnknown,
            expectedInstallID: "this-install",
            expectedPriceID: "pri_abcdefghijklmnopqrstuvwxyz",
            now: Date(timeIntervalSinceReferenceDate: 1)
        ), "decoded unknown status fails closed")

        let legacyJSON = """
        {
          "install_id": "this-install",
          "status": "active",
          "annual_price_id": "pri_annual_999",
          "issued_at": 0,
          "expires_at": 60
        }
        """.data(using: .utf8)!
        expect((try? JSONDecoder().decode(PremiumAccessPayload.self, from: legacyJSON)) == nil,
               "legacy annual payload cannot decode as a v2 perpetual entitlement")

        print("PremiumAccessPolicyTests: PASS")
    }
}
