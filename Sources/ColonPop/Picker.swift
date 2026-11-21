import AppKit

enum PopupPlacement {
    static let rowHeight: CGFloat = 34

    static func rowFrame(_ index: Int, in size: CGSize) -> CGRect {
        CGRect(x: 6, y: size.height - 6 - CGFloat(index + 1) * rowHeight,
               width: size.width - 12, height: rowHeight)
    }

    static func rowIndex(atQuartzPoint point: CGPoint, panel: CGRect, primaryTop: CGFloat, count: Int) -> Int? {
        let local = CGPoint(x: point.x - panel.minX, y: primaryTop - point.y - panel.minY)
        return (0..<count).first { rowFrame($0, in: panel.size).contains(local) }
    }

    static func appKitRect(_ quartz: CGRect, primaryTop: CGFloat) -> CGRect {
        CGRect(x: quartz.minX, y: primaryTop - quartz.maxY, width: quartz.width, height: quartz.height)
    }

    static func frame(size: CGSize, near anchor: CGRect, inside screen: CGRect) -> CGRect {
        let safe = screen.insetBy(dx: 6, dy: 6)
        let below = anchor.minY - size.height - 5
        let preferredY = below >= safe.minY ? below : anchor.maxY + 5
        return CGRect(x: max(safe.minX, min(anchor.minX, safe.maxX - size.width)),
                      y: max(safe.minY, min(preferredY, safe.maxY - size.height)),
                      width: size.width, height: size.height)
    }
}

private final class PassivePanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class CandidateRow: NSView {
    private let glyph = NSTextField(labelWithString: "")
    private let alias = NSTextField(labelWithString: "")
    private let enter = NSTextField(labelWithString: "↵")
    var choose: (() -> Void)?
    private(set) var candidate: Candidate?
    private var selected = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        glyph.font = .systemFont(ofSize: 21)
        glyph.alignment = .center
        alias.font = .systemFont(ofSize: 13, weight: .medium)
        alias.lineBreakMode = .byTruncatingMiddle
        enter.font = .systemFont(ofSize: 14, weight: .medium)
        enter.alignment = .right
        for label in [glyph, alias, enter] {
            label.setAccessibilityElement(false)
            addSubview(label)
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }

    required init?(coder: NSCoder) { nil }

    func configure(with item: Candidate, selected: Bool) {
        candidate = item
        self.selected = selected
        glyph.stringValue = item.glyph
        alias.stringValue = ":" + item.alias + ":"
        alias.textColor = selected ? .white : .labelColor
        enter.textColor = .white
        enter.isHidden = !selected
        toolTip = item.name
        setAccessibilityLabel(item.name + ", " + alias.stringValue)
        setAccessibilitySelected(selected)
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        glyph.frame = NSRect(x: 5, y: 4, width: 33, height: 26)
        alias.frame = NSRect(x: 45, y: 8, width: bounds.width - 80, height: 18)
        enter.frame = NSRect(x: bounds.width - 30, y: 8, width: 19, height: 18)
    }

    override func draw(_ dirtyRect: NSRect) {
        if selected {
            NSColor.controlAccentColor.setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? { isHidden ? nil : (frame.contains(point) ? self : nil) }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { choose?() }
    }
    override func accessibilityPerformPress() -> Bool { choose?(); return true }
}

@MainActor
protocol PickerSurface: AnyObject {
    var onPick: ((Candidate) -> Void)? { get set }
    func hide()
    func show(_ items: [Candidate], selected: Int, quartzCaret: CGRect?)
    func showInsertionFailure(needsKeyboardAccess: Bool)
    func contains(quartzPoint: CGPoint) -> Bool
    func candidate(atQuartzPoint point: CGPoint) -> Candidate?
}

@MainActor
final class Picker: PickerSurface {
    var onPick: ((Candidate) -> Void)?
    private let panel = PassivePanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                                     backing: .buffered, defer: true)
    private let surface = NSVisualEffectView()
    private let hint = NSTextField(labelWithString: "")
    private var failureDismissal: DispatchWorkItem?
    private var rows: [CandidateRow] = []
    private let width: CGFloat = 300

