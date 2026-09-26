import AppKit

/// Browsing an unowned seasonal pack never changes the applied menu bar selection.
final class CharacterSettingsView: NSStackView {
    private let selection: () -> CharacterSelection
    private let owned: () -> Set<CharacterPack>
    private let purchasable: (CharacterPack) -> Bool
    private let busy: () -> Bool
    private let apply: (CharacterSelection) -> Void
    private let purchase: (CharacterPack) -> Void
    private let layoutChanged: () -> Void
    private var draft: CharacterSelection
    private var lastSelection: CharacterSelection
    private var lastOwned: Set<CharacterPack>
    private let series = NSPopUpButton()
    private let gallery = NSStackView()
    private let previews = (0..<CharacterPreviewTimeline.characterCount).map { _ in NSImageView() }
    private let numberPreview = NSTextField(labelWithString: "2")
    private let descriptionLabel = NSTextField(wrappingLabelWithString: "")
    private let offer = NSStackView()
    private let offerTitle = NSTextField(labelWithString: "")
    private let offerDetail = NSTextField(wrappingLabelWithString: String(localized: "10 seasonal characters. One-time purchase, yours year-round."))
    private let purchaseButton = NSButton(title: String(localized: "Buy Pack…"), target: nil, action: nil)
    private let animator = CharacterGalleryAnimator(renderSize: UI.characterPreviewSize)
    private var previewVisible = false
    private var windowObserver: NSObjectProtocol?
    let appliedStatusLabel = NSTextField(labelWithString: "")

    init(selection: @escaping () -> CharacterSelection,
         owned: @escaping () -> Set<CharacterPack>,
         purchasable: @escaping (CharacterPack) -> Bool,
         busy: @escaping () -> Bool,
         apply: @escaping (CharacterSelection) -> Void,
         purchase: @escaping (CharacterPack) -> Void,
         layoutChanged: @escaping () -> Void = {}) {
        self.selection = selection; self.owned = owned; self.purchasable = purchasable
        self.busy = busy; self.apply = apply; self.purchase = purchase; self.layoutChanged = layoutChanged
        draft = selection(); lastSelection = draft; lastOwned = owned()
        super.init(frame: .zero)
        orientation = .vertical; alignment = .leading; spacing = UI.spacing
        widthAnchor.constraint(equalToConstant: UI.settingsContentWidth).isActive = true

        series.addItem(withTitle: String(localized: "Numbers"))
        series.addItems(withTitles: CharacterCollection.allCases.map(\.title))
        series.target = self; series.action = #selector(seriesChanged)
        series.setAccessibilityLabel(String(localized: "Characters"))
        let seriesLabel = NSTextField(labelWithString: String(localized: "Characters"))
        seriesLabel.font = .systemFont(ofSize: UI.bodySize)
        let seriesRow = NSStackView(views: [seriesLabel, NSView(), series])
        seriesRow.orientation = .horizontal; seriesRow.alignment = .centerY; seriesRow.spacing = UI.rowSpacing
        addArrangedSubview(seriesRow)
        seriesRow.widthAnchor.constraint(equalTo: widthAnchor).isActive = true

        let caption = NSTextField(labelWithString: String(localized: "Preview"))
        caption.font = .systemFont(ofSize: UI.captionSize); caption.textColor = .secondaryLabelColor
        caption.alignment = .center
        addArrangedSubview(caption)
        caption.widthAnchor.constraint(equalTo: widthAnchor).isActive = true

        gallery.orientation = .vertical; gallery.alignment = .centerX; gallery.spacing = UI.spacing
        for start in stride(from: 0, to: previews.count, by: 5) {
            let row = NSStackView(views: Array(previews[start..<(start + 5)]))
            row.orientation = .horizontal; row.distribution = .fillEqually; row.spacing = UI.rowSpacing
            gallery.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: gallery.widthAnchor).isActive = true
        }
        for preview in previews {
            preview.imageScaling = .scaleNone
            preview.contentTintColor = .labelColor
            preview.heightAnchor.constraint(equalToConstant: UI.characterPreviewSize + UI.cardPadding).isActive = true
        }
        addArrangedSubview(gallery)
        gallery.widthAnchor.constraint(equalTo: widthAnchor).isActive = true

        numberPreview.font = .monospacedDigitSystemFont(ofSize: NSFont.menuBarFont(ofSize: 0).pointSize, weight: .regular)
        numberPreview.alignment = .center
        numberPreview.setAccessibilityLabel(String(localized: "Numbers"))
        addArrangedSubview(numberPreview)
        numberPreview.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
        numberPreview.heightAnchor.constraint(equalToConstant: UI.characterPreviewSize * 2 + UI.cardPadding * 2 + UI.spacing).isActive = true

        descriptionLabel.font = .systemFont(ofSize: UI.captionSize)
        descriptionLabel.textColor = .secondaryLabelColor; descriptionLabel.alignment = .center
        addArrangedSubview(descriptionLabel)
        descriptionLabel.widthAnchor.constraint(equalTo: widthAnchor).isActive = true

