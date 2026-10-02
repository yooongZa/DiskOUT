import AppKit

private final class CharacterAnnouncementPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Three characters, a single-line message, and one action in a compact strip.
final class CharacterAnnouncementView: NSView {
    enum Kind { case release, trialStarted }
    let primaryButton = NSButton()
    let dismissButton = NSButton()
    let returnButton = NSButton()
    let previewViews = (0..<3).map { _ in NSImageView() }
    private let animator: CharacterGalleryAnimator
    private let titleLabel: NSTextField
    private var tipX: CGFloat = 0
    var onPrimaryAction: (() -> Void)?
    var onDismiss: (() -> Void)?
    var onReturn: (() -> Void)?

    init(campaign: CharacterLaunchCampaign, kind: Kind, bundle: Bundle = .main) {
        animator = CharacterGalleryAnimator(bundle: bundle, renderSize: UI.characterPreviewSize)
        titleLabel = NSTextField(labelWithString: kind == .release ? campaign.releaseTitle
            : String(localized: "\(campaign.collection.title) · 3-day trial started"))
        super.init(frame: .zero)
        titleLabel.font = .systemFont(ofSize: UI.bodySize, weight: .medium)
        titleLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        let previews = NSStackView(views: previewViews)
        previews.orientation = .horizontal; previews.alignment = .centerY; previews.spacing = UI.compactSpacing
        for (view, count) in zip(previewViews, campaign.previewCounts) {
            view.imageScaling = .scaleNone
            view.contentTintColor = .labelColor
            view.setAccessibilityLabel(HalloweenCharacter.character(for: count)?.title)
            view.widthAnchor.constraint(equalToConstant: count == 2
                ? UI.characterPreviewSize * 30 / 21 : UI.characterPreviewSize).isActive = true
            view.heightAnchor.constraint(equalToConstant: UI.characterPreviewSize).isActive = true
        }
        primaryButton.title = kind == .release ? String(localized: "Try for Free") : String(localized: "View Characters")
        primaryButton.bezelStyle = .rounded
        primaryButton.controlSize = .small
        primaryButton.font = .systemFont(ofSize: UI.captionSize)
        if kind == .release { primaryButton.toolTip = String(localized: "3-Day Menu Bar Trial") }
        primaryButton.target = self; primaryButton.action = #selector(primaryAction)
        primaryButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        dismissButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: String(localized: "Dismiss Character Announcement"))
        dismissButton.bezelStyle = .inline; dismissButton.isBordered = false
        dismissButton.contentTintColor = .secondaryLabelColor
        dismissButton.target = self; dismissButton.action = #selector(dismiss)
        dismissButton.setAccessibilityLabel(String(localized: "Dismiss Character Announcement"))
        dismissButton.widthAnchor.constraint(equalToConstant: UI.characterAnnouncementCloseSize).isActive = true
        dismissButton.heightAnchor.constraint(equalToConstant: UI.characterAnnouncementCloseSize).isActive = true
        let row = NSStackView(views: [previews, titleLabel, NSView(), primaryButton, dismissButton])
        row.orientation = .horizontal; row.alignment = .centerY; row.spacing = UI.characterAnnouncementSpacing
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: UI.characterAnnouncementPadding),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -UI.characterAnnouncementPadding),
            row.topAnchor.constraint(equalTo: topAnchor, constant: UI.characterAnnouncementTipSize),
            row.heightAnchor.constraint(equalToConstant: UI.characterAnnouncementHeight)
        ])
        let bodyHeight = UI.characterAnnouncementHeight + (kind == .trialStarted ? UI.characterAnnouncementFooterHeight : 0)
        if kind == .trialStarted {
            returnButton.title = String(localized: "Return to Previous Characters")
            returnButton.isBordered = false
            returnButton.font = .systemFont(ofSize: UI.captionSize)
            returnButton.contentTintColor = .linkColor
            returnButton.target = self; returnButton.action = #selector(returnToPrevious)
            returnButton.translatesAutoresizingMaskIntoConstraints = false
            addSubview(returnButton)
            NSLayoutConstraint.activate([
                returnButton.trailingAnchor.constraint(equalTo: row.trailingAnchor),
                returnButton.topAnchor.constraint(equalTo: row.bottomAnchor, constant: -UI.compactSpacing),
                returnButton.heightAnchor.constraint(equalToConstant: UI.characterAnnouncementFooterHeight)
            ])
        }
        let width = max(UI.characterAnnouncementMinWidth,
            row.fittingSize.width + 2 * UI.characterAnnouncementPadding)
        setFrameSize(NSSize(width: width, height: bodyHeight + UI.characterAnnouncementTipSize))
        animator.onFramesChanged = { [weak self] images in
            guard let self else { return }
            for (view, count) in zip(self.previewViews, campaign.previewCounts) {
                view.image = images.indices.contains(count) ? images[count] : nil
            }
        }
        animator.configure(collection: campaign.collection)
        setAccessibilityLabel(kind == .release ? String(localized: "New Characters") : String(localized: "3-day trial started"))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var isFlipped: Bool { true }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
    func setPlaying(_ playing: Bool) { animator.setActive(playing) }
    func setTip(_ x: CGFloat) { tipX = max(16, min(bounds.width - 16, x)); needsDisplay = true }

    override func draw(_ dirtyRect: NSRect) {
        let rect = NSRect(x: 0.5, y: UI.characterAnnouncementTipSize + 0.5,
                          width: bounds.width - 1, height: bounds.height - UI.characterAnnouncementTipSize - 1)
        let body = NSBezierPath(roundedRect: rect, xRadius: UI.cardCornerRadius, yRadius: UI.cardCornerRadius)
        NSColor.windowBackgroundColor.setFill(); body.fill()
        NSColor.separatorColor.setStroke(); body.lineWidth = 0.5; body.stroke()
        let tip = NSBezierPath()
        tip.move(to: NSPoint(x: tipX - UI.characterAnnouncementTipSize, y: UI.characterAnnouncementTipSize + 1))
        tip.line(to: NSPoint(x: tipX, y: 0))
        tip.line(to: NSPoint(x: tipX + UI.characterAnnouncementTipSize, y: UI.characterAnnouncementTipSize + 1))
        tip.close()
        NSColor.windowBackgroundColor.setFill(); tip.fill()
    }
    @objc private func primaryAction() { onPrimaryAction?() }
    @objc private func dismiss() { onDismiss?() }
    @objc private func returnToPrevious() { onReturn?() }
}