    init() {
        panel.level = .popUpMenu
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.worksWhenModal = true
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = true
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.setAccessibilityLabel("Emoji suggestions")
        surface.material = .popover
        surface.blendingMode = .behindWindow
        surface.state = .active
        surface.wantsLayer = true
        surface.layer?.cornerRadius = 11
        surface.layer?.masksToBounds = true
        panel.contentView = surface
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        surface.addSubview(hint)
        for _ in 0..<Catalog.rowLimit {
            let row = CandidateRow(frame: .zero)
            row.choose = { [weak self, weak row] in
                if let hit = row?.candidate { self?.onPick?(hit) }
            }
            rows.append(row)
            surface.addSubview(row)
        }
    }

    func hide() {
        failureDismissal?.cancel()
        failureDismissal = nil
        if panel.isVisible { panel.orderOut(nil) }
    }

    func showInsertionFailure(needsKeyboardAccess: Bool) {
        guard panel.frame.width > 0 else { return }
        for row in rows { row.isHidden = true }
        let frame = panel.frame
        panel.setFrame(CGRect(x: frame.minX, y: frame.maxY - 34, width: frame.width, height: 34), display: false)
        panel.ignoresMouseEvents = true
        hint.stringValue = needsKeyboardAccess ? "Allow keyboard insertion in ColonPop Setup." : "Couldn’t verify the shortcode in this field."
        hint.frame = NSRect(x: 12, y: 8, width: frame.width - 24, height: 17)
        panel.orderFrontRegardless()
        let dismissal = DispatchWorkItem { [weak self] in self?.hide() }
        failureDismissal = dismissal
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: dismissal)
    }

    func contains(quartzPoint: CGPoint) -> Bool {
        guard panel.isVisible, let top = NSScreen.screens.first?.frame.maxY else { return false }
        return panel.frame.contains(CGPoint(x: quartzPoint.x, y: top - quartzPoint.y))
    }

    func candidate(atQuartzPoint point: CGPoint) -> Candidate? {
        guard panel.isVisible, let top = NSScreen.screens.first?.frame.maxY else { return nil }
        guard let index = PopupPlacement.rowIndex(atQuartzPoint: point, panel: panel.frame, primaryTop: top,
                                                  count: rows.prefix { !$0.isHidden }.count) else { return nil }
        return rows[index].candidate
    }

    func show(_ items: [Candidate], selected: Int, quartzCaret: CGRect?) {
        guard !items.isEmpty, let primary = NSScreen.screens.first else { hide(); return }
        failureDismissal?.cancel()
        failureDismissal = nil
        panel.ignoresMouseEvents = false
        hint.stringValue = "↑↓  Choose       ↵  Insert       esc  Dismiss"
        let caret = quartzCaret.map { PopupPlacement.appKitRect($0, primaryTop: primary.frame.maxY) }
        let pointer = NSEvent.mouseLocation
        let screenAtCaret = caret.flatMap { rect in
            NSScreen.screens.first { $0.frame.contains(CGPoint(x: rect.midX, y: rect.midY)) }
        }
        let screen = screenAtCaret ?? NSScreen.screens.first { $0.frame.contains(pointer) } ?? primary
        let anchor = screenAtCaret != nil ? caret! : CGRect(origin: pointer, size: CGSize(width: 0, height: 1))
        let height = CGFloat(items.count) * PopupPlacement.rowHeight + 34
        panel.setFrame(PopupPlacement.frame(size: CGSize(width: width, height: height),
                                           near: anchor, inside: screen.visibleFrame), display: false)
        for (i, row) in rows.enumerated() {
            row.isHidden = i >= items.count
            guard !row.isHidden else { continue }
            row.frame = PopupPlacement.rowFrame(i, in: panel.frame.size)
            row.configure(with: items[i], selected: i == selected)
        }
        hint.frame = NSRect(x: 15, y: 6, width: width - 30, height: 16)
        if !panel.isVisible { panel.orderFrontRegardless() }
    }
}
