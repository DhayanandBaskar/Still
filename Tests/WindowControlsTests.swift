import AppKit

@main
struct WindowControlsTests {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let runner = WindowChecks()
        app.delegate = runner
        app.run()
    }
}

final class WindowChecks: NSObject, NSApplicationDelegate {
    private let reader = ReaderApp()
    private var checks = 0

    func applicationDidFinishLaunching(_ notification: Notification) {
        reader.applicationDidFinishLaunching(notification)
        guard let window = NSApp.windows.first(where: { $0.delegate === reader }),
              let close = window.standardWindowButton(.closeButton),
              let minimize = window.standardWindowButton(.miniaturizeButton),
              let maximize = window.standardWindowButton(.zoomButton),
              let screen = window.screen else { fail("Missing native window controls"); return }

        check("Traffic lights are visible and enabled", [close, minimize, maximize].allSatisfy { !$0.isHidden && $0.isEnabled })
        check("Title bar and toolbar share a compact row", window.toolbarStyle == .unifiedCompact && window.titleVisibility == .hidden)
        check("Window uses simple maximize behavior", window.collectionBehavior.contains(.fullScreenNone) && window.collectionBehavior.contains(.fullScreenDisallowsTiling))

        let area = screen.visibleFrame
        let original = NSRect(x: area.midX - 400, y: area.midY - 300, width: 800, height: 600)
        window.setFrame(original, display: true)
        maximize.performClick(nil)
        check("Green button maximizes to available screen space", matches(window.frame, area) && !window.styleMask.contains(.fullScreen))
        maximize.performClick(nil)
        check("Green button restores the previous size and position", matches(window.frame, original))

        guard let toolbar = window.toolbar,
              let collapse = toolbar.items.first(where: { $0.itemIdentifier.rawValue == "collapse" }),
              let action = collapse.action else { fail("Missing toolbar collapse action"); return }
        NSApp.sendAction(action, to: collapse.target, from: collapse)
        check("Collapsed toolbar keeps the traffic lights available", !toolbar.isVisible && [close, minimize, maximize].allSatisfy { !$0.isHidden })
        NSApp.sendAction(action, to: collapse.target, from: collapse)
        check("Toolbar expands again", toolbar.isVisible)
        testIndex(in: window)

        minimize.performClick(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            self.check("Yellow button minimizes the window", window.isMiniaturized)
            window.deminiaturize(nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                close.performClick(nil)
                self.check("Red button closes the window", !window.isVisible)
                print("Passed \(self.checks) window control checks")
                exit(0)
            }
        }
    }

    private func testIndex(in window: NSWindow) {
        func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
        guard let content = window.contentView,
              let index = views(content).compactMap({ $0 as? DocumentIndexView }).first,
              let indexHeader = views(content).compactMap({ $0 as? NSButton }).first(where: { $0.title == "Index" }),
              let recentHeader = views(content).compactMap({ $0 as? NSButton }).first(where: { $0.title == "Recent Files" }),
              let recents = views(content).compactMap({ $0 as? RecentStack }).first else { fail("Missing sidebar sections"); return }
        let headings: [[String: Any]] = [
            ["id": "root", "text": "A thoughtful reading experience", "level": 1],
            ["id": "branch", "text": "A subsection after a skipped heading level", "level": 3],
            ["id": "leaf", "text": "A deeper detail", "level": 6],
            ["id": "sibling", "text": "The next section", "level": 2],
            ["id": "second", "text": "A new chapter", "level": 1],
            ["id": "child", "text": "More to explore", "level": 4]
        ]
        index.update(headings, documentKey: "fixture.md")
        let outline = index.outline
        check("Index nests headings and handles skipped levels", outline.numberOfRows == 6 && (0..<6).map { outline.level(forRow: $0) } == [0, 1, 2, 1, 0, 1])
        index.setActiveHeading("leaf")
        check("Current reading section is selected", (outline.item(atRow: outline.selectedRow) as? HeadingNode)?.id == "leaf")
        outline.collapseItem(outline.item(atRow: 0))
        index.setActiveHeading("leaf")
        check("Collapsed branches highlight their visible parent", outline.numberOfRows == 3 && (outline.item(atRow: outline.selectedRow) as? HeadingNode)?.id == "root")
        index.update(headings, documentKey: "fixture.md")
        check("Refreshing keeps collapsed index branches", outline.numberOfRows == 3)
        index.update(headings, documentKey: "other.md")
        check("A different document opens its full hierarchy", outline.numberOfRows == 6)
        var destination: String?
        index.onJump = { destination = $0 }
        outline.selectRowIndexes(IndexSet(integer: 3), byExtendingSelection: false)
        if let action = outline.action { NSApp.sendAction(action, to: outline.target, from: outline) }
        check("Choosing an index entry navigates to its heading", destination == "sibling")
        index.update([], documentKey: "empty.md")
        check("Files without headings clear the index", !index.hasHeadings && outline.numberOfRows == 0)

        if index.isHidden { indexHeader.performClick(nil) }
        indexHeader.performClick(nil)
        check("Index collapses independently", index.isHidden && !recents.enclosingScrollView!.isHidden)
        recentHeader.performClick(nil)
        check("Recent Files also collapses independently", index.isHidden && recents.enclosingScrollView!.isHidden)
        indexHeader.performClick(nil)
        check("Index expands while Recent Files stays collapsed", !index.isHidden && recents.enclosingScrollView!.isHidden)
        recentHeader.performClick(nil)
        testSidebarSplit(in: window, index: index, recents: recents)
    }

