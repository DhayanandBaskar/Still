import AppKit

/// A native horizontal divider that keeps the reader's two sidebar sections proportional.
final class SidebarSplitView: NSSplitView, NSSplitViewDelegate {
    override var isFlipped: Bool { true }
    override var dividerThickness: CGFloat { 9 }
    var indexExpanded = true
    var recentsExpanded = true
    var fraction: CGFloat = 0.7
    var onFractionChanged: ((CGFloat) -> Void)?
    private var arranging = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isVertical = false
        dividerStyle = .thin
        delegate = self
        toolTip = "Drag to adjust the space for Index and Recent Files"
        setAccessibilityLabel("Index and Recent Files split")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func drawDivider(in rect: NSRect) {
        NSColor.separatorColor.withAlphaComponent(0.5).setFill()
        NSRect(x: 16, y: rect.midY, width: max(0, rect.width - 32), height: 0.5).fill()
        NSColor.tertiaryLabelColor.setFill()
        NSBezierPath(roundedRect: NSRect(x: rect.midX - 14, y: rect.midY - 1, width: 28, height: 2), xRadius: 1, yRadius: 1).fill()
    }

    override func layout() { super.layout(); arrangeSections() }

    func arrangeSections() {
        guard !arranging, subviews.count == 2, bounds.height > dividerThickness else { return }
        arranging = true
        defer { arranging = false }
        let available = bounds.height - dividerThickness
        let top = position(for: available)
        let frames = [
            NSRect(x: 0, y: 0, width: bounds.width, height: top),
            NSRect(x: 0, y: top + dividerThickness, width: bounds.width, height: available - top)
        ]
        for (view, frame) in zip(subviews, frames) {
            if view.frame != frame { view.frame = frame }
        }
        needsDisplay = true
    }

    private func position(for available: CGFloat) -> CGFloat {
        if !indexExpanded { return min(50, available / 2) }
        if !recentsExpanded { return max(0, available - min(50, available / 2)) }
        let minimum = min(96, available / 3)
        return min(available - minimum, max(minimum, available * fraction))
    }

    func splitView(_ splitView: NSSplitView, resizeSubviewsWithOldSize oldSize: NSSize) { arrangeSections() }
    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        let available = max(0, bounds.height - dividerThickness)
        if !indexExpanded || !recentsExpanded { return position(for: available) }
        return min(96, available / 3)
    }
    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        let available = max(0, bounds.height - dividerThickness)
        if !indexExpanded || !recentsExpanded { return position(for: available) }
        return available - min(96, available / 3)
    }
    func splitView(_ splitView: NSSplitView, effectiveRect proposedEffectiveRect: NSRect, forDrawnRect drawnRect: NSRect, ofDividerAt dividerIndex: Int) -> NSRect {
        indexExpanded && recentsExpanded ? drawnRect.insetBy(dx: 0, dy: -4) : .zero
    }
    func splitViewDidResizeSubviews(_ notification: Notification) {
        guard !arranging, indexExpanded, recentsExpanded, subviews.count == 2 else { return }
        let available = bounds.height - dividerThickness
        guard available > 0 else { return }
        let updated = subviews[0].frame.height / available
        guard abs(updated - fraction) > 0.001 else { return }
        fraction = updated
        onFractionChanged?(fraction)
    }
}
