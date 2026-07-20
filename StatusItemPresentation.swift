//
//  StatusItemPresentation.swift
//  DiskOUT
//
//  메뉴바의 무료 글리프와 Premium 캐릭터 표시를 결정하는 순수 정책.
//

import Foundation

/// Local demo builds may open only the Premium status-item presentation without changing
/// Paddle entitlement verification. Normal builds remain fail-closed unless a signed lease
/// has been verified by `PaddleBillingController`.
enum PremiumRuntimeMode {
    static func hasPresentationAccess(verifiedBillingAccess: Bool) -> Bool {
#if DISKOUT_PREMIUM_PREVIEW
        true
#else
        verifiedBillingAccess
#endif
    }
}

enum PremiumVerificationState: Equatable {
    case free
    case unverified
    case verified
}

enum StatusItemVisual: Equatable {
    /// 기존 무료 버전의 eject 글리프를 그대로 사용한다.
    case freeGlyph
    /// 해당 count 의 Premium 캐릭터 asset 을 사용한다.
    case premiumCharacter(count: Int)
}

struct StatusItemPresentation: Equatable {
    let visual: StatusItemVisual
    /// 캐릭터/글리프 오른쪽에 표시할 숫자. 무료 상태의 0은 기존처럼 생략한다.
    let countTitle: String
}

enum StatusItemPresentationPolicy {
    static let characterCountRange = 0...12

    static func presentation(
        count: Int,
        premiumState: PremiumVerificationState,
        hasCharacterAsset: (Int) -> Bool
    ) -> StatusItemPresentation {
        guard premiumState == .verified,
              characterCountRange.contains(count),
              hasCharacterAsset(count) else {
            return freePresentation(count: count)
        }

        return StatusItemPresentation(
            visual: .premiumCharacter(count: count),
            countTitle: String(count)
        )
    }

    private static func freePresentation(count: Int) -> StatusItemPresentation {
        StatusItemPresentation(
            visual: .freeGlyph,
            countTitle: count > 0 ? String(count) : ""
        )
    }
}
