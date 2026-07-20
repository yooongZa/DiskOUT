import Foundation

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

@main
private enum StatusItemPresentationPolicyTests {
    static func main() {
        expect(PremiumRuntimeMode.hasPresentationAccess(verifiedBillingAccess: true),
               "a verified signed lease opens the Premium presentation in every build")
#if DISKOUT_PREMIUM_PREVIEW
        expect(PremiumRuntimeMode.hasPresentationAccess(verifiedBillingAccess: false),
               "the explicit local Preview build opens the character presentation")
#else
        expect(!PremiumRuntimeMode.hasPresentationAccess(verifiedBillingAccess: false),
               "a normal build fails closed without verified billing access")
#endif

        var assetLookups: [Int] = []
        let freeZero = StatusItemPresentationPolicy.presentation(
            count: 0,
            premiumState: .free,
            hasCharacterAsset: { assetLookups.append($0); return true }
        )
        expect(freeZero == StatusItemPresentation(visual: .freeGlyph, countTitle: ""),
               "free zero preserves the existing glyph with no title")
        expect(assetLookups.isEmpty, "free access does not consult Premium assets")

        let freePositive = StatusItemPresentationPolicy.presentation(
            count: 4,
            premiumState: .free,
            hasCharacterAsset: { _ in true }
        )
        expect(freePositive == StatusItemPresentation(visual: .freeGlyph, countTitle: "4"),
               "free positive count preserves the existing title")

        let unverified = StatusItemPresentationPolicy.presentation(
            count: 7,
            premiumState: .unverified,
            hasCharacterAsset: { _ in true }
        )
        expect(unverified == StatusItemPresentation(visual: .freeGlyph, countTitle: "7"),
               "unverified Premium access fails closed to the free presentation")

        let premiumZero = StatusItemPresentationPolicy.presentation(
            count: 0,
            premiumState: .verified,
            hasCharacterAsset: { $0 == 0 }
        )
        expect(premiumZero == StatusItemPresentation(visual: .premiumCharacter(count: 0), countTitle: "0"),
               "Premium zero shows its character and an explicit right-side zero")

        let premiumTwelve = StatusItemPresentationPolicy.presentation(
            count: 12,
            premiumState: .verified,
            hasCharacterAsset: { $0 == 12 }
        )
        expect(premiumTwelve == StatusItemPresentation(visual: .premiumCharacter(count: 12), countTitle: "12"),
               "Premium character range includes twelve")

        let missingAsset = StatusItemPresentationPolicy.presentation(
            count: 6,
            premiumState: .verified,
            hasCharacterAsset: { _ in false }
        )
        expect(missingAsset == StatusItemPresentation(visual: .freeGlyph, countTitle: "6"),
               "missing character asset falls back to the free presentation")

        var outOfRangeAssetWasRead = false
        let thirteen = StatusItemPresentationPolicy.presentation(
            count: 13,
            premiumState: .verified,
            hasCharacterAsset: { _ in outOfRangeAssetWasRead = true; return true }
        )
        expect(thirteen == StatusItemPresentation(visual: .freeGlyph, countTitle: "13"),
               "count thirteen falls back to the unlimited free title")
        expect(!outOfRangeAssetWasRead, "out-of-range count does not consult character assets")

        let negative = StatusItemPresentationPolicy.presentation(
            count: -1,
            premiumState: .verified,
            hasCharacterAsset: { _ in true }
        )
        expect(negative == StatusItemPresentation(visual: .freeGlyph, countTitle: ""),
               "invalid negative count fails closed without a misleading title")

        print("StatusItemPresentationPolicyTests: PASS")
    }
}
