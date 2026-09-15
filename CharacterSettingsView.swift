import AppKit

/// Browsing and simulated activity stay separate from the applied menu bar selection.
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
    private let display = NSSegmentedControl(labels: [String(localized: "Numbers"), String(localized: "Characters")],
        trackingMode: .selectOne, target: nil, action: nil)
    private let series = NSPopUpButton()
    private let seriesRow = NSStackView()
    private let character = NSPopUpButton()
    private let statePicker = NSSegmentedControl(labels: [String(localized: "Resting"), String(localized: "Active"), String(localized: "Busy")],
        trackingMode: .selectOne, target: nil, action: nil)
    private let preview = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let ownershipLabel = NSTextField(labelWithString: String(localized: "Purchased"))
    private let descriptionLabel = NSTextField(wrappingLabelWithString: "")
    private let motion = NSButton(checkboxWithTitle: String(localized: "Activity-Reactive Motion"), target: nil, action: nil)
    private let useButton = NSButton(title: String(localized: "Apply to Menu Bar"), target: nil, action: nil)
    private let disclosure = NSButton(title: String(localized: "Preview Characters"), target: nil, action: nil)
    private let previewControls = NSStackView()
    private let offer = NSStackView()
    private let offerTitle = NSTextField(labelWithString: "")
    private let offerDetail = NSTextField(wrappingLabelWithString: "")
    private let purchaseButton = NSButton(title: String(localized: "Buy Pack…"), target: nil, action: nil)
    private let animator = StatusCharacterAnimator(renderSize: UI.characterPreviewSize)
    private var previewVisible = false
    private var previewExpanded = false

    init(selection: @escaping () -> CharacterSelection,
         owned: @escaping () -> Set<CharacterPack>,
         purchasable: @escaping (CharacterPack) -> Bool,
         busy: @escaping () -> Bool,
         apply: @escaping (CharacterSelection) -> Void,
         purchase: @escaping (CharacterPack) -> Void,
         layoutChanged: @escaping () -> Void = {}) {
        self.selection = selection; self.owned = owned; self.purchasable = purchasable
        self.busy = busy; self.apply = apply; self.purchase = purchase; self.layoutChanged = layoutChanged
        draft = selection(); lastSelection = draft
        super.init(frame: .zero)
        orientation = .vertical; alignment = .leading; spacing = UI.spacing
        widthAnchor.constraint(equalToConstant: UI.settingsContentWidth).isActive = true

        display.target = self; display.action = #selector(displayChanged)
        display.setAccessibilityLabel(String(localized: "Menu Bar Display"))
        addArrangedSubview(display)
        display.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
        series.addItems(withTitles: CharacterCollection.allCases.map(\.title))
        series.target = self; series.action = #selector(seriesChanged)
        series.setAccessibilityLabel(String(localized: "Character Series"))
        let seriesLabel = NSTextField(labelWithString: String(localized: "Character Series"))
        seriesLabel.font = .systemFont(ofSize: UI.bodySize)
        seriesRow.orientation = .horizontal; seriesRow.alignment = .centerY; seriesRow.spacing = UI.rowSpacing
        seriesRow.addArrangedSubview(seriesLabel); seriesRow.addArrangedSubview(series)
        addArrangedSubview(seriesRow)

        preview.imageScaling = .scaleProportionallyUpOrDown
        preview.widthAnchor.constraint(equalToConstant: UI.characterPreviewSize).isActive = true
        preview.heightAnchor.constraint(equalToConstant: UI.characterPreviewSize).isActive = true
        titleLabel.font = .systemFont(ofSize: UI.titleSize, weight: .semibold)
        descriptionLabel.font = .systemFont(ofSize: UI.bodySize)
        descriptionLabel.textColor = .secondaryLabelColor
        let textWidth = UI.settingsContentWidth - UI.cardPadding * 2 - UI.characterPreviewSize - UI.spacing
        descriptionLabel.widthAnchor.constraint(equalToConstant: textWidth).isActive = true
        let caption = NSTextField(labelWithString: String(localized: "Preview"))
        caption.font = .systemFont(ofSize: UI.captionSize); caption.textColor = .secondaryLabelColor
        ownershipLabel.font = .systemFont(ofSize: UI.captionSize)
        ownershipLabel.textColor = .secondaryLabelColor
        let titleRow = NSStackView(views: [titleLabel, ownershipLabel]); titleRow.spacing = UI.rowSpacing
        let summary = NSStackView(views: [caption, titleRow, descriptionLabel])
        summary.orientation = .vertical; summary.alignment = .leading; summary.spacing = UI.compactSpacing
        let previewRow = NSStackView(views: [preview, summary])
        previewRow.orientation = .horizontal; previewRow.spacing = UI.spacing; previewRow.alignment = .centerY
        let card = NSBox()
        card.boxType = .custom; card.titlePosition = .noTitle
        card.fillColor = .controlBackgroundColor; card.borderColor = .separatorColor
        card.cornerRadius = UI.cardCornerRadius; card.contentViewMargins = .zero
        card.contentView = NSView()
        card.contentView!.addSubview(previewRow)
        previewRow.translatesAutoresizingMaskIntoConstraints = false
        addArrangedSubview(card)
        NSLayoutConstraint.activate([
            card.widthAnchor.constraint(equalTo: widthAnchor),
            previewRow.leadingAnchor.constraint(equalTo: card.contentView!.leadingAnchor, constant: UI.cardPadding),
            previewRow.trailingAnchor.constraint(equalTo: card.contentView!.trailingAnchor, constant: -UI.cardPadding),
            previewRow.topAnchor.constraint(equalTo: card.contentView!.topAnchor, constant: UI.cardPadding),
            previewRow.bottomAnchor.constraint(equalTo: card.contentView!.bottomAnchor, constant: -UI.cardPadding),
        ])

        motion.target = self; motion.action = #selector(motionChanged)
        useButton.bezelStyle = .rounded; useButton.target = self; useButton.action = #selector(useClicked)
        useButton.setContentHuggingPriority(.required, for: .horizontal)
        let spacer = NSView()
        let actions = NSStackView(views: [motion, spacer, useButton])
        actions.orientation = .horizontal; actions.alignment = .centerY; actions.spacing = UI.rowSpacing
        addArrangedSubview(actions)
        actions.widthAnchor.constraint(equalTo: widthAnchor).isActive = true

        disclosure.isBordered = false; disclosure.imagePosition = .imageLeading
        disclosure.font = .systemFont(ofSize: UI.bodySize)
        disclosure.target = self; disclosure.action = #selector(togglePreview)
        addArrangedSubview(disclosure)
        character.target = self; character.action = #selector(previewChanged)
        character.setAccessibilityLabel(String(localized: "Preview Drive Count"))
        statePicker.selectedSegment = 1; statePicker.target = self; statePicker.action = #selector(previewChanged)
        statePicker.setAccessibilityLabel(String(localized: "Preview Activity"))
        previewControls.orientation = .vertical; previewControls.alignment = .leading; previewControls.spacing = UI.rowSpacing
        let controls = NSStackView(views: [character, statePicker]); controls.spacing = UI.rowSpacing
        previewControls.addArrangedSubview(controls)
        let note = NSTextField(wrappingLabelWithString: String(localized: "Preview only. Resting does not mean a drive is ejected."))
        note.font = .systemFont(ofSize: UI.captionSize); note.textColor = .secondaryLabelColor
        previewControls.addArrangedSubview(note)
        addArrangedSubview(previewControls)
        note.widthAnchor.constraint(equalTo: widthAnchor).isActive = true

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

        animator.onFrameChanged = { [weak self] in self?.preview.image = self?.animator.currentImage() }
        synchronizeControls()
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil || !previewVisible { animator.setActive(false) } else { updatePreview() }
    }
    func setPreviewVisible(_ visible: Bool) {
        previewVisible = visible
        if visible { updatePreview() } else { animator.setActive(false) }
    }

    func refresh() {
        let current = selection()
        // Entitlement changes can correct the applied selection. Ordinary status refreshes
        // must not discard the collection or motion the user is currently browsing.
        if current != lastSelection {
            lastSelection = current; draft = current
            synchronizeControls()
        }
        let numbers = draft.display == .numbers
        seriesRow.isHidden = numbers
        motion.isHidden = numbers
        disclosure.isHidden = numbers
        previewControls.isHidden = numbers || !previewExpanded
        statePicker.isEnabled = motion.state == .on
        disclosure.image = NSImage(systemSymbolName: previewExpanded ? "chevron.down" : "chevron.right", accessibilityDescription: nil)
        let pack = draft.collection.motionPack
        ownershipLabel.isHidden = numbers || draft.collection == .basic || !owned().contains(pack)
        offer.isHidden = numbers || owned().contains(pack)
        offerTitle.stringValue = pack == .baseMotion ? String(localized: "Premium Motion") : String(localized: "Halloween Pack")
        offerDetail.stringValue = pack == .baseMotion
            ? String(localized: "Rest, walk, and speed up with drive activity.")
            : String(localized: "10 characters with motion, available year-round.")
        purchaseButton.title = purchasable(pack) ? "USD $\(pack.priceUSD) · \(String(localized: "Buy Pack…"))" : String(localized: "Coming Soon")
        purchaseButton.toolTip = String(localized: "One-Time Purchase")
        purchaseButton.isEnabled = purchasable(pack) && !owned().contains(pack) && !busy()
        let applied = numbers ? current.display == .numbers : draft == current
        useButton.title = applied ? String(localized: "Applied") : String(localized: "Apply to Menu Bar")
        let allowed = numbers || (draft.collection == .basic
            ? (!draft.basicReactive || owned().contains(.baseMotion)) : owned().contains(.halloween))
        useButton.isEnabled = allowed && !applied
        updatePreview()
    }

    private func synchronizeControls() {
        display.selectedSegment = draft.display == .numbers ? 0 : 1
        series.selectItem(at: CharacterCollection.allCases.firstIndex(of: draft.collection) ?? 0)
        motion.state = (draft.collection == .basic ? draft.basicReactive : draft.halloweenAnimated) ? .on : .off
        populateCharacters()
    }

    private func populateCharacters() {
        character.removeAllItems()
        if draft.collection == .basic {
            for index in 0...12 { character.addItem(withTitle: String(localized: "Drive Count: \(index)")) }
            character.selectItem(at: 2)
        } else {
            character.addItems(withTitles: HalloweenCharacter.allCases.map(\.previewTitle))
            character.selectItem(at: 0)
        }
    }

    @objc private func displayChanged() {
        draft.display = display.selectedSegment == 0 ? .numbers : .characters
        synchronizeControls(); refresh(); layoutChanged()
    }
    @objc private func seriesChanged() {
        guard CharacterCollection.allCases.indices.contains(series.indexOfSelectedItem) else { return }
        draft.collection = CharacterCollection.allCases[series.indexOfSelectedItem]
        synchronizeControls(); refresh(); layoutChanged()
    }
    @objc private func motionChanged() {
        if draft.collection == .basic { draft.basicReactive = motion.state == .on }
        else { draft.halloweenAnimated = motion.state == .on }
        refresh(); layoutChanged()
    }
    @objc private func togglePreview() {
        previewExpanded.toggle(); refresh(); layoutChanged()
    }
    @objc private func previewChanged() { updatePreview() }

    private func updatePreview() {
        let numbers = draft.display == .numbers
        titleLabel.stringValue = numbers ? String(localized: "Numbers")
            : draft.collection.title
        descriptionLabel.stringValue = numbers ? String(localized: "Show the number of connected drives.")
            : (draft.collection == .basic ? String(localized: "13 free characters that follow your drive count.")
                : String(localized: "10 Halloween characters that follow your drive count."))
        if numbers {
            animator.setActive(false)
            preview.image = NSImage(systemSymbolName: "2.circle", accessibilityDescription: String(localized: "Numbers"))
            preview.setAccessibilityLabel(String(localized: "Numbers")); preview.setAccessibilityValue("2")
            return
        }
        let states: [CharacterMotionState] = [.rest, .active, .busy]
        let state = states[max(0, min(2, statePicker.selectedSegment))]
        let visual: CharacterVisual = draft.collection == .basic
            ? .basic(count: max(0, min(12, character.indexOfSelectedItem)), reactive: draft.basicReactive)
            : .halloween(HalloweenCharacter.allCases[max(0, min(9, character.indexOfSelectedItem))], animated: draft.halloweenAnimated)
        animator.configure(visual: visual, state: state)
        preview.image = animator.currentImage()
        preview.setAccessibilityLabel(character.titleOfSelectedItem ?? "DiskOUT")
        preview.setAccessibilityValue(state.title)
        if window == nil || !previewVisible { animator.setActive(false) }
    }

    @objc private func useClicked() {
        var value = selection()
        if draft.display == .numbers {
            value.display = .numbers
        } else {
            guard draft.collection == .basic
                ? (!draft.basicReactive || owned().contains(.baseMotion)) : owned().contains(.halloween) else { return }
            value = draft
        }
        apply(value); refresh(); layoutChanged()
    }

    @objc private func buyClicked() {
        let pack = draft.collection.motionPack
        guard draft.display == .characters, purchasable(pack), !owned().contains(pack), !busy() else { return }
        purchase(pack); refresh(); layoutChanged()
    }
}
