//
//  PremiumAccessPolicy.swift
//  DiskOUT
//
//  서명 검증을 마치고 decode 된 Paddle one-time entitlement lease 의 접근 허용 정책.
//

import Foundation

enum PremiumEntitlementStatus: Equatable, Codable {
    case active
    case free
    case refunded
    case chargeback
    case suspended
    case revoked
    case unknown(String)

    private var wireValue: String {
        switch self {
        case .active: return "active"
        case .free: return "free"
        case .refunded: return "refunded"
        case .chargeback: return "chargeback"
        case .suspended: return "suspended"
        case .revoked: return "revoked"
        case .unknown(let value): return value
        }
    }

    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        switch value {
        case "active": self = .active
        case "free": self = .free
        case "refunded": self = .refunded
        case "chargeback": self = .chargeback
        case "suspended": self = .suspended
        case "revoked": self = .revoked
        default: self = .unknown(value)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(wireValue)
    }
}

struct PremiumAccessPayload: Equatable, Codable {
    let schemaVersion: Int
    let installID: String
    let status: PremiumEntitlementStatus
    let priceID: String
    let entitlement: String
    let issuedAt: Date
    let expiresAt: Date

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case installID = "install_id"
        case status
        case priceID = "price_id"
        case entitlement
        case issuedAt = "issued_at"
        case expiresAt = "expires_at"
    }
}

enum PremiumAccessPolicy {
    static let supportedSchemaVersion = 2
    static let perpetualEntitlement = "perpetual"
    static let maximumFutureIssuedAtSkew: TimeInterval = 5 * 60
    static let maximumPositiveLeaseDuration: TimeInterval = 30 * 24 * 60 * 60
    static let maximumDeniedLeaseDuration: TimeInterval = 15 * 60

    /// A cryptographically valid envelope is usable only when it is bound to this app
    /// installation and configured price, and its lease window is currently valid.
    static func acceptsLease(
        payload: PremiumAccessPayload,
        expectedInstallID: String,
        expectedPriceID: String,
        now: Date = Date()
    ) -> Bool {
        let leaseDuration = payload.expiresAt.timeIntervalSince(payload.issuedAt)
        let maximumLeaseDuration = payload.status == .active
            ? maximumPositiveLeaseDuration
            : maximumDeniedLeaseDuration
        return payload.schemaVersion == supportedSchemaVersion &&
            payload.installID == expectedInstallID &&
            payload.priceID == expectedPriceID &&
            payload.entitlement == perpetualEntitlement &&
            payload.issuedAt.timeIntervalSince(now) <= maximumFutureIssuedAtSkew &&
            leaseDuration > 0 &&
            leaseDuration <= maximumLeaseDuration &&
            now < payload.expiresAt
    }

    static func grantsPremium(
        payload: PremiumAccessPayload,
        expectedInstallID: String,
        expectedPriceID: String,
        now: Date = Date()
    ) -> Bool {
        guard acceptsLease(
            payload: payload,
            expectedInstallID: expectedInstallID,
            expectedPriceID: expectedPriceID,
            now: now
        ) else {
            return false
        }

        switch payload.status {
        case .active:
            return true
        case .free, .refunded, .chargeback, .suspended, .revoked, .unknown:
            return false
        }
    }
}