    private func testSidebarSplit(in window: NSWindow, index: DocumentIndexView, recents: RecentStack) {
        guard let sections = index.superview?.superview as? SidebarSplitView,
              let indexScroll = index.outline.enclosingScrollView,
              let recentScroll = recents.enclosingScrollView else { fail("Missing sidebar split and scroll areas"); return }
        window.contentView?.layoutSubtreeIfNeeded()
        sections.fraction = 0.7
        sections.arrangeSections()
        let height = sections.bounds.height - sections.dividerThickness
        check("Sidebar starts with a 70/30 split", abs(sections.subviews[0].frame.height / height - 0.7) < 0.01)
        sections.setPosition(height * 0.55, ofDividerAt: 0)
        check("Dragging the divider changes the section balance", abs(sections.fraction - 0.55) < 0.01)
        var frame = window.frame
        frame.size.height += 80
        window.setFrame(frame, display: true)
        window.contentView?.layoutSubtreeIfNeeded()
        check("Window resizing preserves the chosen balance", abs(sections.subviews[0].frame.height / (sections.bounds.height - sections.dividerThickness) - 0.55) < 0.01)

        let headings = (0..<100).map { ["id": "section-\($0)", "text": "A section worth reading \($0)", "level": 2] as [String: Any] }
        index.update(headings, documentKey: "long.md")
        for i in 0..<10 {
            let file = NSTextField(labelWithString: "Recent file \(i).md")
            file.translatesAutoresizingMaskIntoConstraints = false
            recents.addArrangedSubview(file)
            file.heightAnchor.constraint(equalToConstant: 36).isActive = true
        }
        window.contentView?.layoutSubtreeIfNeeded()
        check("Both sidebar sections have independent vertical scrolling", indexScroll.hasVerticalScroller && recentScroll.hasVerticalScroller && indexScroll !== recentScroll)
        check("Long indexes and recent lists can overflow their own panes", indexScroll.documentView!.frame.height > indexScroll.contentSize.height && recentScroll.documentView!.frame.height > recentScroll.contentSize.height)
        let recentPosition = recentScroll.documentVisibleRect.origin.y
        index.outline.scrollRowToVisible(99)
        check("Scrolling Index leaves Recent Files in place", indexScroll.documentVisibleRect.origin.y > 0 && recentScroll.documentVisibleRect.origin.y == recentPosition)
        let indexPosition = indexScroll.documentVisibleRect.origin.y
        recentScroll.contentView.scroll(to: NSPoint(x: 0, y: 100))
        recentScroll.reflectScrolledClipView(recentScroll.contentView)
        check("Scrolling Recent Files leaves Index in place", recentScroll.documentVisibleRect.origin.y > 0 && indexScroll.documentVisibleRect.origin.y == indexPosition)
    }

    private func matches(_ lhs: NSRect, _ rhs: NSRect) -> Bool {
        abs(lhs.minX - rhs.minX) < 2 && abs(lhs.minY - rhs.minY) < 2 && abs(lhs.width - rhs.width) < 2 && abs(lhs.height - rhs.height) < 2
    }
    private func check(_ name: String, _ condition: Bool) {
        guard condition else { fail(name); return }
        checks += 1
        print("PASS: \(name)")
    }
    private func fail(_ name: String) { fputs("FAIL: \(name)\n", stderr); exit(1) }
}