        offerTitle.font = .systemFont(ofSize: UI.bodySize, weight: .semibold)
        offerDetail.font = .systemFont(ofSize: UI.captionSize); offerDetail.textColor = .secondaryLabelColor
        offerDetail.widthAnchor.constraint(equalToConstant: UI.characterOfferTextWidth).isActive = true
        let offerText = NSStackView(views: [offerTitle, offerDetail])
        offerText.orientation = .vertical; offerText.alignment = .leading; offerText.spacing = UI.compactSpacing
        purchaseButton.bezelStyle = .rounded; purchaseButton.target = self; purchaseButton.action = #selector(buyClicked)
        purchaseButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        offer.orientation = .horizontal; offer.alignment = .centerY; offer.spacing = UI.rowSpacing
        offer.addArrangedSubview(offerText); offer.addArrangedSubview(NSView()); offer.addArrangedSubview(purchaseButton)
        addArrangedSubview(offer)
        offer.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
        appliedStatusLabel.font = .systemFont(ofSize: UI.captionSize)
        appliedStatusLabel.textColor = .secondaryLabelColor

        animator.onFramesChanged = { [weak self] images in
            guard let self else { return }
            for (preview, image) in zip(self.previews, images) { preview.image = image }
        }
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let windowObserver { NotificationCenter.default.removeObserver(windowObserver) }
        windowObserver = nil
        if let window {
            windowObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main
            ) { [weak self] _ in self?.updatePlayback() }
        }
        updatePlayback()
    }

    func setPreviewVisible(_ visible: Bool) {
        previewVisible = visible
        updatePlayback()
    }

    private func updatePlayback() {
        animator.setActive(previewVisible && draft.display == .characters && window?.occlusionState.contains(.visible) == true)
    }

    func refresh() {
        var current = selection()
        let packs = owned()
        let newlyOwned = packs.subtracting(lastOwned)
        lastOwned = packs
        // Apply a just-purchased pack only while it is still the user's selected preview.
        // Record ownership first because applying can synchronously refresh the settings again.
        if current == lastSelection, draft.display == .characters,
           let pack = draft.collection.paidPack, newlyOwned.contains(pack) {
            apply(draft)
            current = selection()
        }
        if current != lastSelection {
            lastSelection = current; draft = current
        }
        let numbers = draft.display == .numbers
        series.selectItem(at: numbers ? 0 : (CharacterCollection.allCases.firstIndex(of: draft.collection) ?? 0) + 1)
        gallery.isHidden = numbers; numberPreview.isHidden = !numbers
        descriptionLabel.stringValue = numbers ? String(localized: "Show the number of connected drives.")
            : String(localized: "Preview shows characters sleeping and moving. In the menu bar, characters respond to drive activity.")
        let activeCollection = current.collection.paidPack.map { packs.contains($0) } == false ? CharacterCollection.basic : current.collection
        let activeTitle = current.display == .numbers ? String(localized: "Numbers") : activeCollection.title
        appliedStatusLabel.stringValue = String(localized: "Using: \(activeTitle)")
        if let pack = draft.collection.paidPack, !numbers, !packs.contains(pack) {
            offer.isHidden = false
            offerTitle.stringValue = draft.collection.title
            purchaseButton.title = purchasable(pack) ? "USD $\(pack.priceUSD) · \(String(localized: "Buy Pack…"))" : String(localized: "Coming Soon")
            purchaseButton.toolTip = String(localized: "One-Time Purchase")
            purchaseButton.isEnabled = purchasable(pack) && !busy()
        } else { offer.isHidden = true }
        for (index, preview) in previews.enumerated() {
            // Counts remain available to VoiceOver without cluttering the visual gallery.
            preview.setAccessibilityLabel(draft.collection == .basic
                ? String(localized: "Drive Count: \(index)") : HalloweenCharacter.allCases[index].previewTitle)
        }
        animator.configure(collection: draft.collection)
        updatePlayback()
    }

    @objc private func seriesChanged() {
        let index = series.indexOfSelectedItem
        if index == 0 {
            draft = selection(); draft.display = .numbers
        } else {
            guard CharacterCollection.allCases.indices.contains(index - 1) else { return }
            draft.display = .characters; draft.collection = CharacterCollection.allCases[index - 1]
        }
        if draft.display == .numbers || draft.collection.paidPack.map({ owned().contains($0) }) != false {
            apply(draft)
        }
        refresh(); layoutChanged()
    }

    @objc private func buyClicked() {
        guard draft.display == .characters, let pack = draft.collection.paidPack,
              purchasable(pack), !owned().contains(pack), !busy() else { return }
        purchase(pack); refresh(); layoutChanged()
    }

    deinit {
        if let windowObserver { NotificationCenter.default.removeObserver(windowObserver) }
    }
}
