import AppKit

final class HeadingNode: NSObject {
    let id: String
    let title: String
    let level: Int
    weak var parent: HeadingNode?
    var children: [HeadingNode] = []

    init(id: String, title: String, level: Int) {
        self.id = id
        self.title = title
        self.level = level
    }

    /// A skipped Markdown heading level still belongs to the nearest preceding parent.
    static func tree(from headings: [[String: Any]]) -> [HeadingNode] {
        var roots: [HeadingNode] = []
        var ancestors: [HeadingNode] = []
        for heading in headings {
            guard let id = heading["id"] as? String, let title = heading["text"] as? String else { continue }
            let node = HeadingNode(id: id, title: title, level: max(1, min(6, heading["level"] as? Int ?? 1)))
            while let last = ancestors.last, last.level >= node.level { ancestors.removeLast() }
            if let parent = ancestors.last {
                node.parent = parent
                parent.children.append(node)
            } else { roots.append(node) }
            ancestors.append(node)
        }
        return roots
    }

    var descendants: [HeadingNode] { [self] + children.flatMap(\.descendants) }
}

private final class IndexRowView: NSTableRowView {
    override var interiorBackgroundStyle: NSView.BackgroundStyle { .normal }
    override func drawSelection(in dirtyRect: NSRect) {
        NSColor.controlAccentColor.withAlphaComponent(0.10).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 3, dy: 2), xRadius: 6, yRadius: 6).fill()
        NSColor.controlAccentColor.withAlphaComponent(0.8).setFill()
        NSBezierPath(roundedRect: NSRect(x: 4, y: 8, width: 2, height: max(8, bounds.height - 16)), xRadius: 1, yRadius: 1).fill()
    }
}

private final class IndexOutlineView: NSOutlineView {
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36, let action { NSApp.sendAction(action, to: target, from: self) }
        else { super.keyDown(with: event) }
    }
}

final class DocumentIndexView: NSView, NSOutlineViewDataSource, NSOutlineViewDelegate {
    let outline: NSOutlineView = IndexOutlineView()
    private let scroll = NSScrollView()
    private let emptyLabel = NSTextField(wrappingLabelWithString: "Open a Markdown file to explore its headings.")
    private var roots: [HeadingNode] = []
    private var nodes: [String: HeadingNode] = [:]
    private var documentKey: String?
    private var activeID: String?
    private var rebuilding = false
    private var previousWidth: CGFloat = 0
    var onJump: ((String) -> Void)?
    var hasHeadings: Bool { !roots.isEmpty }
    var headingCount: Int { nodes.count }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("heading"))
        column.resizingMask = .autoresizingMask
        column.minWidth = 40
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.style = .plain
        outline.backgroundColor = .clear
        outline.indentationPerLevel = 14
        outline.intercellSpacing = NSSize(width: 0, height: 2)
        outline.rowHeight = 32
        outline.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        outline.autoresizesOutlineColumn = false
        outline.focusRingType = .none
        outline.allowsEmptySelection = true
        outline.allowsMultipleSelection = false
        outline.allowsColumnReordering = false
        outline.allowsColumnResizing = false
        outline.dataSource = self
        outline.delegate = self
        outline.target = self
        outline.action = #selector(openHeading)
        outline.setAccessibilityLabel("Document index")
        scroll.documentView = outline

        emptyLabel.font = .systemFont(ofSize: 12)
        emptyLabel.textColor = .tertiaryLabelColor
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(emptyLabel)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: topAnchor), scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor), scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            emptyLabel.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            emptyLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            emptyLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12)
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        let width = scroll.contentSize.width
        guard abs(width - previousWidth) > 1 else { return }
        previousWidth = width
        outline.tableColumns.first?.width = width
        outline.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: 0..<outline.numberOfRows))
    }

    func update(_ headings: [[String: Any]], documentKey: String?) {
        let collapsed = documentKey == self.documentKey ? Set(nodes.values.filter { !$0.children.isEmpty && !outline.isItemExpanded($0) }.map(\.id)) : []
        if documentKey != self.documentKey { activeID = nil }
        self.documentKey = documentKey
        roots = HeadingNode.tree(from: headings)
        nodes = Dictionary(uniqueKeysWithValues: roots.flatMap(\.descendants).map { ($0.id, $0) })
        rebuilding = true
        outline.reloadData()
        outline.expandItem(nil, expandChildren: true)
        for id in collapsed { if let node = nodes[id] { outline.collapseItem(node) } }
        rebuilding = false
        emptyLabel.stringValue = documentKey == nil ? "Open a Markdown file to explore its headings." : "This page has no headings. Settle in and read."
        emptyLabel.isHidden = hasHeadings
        scroll.isHidden = !hasHeadings
        setActiveHeading(activeID)
    }

    func setActiveHeading(_ id: String?) {
        activeID = id
        var visible = id.flatMap { nodes[$0] }
        while let node = visible, outline.row(forItem: node) < 0 { visible = node.parent }
        if let visible {
            let row = outline.row(forItem: visible)
            outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        } else { outline.deselectAll(nil) }
    }

    @objc private func openHeading() {
        guard let node = outline.item(atRow: outline.selectedRow) as? HeadingNode else { return }
        onJump?(node.id)
    }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int { (item as? HeadingNode)?.children.count ?? roots.count }
    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any { ((item as? HeadingNode)?.children ?? roots)[index] }
    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool { !(item as! HeadingNode).children.isEmpty }
    func outlineView(_ outlineView: NSOutlineView, objectValueFor tableColumn: NSTableColumn?, byItem item: Any?) -> Any? { (item as? HeadingNode)?.title }
    func outlineView(_ outlineView: NSOutlineView, shouldEdit tableColumn: NSTableColumn?, item: Any) -> Bool { false }
    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? { IndexRowView() }
    func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        let node = item as! HeadingNode
        let width = max(50, outlineView.bounds.width - CGFloat(outlineView.level(forItem: node) + 1) * 14 - 24)
        let height = (node.title as NSString).boundingRect(with: NSSize(width: width, height: 100), options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: font(for: node)]).height
        return max(32, min(64, ceil(height) + 14))
    }
    private func font(for node: HeadingNode) -> NSFont { .systemFont(ofSize: 13, weight: node.level <= 2 ? .medium : .regular) }
    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        let node = item as! HeadingNode
        let identifier = NSUserInterfaceItemIdentifier("headingCell")
        let cell = outlineView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView ?? NSTableCellView()
        if cell.textField == nil {
            cell.identifier = identifier
            let label = NSTextField(wrappingLabelWithString: "")
            label.maximumNumberOfLines = 3
            label.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(label)
            cell.textField = label
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 3),
                label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
                label.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
            ])
        }
        cell.textField?.stringValue = node.title
        cell.textField?.font = font(for: node)
        cell.textField?.textColor = node.level <= 2 ? .labelColor : .secondaryLabelColor
        cell.toolTip = node.title
        return cell
    }
    func outlineViewItemDidCollapse(_ notification: Notification) { if !rebuilding { setActiveHeading(activeID) } }
    func outlineViewItemDidExpand(_ notification: Notification) { if !rebuilding { setActiveHeading(activeID) } }
}
