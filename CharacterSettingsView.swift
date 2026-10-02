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
    private let effectiveSelection: (() -> CharacterSelection)?
    private let trialStatus: (CharacterPack) -> CharacterTrialStatus
    private let startTrial: (CharacterPack) -> Void
    private let endTrial: () -> Void
    private let announcementsEnabled: () -> Bool
    private let setAnnouncementsEnabled: (Bool) -> Void
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
    private let trialRow = NSStackView()
    private let trialTitle = NSTextField(labelWithString: "")
    private let trialDetail = NSTextField(wrappingLabelWithString: "")
    private let trialButton = NSButton()
    private let announcementToggle = NSButton(checkboxWithTitle: String(localized: "Show new character announcements"),
                                              target: nil, action: nil)
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
         effectiveSelection: (() -> CharacterSelection)? = nil,
         trialStatus: @escaping (CharacterPack) -> CharacterTrialStatus = { _ in .unavailable },
         startTrial: @escaping (CharacterPack) -> Void = { _ in },
         endTrial: @escaping () -> Void = {},
         announcementsEnabled: @escaping () -> Bool = { true },
         setAnnouncementsEnabled: @escaping (Bool) -> Void = { _ in },
         layoutChanged: @escaping () -> Void = {}) {
        self.selection = selection; self.owned = owned; self.purchasable = purchasable
        self.busy = busy; self.apply = apply; self.purchase = purchase; self.layoutChanged = layoutChanged
        self.effectiveSelection = effectiveSelection; self.trialStatus = trialStatus
        self.startTrial = startTrial; self.endTrial = endTrial
        self.announcementsEnabled = announcementsEnabled; self.setAnnouncementsEnabled = setAnnouncementsEnabled
        draft = effectiveSelection?() ?? selection(); lastSelection = selection(); lastOwned = owned()
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

        trialTitle.font = .systemFont(ofSize: UI.bodySize, weight: .medium)
        trialDetail.font = .systemFont(ofSize: UI.captionSize); trialDetail.textColor = .secondaryLabelColor
        trialDetail.widthAnchor.constraint(equalToConstant: UI.characterOfferTextWidth).isActive = true
        let trialText = NSStackView(views: [trialTitle, trialDetail])
        trialText.orientation = .vertical; trialText.alignment = .leading; trialText.spacing = UI.compactSpacing
        trialButton.bezelStyle = .rounded; trialButton.target = self; trialButton.action = #selector(trialClicked)
        trialButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        trialRow.orientation = .horizontal; trialRow.alignment = .centerY; trialRow.spacing = UI.rowSpacing
        trialRow.addArrangedSubview(trialText); trialRow.addArrangedSubview(NSView()); trialRow.addArrangedSubview(trialButton)
        addArrangedSubview(trialRow)
        trialRow.widthAnchor.constraint(equalTo: widthAnchor).isActive = true

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
        announcementToggle.font = .systemFont(ofSize: UI.captionSize)
        announcementToggle.target = self; announcementToggle.action = #selector(announcementPreferenceChanged)
        addArrangedSubview(announcementToggle)
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

    func preview(collection: CharacterCollection) {
        draft = CharacterSelection(display: .characters, collection: collection)
        refresh(); layoutChanged()
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
        let displayed = effectiveSelection?() ?? current
        let activeTrial = displayed.collection.paidPack.map { pack -> Bool in
            if case .active = trialStatus(pack) { return true }
            return false
        } ?? false
        let activeCollection = displayed.collection.paidPack.map { !packs.contains($0) && !activeTrial } == true
            ? CharacterCollection.basic : displayed.collection
        let activeTitle = displayed.display == .numbers ? String(localized: "Numbers") : activeCollection.title
        appliedStatusLabel.stringValue = String(localized: "Using: \(activeTitle)")
            + (activeTrial ? " · " + String(localized: "Trial") : "")
        announcementToggle.state = announcementsEnabled() ? .on : .off
        trialRow.isHidden = true
        if let pack = draft.collection.paidPack, !numbers, !packs.contains(pack) {
            offer.isHidden = false
            offerTitle.stringValue = draft.collection.title
            purchaseButton.title = purchasable(pack) ? "USD $\(pack.priceUSD) · \(String(localized: "Buy Pack…"))" : String(localized: "Coming Soon")
            purchaseButton.toolTip = String(localized: "One-Time Purchase")
            purchaseButton.isEnabled = purchasable(pack) && !busy()
        } else { offer.isHidden = true }
        let trialPack = activeTrialPack ?? (numbers ? nil : draft.collection.paidPack)
        if let pack = trialPack, !packs.contains(pack) {
            switch trialStatus(pack) {
            case .unavailable: break
            case .available:
                trialRow.isHidden = false
                trialTitle.stringValue = String(localized: "3-Day Menu Bar Trial")
                trialDetail.stringValue = String(localized: "Your previous selection returns when the trial ends.")
                trialButton.title = String(localized: "Try for 3 Days")
                trialButton.isEnabled = !busy()
            case .active(let until):
                trialRow.isHidden = false
                trialTitle.stringValue = String(localized: "Trying These Characters")
                let date = DateFormatter.localizedString(from: until, dateStyle: .medium, timeStyle: .short)
                trialDetail.stringValue = String(localized: "Trial ends \(date)")
                trialButton.title = String(localized: "End Trial")
                trialButton.isEnabled = true
            case .ended:
                trialRow.isHidden = false
                trialTitle.stringValue = String(localized: "Trial Finished")
                trialDetail.stringValue = String(localized: "This pack's 3-day trial has ended.")
                trialButton.title = String(localized: "Trial Used")
                trialButton.isEnabled = false
            }
        }
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

    private var activeTrialPack: CharacterPack? {
        CharacterPack.allCases.first { pack in
            if case .active = trialStatus(pack) { return true }
            return false
        }
    }

    @objc private func trialClicked() {
        guard let pack = activeTrialPack ?? draft.collection.paidPack else { return }
        switch trialStatus(pack) {
        case .available where !busy(): startTrial(pack)
        case .active: endTrial()
        default: return
        }
        refresh(); layoutChanged()
    }

    @objc private func announcementPreferenceChanged() {
        setAnnouncementsEnabled(announcementToggle.state == .on)
    }

    deinit {
        if let windowObserver { NotificationCenter.default.removeObserver(windowObserver) }
    }
}