/// Never activates the app or takes the key window. All lifetime and event work is main-thread only.
final class CharacterAnnouncementController {
    private var panel: CharacterAnnouncementPanel?
    private var view: CharacterAnnouncementView?
    private var localMonitor: Any?
    private var globalMonitor: Any?
    private var observers: [NSObjectProtocol] = []
    private var guardTimer: Timer?
    var isVisible: Bool { panel?.isVisible == true }

    @discardableResult
    func show(campaign: CharacterLaunchCampaign, kind: CharacterAnnouncementView.Kind,
              relativeTo button: NSStatusBarButton, canRemainVisible: @escaping () -> Bool,
              onPrimaryAction: @escaping () -> Void, onReturn: @escaping () -> Void) -> Bool {
        precondition(Thread.isMainThread)
        dismiss()
        guard let window = button.window, window.isVisible,
              button.bounds.width > 0, button.bounds.height > 0 else { return false }
        let anchor = window.convertToScreen(button.convert(button.bounds, to: nil))
        // NSStatusBarWindow can report a nil screen while its button is already visible.
        // Resolve the display from the actual global anchor, including secondary displays.
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(NSPoint(x: anchor.midX, y: anchor.midY)) })
            ?? window.screen, screen.frame.intersects(anchor) else { return false }
        let content = CharacterAnnouncementView(campaign: campaign, kind: kind)
        let size = content.frame.size
        let visible = screen.visibleFrame.insetBy(dx: 6, dy: 6)
        guard size.width <= visible.width else { return false }
        let x = max(visible.minX, min(anchor.midX - size.width + 28, visible.maxX - size.width))
        let y = max(visible.minY, min(anchor.minY - size.height - 3, visible.maxY - size.height))
        let panel = CharacterAnnouncementPanel(contentRect: NSRect(x: x, y: y, width: size.width, height: size.height),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.backgroundColor = .clear; panel.isOpaque = false; panel.hasShadow = true
        panel.level = .statusBar
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.contentView = content
        content.setTip(anchor.midX - x)
        content.onDismiss = { [weak self] in self?.dismiss() }
        content.onPrimaryAction = { [weak self] in self?.dismiss(); onPrimaryAction() }
        content.onReturn = { [weak self] in self?.dismiss(); onReturn() }
        self.panel = panel; view = content
        panel.orderFrontRegardless()
        content.setPlaying(true)
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] event in
            if event.type == .keyDown && event.keyCode == 53 { self?.dismiss() }
            else if event.type != .keyDown && event.window !== self?.panel { self?.dismiss() }
            return event
        }
        // Global key observation uses the app's existing Accessibility permission when available.
        // Mouse dismissal remains available without an additional permission request.
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] event in
            if event.type != .keyDown || event.keyCode == 53 { self?.dismiss() }
        }
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification,
                     NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.sessionDidResignActiveNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.dismiss() })
        }
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main) { [weak self] _ in self?.dismiss() })
        guardTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            if !canRemainVisible() { self?.dismiss() }
        }
        return panel.isVisible
    }

    func dismiss() {
        precondition(Thread.isMainThread)
        view?.setPlaying(false)
        panel?.orderOut(nil)
        panel = nil; view = nil
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        localMonitor = nil; globalMonitor = nil
        guardTimer?.invalidate(); guardTimer = nil
        for observer in observers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            NotificationCenter.default.removeObserver(observer)
        }
        observers.removeAll()
    }
}
