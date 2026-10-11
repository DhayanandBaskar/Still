import AppKit
import WebKit
import UniformTypeIdentifiers

final class RecentStack: NSStackView {
    override var isFlipped: Bool { true }
}

final class ReaderWebView: WKWebView {
    var openFile: ((URL) -> Void)?
    var escape: (() -> Void)?
    private func markdownURL(_ sender: NSDraggingInfo) -> URL? {
        let files = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
        return files?.first(where: { ["md", "markdown"].contains($0.pathExtension.lowercased()) })
    }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { markdownURL(sender) == nil ? [] : .copy }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { draggingEntered(sender) }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { markdownURL(sender) != nil }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let url = markdownURL(sender) else { return false }
        openFile?(url)
        return true
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { escape?() } else { super.keyDown(with: event) }
    }
}

/// Serves only image files beside the opened document. No temporary HTML or source writes.
final class LocalImages: NSObject, WKURLSchemeHandler {
    var directory: URL?
    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let directory, let url = urlSchemeTask.request.url,
              url.host == "document",
              let encoded = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath,
              let path = String(encoded.dropFirst()).removingPercentEncoding,
              !path.hasPrefix("/"), !path.contains("\0") else {
            urlSchemeTask.didFailWithError(URLError(.badURL)); return
        }
        let root = directory.resolvingSymlinksInPath().standardizedFileURL
        let file = root.appendingPathComponent(path).resolvingSymlinksInPath().standardizedFileURL
        guard file.path.hasPrefix(root.path + "/"),
              let type = UTType(filenameExtension: file.pathExtension), type.conforms(to: .image),
              let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true, (values.fileSize ?? Int.max) <= 30_000_000,
              let data = try? Data(contentsOf: file) else {
            urlSchemeTask.didFailWithError(URLError(.noPermissionsToReadFile)); return
        }
        let response = URLResponse(url: url, mimeType: type.preferredMIMEType ?? "application/octet-stream", expectedContentLength: data.count, textEncodingName: nil)
        urlSchemeTask.didReceive(response)
        urlSchemeTask.didReceive(data)
        urlSchemeTask.didFinish()
    }
    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {}
}

final class ReaderApp: NSObject, NSApplicationDelegate, NSWindowDelegate, WKScriptMessageHandler, WKNavigationDelegate, NSToolbarDelegate, NSSearchFieldDelegate, NSMenuItemValidation, NSSplitViewDelegate, NSOpenSavePanelDelegate {
    private var window: NSWindow!
    private var webView: ReaderWebView!
    private var toolbar: NSToolbar!
    private var searchBar: NSView!
    private var searchField: NSSearchField!
    private var searchHeight: NSLayoutConstraint!
    private var searchResult: NSTextField!
    private var currentFile: URL?
    private var source = ""
    private var monitor: FileMonitor?
    private var pendingFile: URL?
    private var ready = false
    private var focus = false
    private var findVisible = false
    private var findRequest = 0
    private var splitView: NSSplitView!
    private var sidebar: NSView!
    private var recentStack: NSStackView!
    private var documentIndex: DocumentIndexView!
    private var indexHeader: NSButton!
    private var recentHeader: NSButton!
    private var indexCount: NSTextField!
    private var recentCount: NSTextField!
    private var indexZeroHeight: NSLayoutConstraint!
    private var recentZeroHeight: NSLayoutConstraint!
    private var indexBodyBottom: NSLayoutConstraint!
    private var recentBodyBottom: NSLayoutConstraint!
    private var sidebarSections: SidebarSplitView!
    private var recentScroll: NSScrollView!
    private var indexExpanded = true
    private var recentsExpanded = true
    private var sidebarVisible = true
    private var sidebarWidth: CGFloat = 260
    private var toolbarVisible = true
    private var sidebarBeforeFocus = true
    private var toolbarBeforeFocus = true
    private var toolbarReveal: NSTitlebarAccessoryViewController!
    private let images = LocalImages()
    private let defaults = UserDefaults.standard
    private var recentFiles: [URL] = []
    private var recentMenu: NSMenu!
    private var appearanceMenu: NSMenu!
    private var themeMenu: NSMenu!
    private var systemAppearanceObservation: NSKeyValueObservation?
    private var contentsMenu: NSMenu!
    private var theme: String { defaults.string(forKey: "theme") ?? "system" }
    private var typeface: String { defaults.string(forKey: "typeface") ?? "sans" }
    private var fontSize: Int { defaults.object(forKey: "fontSize") as? Int ?? 17 }

    func applicationDidFinishLaunching(_ notification: Notification) {
        recentFiles = (defaults.stringArray(forKey: "recentFiles") ?? []).map { URL(fileURLWithPath: $0) }.filter { FileManager.default.fileExists(atPath: $0.path) }
        makeMenus()
        makeWindow()
        systemAppearanceObservation = NSApp.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in
            DispatchQueue.main.async {
                guard let self, self.theme == "system" else { return }
                self.applyPreferences()
            }
        }
        loadReader()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        if let argument = CommandLine.arguments.dropFirst().first(where: { !$0.hasPrefix("-") }) {
            pendingFile = URL(fileURLWithPath: argument)
        }
    }

    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        if let first = filenames.first {
            let url = URL(fileURLWithPath: first)
            if ready { open(url) } else { pendingFile = url }
        }
        sender.reply(toOpenOrPrint: .success)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        window.makeKeyAndOrderFront(nil)
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        monitor?.cancel()
        systemAppearanceObservation?.invalidate()
    }

    private func makeWindow() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 800), styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = "Still"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.collectionBehavior = [.fullScreenNone, .fullScreenDisallowsTiling]
        window.minSize = NSSize(width: 540, height: 420)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.setFrameAutosaveName("StillReaderWindow")
        window.center()

        toolbar = NSToolbar(identifier: "reader")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar
        window.toolbarStyle = .unifiedCompact
        window.standardWindowButton(.closeButton)?.toolTip = "Close window"
        window.standardWindowButton(.miniaturizeButton)?.toolTip = "Minimize window"
        if let maximize = window.standardWindowButton(.zoomButton) {
            maximize.toolTip = "Maximize or restore window"
            maximize.setAccessibilityLabel("Maximize or restore window")
        }
        makeToolbarReveal()

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.setURLSchemeHandler(images, forURLScheme: "still-image")
        configuration.userContentController.add(self, name: "reader")
        webView = ReaderWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = self
        webView.setValue(false, forKey: "drawsBackground")
        webView.registerForDraggedTypes([.fileURL])
        webView.openFile = { [weak self] url in self?.open(url) }
        webView.escape = { [weak self] in self?.escape() }
        webView.translatesAutoresizingMaskIntoConstraints = false
        webView.setAccessibilityLabel("Markdown reading view")

        let root = NSView()
        window.contentView = root
        splitView = NSSplitView()
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitView.delegate = self
        splitView.autosaveName = "StillSidebarWidth"
        splitView.translatesAutoresizingMaskIntoConstraints = false
        sidebar = NSView()
        let readingPane = NSView()
        root.addSubview(splitView)
        splitView.addArrangedSubview(sidebar)
        splitView.addArrangedSubview(readingPane)
        NSLayoutConstraint.activate([
            splitView.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor),
            splitView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            splitView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            splitView.trailingAnchor.constraint(equalTo: root.trailingAnchor)
        ])
        makeSidebar()
        searchBar = NSView()
        searchBar.translatesAutoresizingMaskIntoConstraints = false
        readingPane.addSubview(searchBar)
        readingPane.addSubview(webView)
        searchHeight = searchBar.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            searchBar.topAnchor.constraint(equalTo: readingPane.topAnchor),
            searchBar.leadingAnchor.constraint(equalTo: readingPane.leadingAnchor),
            searchBar.trailingAnchor.constraint(equalTo: readingPane.trailingAnchor), searchHeight,
            webView.topAnchor.constraint(equalTo: searchBar.bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: readingPane.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: readingPane.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: readingPane.bottomAnchor)
        ])
        makeSearchBar()
        applyPreferences()
        root.layoutSubtreeIfNeeded()
        splitView.setPosition(sidebarWidth, ofDividerAt: 0)
        sidebarVisible = defaults.object(forKey: "sidebarVisible") as? Bool ?? true
        if !sidebarVisible { setSidebar(false) }
    }

    private func makeSidebar() {
        sidebar.wantsLayer = true
        indexExpanded = defaults.object(forKey: "indexExpanded") as? Bool ?? true
        recentsExpanded = defaults.object(forKey: "recentsExpanded") as? Bool ?? true
        sidebarSections = SidebarSplitView()
        sidebarSections.translatesAutoresizingMaskIntoConstraints = false
        sidebarSections.fraction = CGFloat(defaults.object(forKey: "sidebarIndexFraction") as? Double ?? 0.7)
        sidebarSections.onFractionChanged = { [weak self] fraction in self?.defaults.set(Double(fraction), forKey: "sidebarIndexFraction") }
        sidebar.addSubview(sidebarSections)
        let indexPane = NSView()
        let recentPane = NSView()
        sidebarSections.addArrangedSubview(indexPane)
        sidebarSections.addArrangedSubview(recentPane)
        let indexSection = makeSidebarHeader("Index", in: indexPane, action: #selector(toggleIndexSection))
        indexHeader = indexSection.button
        indexCount = indexSection.count
        let recentSection = makeSidebarHeader("Recent Files", in: recentPane, action: #selector(toggleRecentSection))
        recentHeader = recentSection.button
        recentCount = recentSection.count
        documentIndex = DocumentIndexView()
        documentIndex.translatesAutoresizingMaskIntoConstraints = false
        documentIndex.onJump = { [weak self] id in self?.navigateToHeading(id) }
        indexPane.addSubview(documentIndex)
        let close = iconButton("sidebar.left", label: "Collapse sidebar (⌥⌘S)", action: #selector(toggleSidebar))
        close.translatesAutoresizingMaskIntoConstraints = false
        indexSection.view.addSubview(close)
        indexCount.trailingAnchor.constraint(equalTo: close.leadingAnchor, constant: -8).isActive = true
        recentCount.trailingAnchor.constraint(equalTo: recentSection.view.trailingAnchor, constant: -8).isActive = true
        recentScroll = NSScrollView()
        recentScroll.drawsBackground = false
        recentScroll.hasVerticalScroller = true
        recentScroll.autohidesScrollers = true
        recentScroll.translatesAutoresizingMaskIntoConstraints = false
        recentStack = RecentStack()
        recentStack.orientation = .vertical
        recentStack.alignment = .leading
        recentStack.spacing = 4
        recentStack.translatesAutoresizingMaskIntoConstraints = false
        recentScroll.documentView = recentStack
        recentPane.addSubview(recentScroll)
        indexZeroHeight = documentIndex.heightAnchor.constraint(equalToConstant: 0)
        recentZeroHeight = recentScroll.heightAnchor.constraint(equalToConstant: 0)
        indexBodyBottom = documentIndex.bottomAnchor.constraint(equalTo: indexPane.bottomAnchor, constant: -12)
        recentBodyBottom = recentScroll.bottomAnchor.constraint(equalTo: recentPane.bottomAnchor, constant: -12)
        NSLayoutConstraint.activate([
            sidebarSections.topAnchor.constraint(equalTo: sidebar.topAnchor),
            sidebarSections.bottomAnchor.constraint(equalTo: sidebar.bottomAnchor),
            sidebarSections.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor),
            sidebarSections.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            indexSection.view.topAnchor.constraint(equalTo: indexPane.topAnchor, constant: 12),
            close.centerYAnchor.constraint(equalTo: indexSection.view.centerYAnchor),
            close.trailingAnchor.constraint(equalTo: indexSection.view.trailingAnchor, constant: -4),
            close.widthAnchor.constraint(equalToConstant: 24),
            close.heightAnchor.constraint(equalToConstant: 24),
            documentIndex.topAnchor.constraint(equalTo: indexSection.view.bottomAnchor, constant: 6),
            documentIndex.leadingAnchor.constraint(equalTo: indexPane.leadingAnchor, constant: 8),
            documentIndex.trailingAnchor.constraint(equalTo: indexPane.trailingAnchor, constant: -8),
            documentIndex.heightAnchor.constraint(greaterThanOrEqualToConstant: 0),
            recentSection.view.topAnchor.constraint(equalTo: recentPane.topAnchor, constant: 12),
            recentScroll.topAnchor.constraint(equalTo: recentSection.view.bottomAnchor, constant: 6),
            recentScroll.leadingAnchor.constraint(equalTo: recentPane.leadingAnchor, constant: 8),
            recentScroll.trailingAnchor.constraint(equalTo: recentPane.trailingAnchor, constant: -8),
            recentScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 0),
            recentStack.topAnchor.constraint(equalTo: recentScroll.contentView.topAnchor),
            recentStack.leadingAnchor.constraint(equalTo: recentScroll.contentView.leadingAnchor),
            recentStack.trailingAnchor.constraint(equalTo: recentScroll.contentView.trailingAnchor),
            recentStack.widthAnchor.constraint(equalTo: recentScroll.contentView.widthAnchor)
        ])
        updateSidebar()
        updateSidebarSections()
    }

    private func makeSidebarHeader(_ title: String, in parent: NSView, action: Selector) -> (view: NSView, button: NSButton, count: NSTextField) {
        let view = NSView()
        view.translatesAutoresizingMaskIntoConstraints = false
        parent.addSubview(view)
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .regularSquare
        button.isBordered = false
        button.alignment = .left
        button.font = .systemFont(ofSize: 12, weight: .semibold)
        button.contentTintColor = .secondaryLabelColor
        button.imagePosition = .imageLeft
        button.imageHugsTitle = true
        button.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(button)
        let count = NSTextField(labelWithString: "")
        count.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        count.textColor = .tertiaryLabelColor
        count.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(count)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: parent.leadingAnchor, constant: 12),
            view.trailingAnchor.constraint(equalTo: parent.trailingAnchor, constant: -10),
            view.heightAnchor.constraint(equalToConstant: 26),
            button.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            button.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            button.trailingAnchor.constraint(equalTo: count.leadingAnchor, constant: -8),
            count.centerYAnchor.constraint(equalTo: view.centerYAnchor)
        ])
        return (view, button, count)
    }

    @objc private func toggleIndexSection() {
        indexExpanded.toggle()
        defaults.set(indexExpanded, forKey: "indexExpanded")
        updateSidebarSections()
    }
    @objc private func toggleRecentSection() {
        recentsExpanded.toggle()
        defaults.set(recentsExpanded, forKey: "recentsExpanded")
        updateSidebarSections()
    }
    private func updateSidebarSections() {
        guard documentIndex != nil else { return }
        for (button, expanded, name) in [(indexHeader!, indexExpanded, "Index"), (recentHeader!, recentsExpanded, "Recent Files")] {
            button.image = NSImage(systemSymbolName: expanded ? "chevron.down" : "chevron.right", accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 9, weight: .semibold))
            button.setAccessibilityLabel("\(expanded ? "Collapse" : "Expand") \(name)")
            button.toolTip = "\(expanded ? "Collapse" : "Expand") \(name)"
        }
        documentIndex.isHidden = !indexExpanded
        recentScroll.isHidden = !recentsExpanded
        indexBodyBottom.isActive = indexExpanded
        recentBodyBottom.isActive = recentsExpanded
        indexZeroHeight.isActive = !indexExpanded
        recentZeroHeight.isActive = !recentsExpanded
        sidebarSections.indexExpanded = indexExpanded
        sidebarSections.recentsExpanded = recentsExpanded
        sidebarSections.arrangeSections()
        indexCount.stringValue = documentIndex.hasHeadings ? "\(documentIndex.headingCount)" : ""
        recentCount.stringValue = recentFiles.isEmpty ? "" : "\(recentFiles.count)"
        sidebar.layoutSubtreeIfNeeded()
    }

    private func updateSidebar() {
        guard recentStack != nil else { return }
        for view in recentStack.arrangedSubviews { recentStack.removeArrangedSubview(view); view.removeFromSuperview() }
        if recentFiles.isEmpty {
            let empty = NSTextField(wrappingLabelWithString: "Files you open will appear here.")
            empty.font = .systemFont(ofSize: 12)
            empty.textColor = .tertiaryLabelColor
            empty.translatesAutoresizingMaskIntoConstraints = false
            recentStack.addArrangedSubview(empty)
            empty.widthAnchor.constraint(equalTo: recentStack.widthAnchor, constant: -16).isActive = true
            updateSidebarSections()
            return
        }
        updateSidebarSections()
        for (index, file) in recentFiles.enumerated() {
            let button = NSButton(title: file.lastPathComponent, target: self, action: #selector(openSidebarFile))
            button.tag = index
            button.bezelStyle = .regularSquare
            button.isBordered = false
            button.alignment = .left
            button.font = .systemFont(ofSize: 12)
            button.lineBreakMode = .byTruncatingMiddle
            button.image = NSImage(systemSymbolName: "doc.text", accessibilityDescription: nil)
            button.imagePosition = .imageLeft
            button.imageScaling = .scaleProportionallyDown
            button.contentTintColor = file == currentFile ? .controlAccentColor : .secondaryLabelColor
            button.toolTip = file.path
            button.setAccessibilityLabel("Open recent file \(file.lastPathComponent)")
            button.wantsLayer = true
            button.layer?.cornerRadius = 5
            button.layer?.backgroundColor = file == currentFile ? NSColor.controlAccentColor.withAlphaComponent(0.09).cgColor : NSColor.clear.cgColor
            button.translatesAutoresizingMaskIntoConstraints = false
            recentStack.addArrangedSubview(button)
            NSLayoutConstraint.activate([button.widthAnchor.constraint(equalTo: recentStack.widthAnchor), button.heightAnchor.constraint(equalToConstant: 34)])
        }
    }

    @objc private func openSidebarFile(_ sender: NSButton) { if recentFiles.indices.contains(sender.tag) { open(recentFiles[sender.tag]) } }
    @objc private func toggleSidebar() {
        if focus { toggleFocus() }
        setSidebar(!sidebarVisible)
        defaults.set(sidebarVisible, forKey: "sidebarVisible")
    }
    private func setSidebar(_ visible: Bool) {
        if !visible, sidebarVisible { sidebarWidth = max(190, sidebar.frame.width) }
        sidebarVisible = visible
        sidebar.isHidden = !visible
        splitView.adjustSubviews()
        if visible { splitView.setPosition(sidebarWidth, ofDividerAt: 0) }
    }
    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat { 190 }
    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat { min(380, splitView.bounds.width - 320) }
    func splitView(_ splitView: NSSplitView, shouldAdjustSizeOfSubview view: NSView) -> Bool { view !== sidebar }

    private func makeToolbarReveal() {
        toolbarReveal = NSTitlebarAccessoryViewController()
        toolbarReveal.layoutAttribute = .right
        let button = iconButton("chevron.down", label: "Show top bar (⇧⌘T)", action: #selector(toggleToolbar))
        button.frame = NSRect(x: 0, y: 0, width: 36, height: 24)
        toolbarReveal.view = button
        window.addTitlebarAccessoryViewController(toolbarReveal)
        toolbarReveal.isHidden = true
        toolbarReveal.view.isHidden = true
    }
    @objc private func toggleToolbar() {
        if focus { toggleFocus() }
        toolbarVisible.toggle()
        toolbar.isVisible = toolbarVisible
        toolbarReveal.isHidden = toolbarVisible
        toolbarReveal.view.isHidden = toolbarVisible
    }

    private func makeSearchBar() {
        searchField = NSSearchField()
        searchField.placeholderString = "Find in document"
        searchField.delegate = self
        searchField.sendsSearchStringImmediately = true
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.setAccessibilityLabel("Find in document")
        searchResult = NSTextField(labelWithString: "")
        searchResult.font = .systemFont(ofSize: 11)
        searchResult.textColor = .secondaryLabelColor
        let previous = iconButton("chevron.up", label: "Previous match", action: #selector(findPrevious))
        let next = iconButton("chevron.down", label: "Next match", action: #selector(findNext))
        let close = iconButton("xmark", label: "Close find", action: #selector(hideFind))
        let stack = NSStackView(views: [searchField, searchResult, previous, next, close])
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        searchBar.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerYAnchor.constraint(equalTo: searchBar.centerYAnchor),
            stack.trailingAnchor.constraint(equalTo: searchBar.trailingAnchor, constant: -20),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: searchBar.leadingAnchor, constant: 20),
            searchField.widthAnchor.constraint(equalToConstant: 220)
        ])
        searchBar.isHidden = true
    }

    private func iconButton(_ symbol: String, label: String, action: Selector) -> NSButton {
        let button = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: label)!, target: self, action: action)
        button.bezelStyle = .texturedRounded
        button.isBordered = false
        button.toolTip = label
        button.setAccessibilityLabel(label)
        return button
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { toolbarDefaultItemIdentifiers(toolbar) }
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [NSToolbarItem.Identifier("sidebar"), NSToolbarItem.Identifier("open"), .flexibleSpace, NSToolbarItem.Identifier("theme"), NSToolbarItem.Identifier("type"), NSToolbarItem.Identifier("focus"), NSToolbarItem.Identifier("collapse")]
    }
    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: identifier)
        switch identifier.rawValue {
        case "sidebar":
            item.label = "Sidebar"
            item.toolTip = "Show or hide recent files (⌥⌘S)"
            item.image = NSImage(systemSymbolName: "sidebar.left", accessibilityDescription: item.label)
            item.target = self; item.action = #selector(toggleSidebar)
        case "open":
            item.label = "Open Markdown"
            item.toolTip = "Open Markdown (⌘O)"
            let button = NSButton(title: "Open", image: NSImage(systemSymbolName: "folder", accessibilityDescription: nil)!, target: self, action: #selector(openPanel))
            button.bezelStyle = .texturedRounded
            button.isBordered = false
            button.font = .systemFont(ofSize: 12)
            button.toolTip = item.toolTip
            button.setAccessibilityLabel("Open Markdown")
            item.view = button
        case "theme":
            item.label = "Appearance"
            let button = NSButton(title: "Appearance ▾", target: self, action: #selector(showTheme))
            button.font = .systemFont(ofSize: 12)
            button.bezelStyle = .texturedRounded
            button.isBordered = false
            button.toolTip = "Choose Light, Dark, or System appearance"
            button.setAccessibilityLabel("Appearance menu")
            item.view = button
        case "type":
            item.label = "Text appearance"
            let button = NSButton(title: "Aa", target: self, action: #selector(showAppearance))
            button.font = .systemFont(ofSize: 17, weight: .medium)
            button.bezelStyle = .texturedRounded
            button.isBordered = false
            button.toolTip = "Typeface and text size"
            button.setAccessibilityLabel("Text appearance")
            item.view = button
        case "focus":
            item.label = "Focus mode"
            item.toolTip = "Focus mode (⇧⌘F); Escape to leave"
            item.image = NSImage(systemSymbolName: "viewfinder", accessibilityDescription: item.label)
            item.target = self; item.action = #selector(toggleFocus)
        case "collapse":
            item.label = "Collapse top bar"
            item.toolTip = "Hide top bar (⇧⌘T)"
            item.image = NSImage(systemSymbolName: "chevron.up", accessibilityDescription: item.label)
            item.target = self; item.action = #selector(toggleToolbar)
        default: return nil
        }
        return item
    }

    private func loadReader() {
        let bundle = Bundle.main.resourceURL!
        do {
            var html = try String(contentsOf: bundle.appendingPathComponent("reader.html"), encoding: .utf8)
            for (token, file) in [("/*STILL_STYLE*/", "reader.css"), ("/*STILL_MARKED*/", "marked.js"), ("/*STILL_PURIFY*/", "purify.js"), ("/*STILL_READER*/", "reader.js")] {
                html = html.replacingOccurrences(of: token, with: try String(contentsOf: bundle.appendingPathComponent(file), encoding: .utf8))
            }
            webView.loadHTMLString(html, baseURL: nil)
        } catch { showError("Still couldn’t load its reader.", detail: error.localizedDescription) }
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame,
              let body = message.body as? [String: Any], let action = body["action"] as? String else { return }
        switch action {
        case "ready":
            ready = true
            applyPreferences()
            if let pendingFile { self.pendingFile = nil; open(pendingFile) }
        case "open": openPanel()
        case "escape": escape()
        case "scroll":
            if let currentFile, let position = body["position"] as? Double {
                var positions = defaults.dictionary(forKey: "positions") ?? [:]
                positions[currentFile.path] = min(1, max(0, position))
                if positions.count > 100 { positions = [currentFile.path: position] }
                defaults.set(positions, forKey: "positions")
            }
        case "headings":
            let headings = body["items"] as? [[String: Any]] ?? []
            documentIndex.update(headings, documentKey: currentFile?.path)
            updateSidebarSections()
            contentsMenu.removeAllItems()
            for heading in headings {
                guard let text = heading["text"] as? String, let id = heading["id"] as? String else { continue }
                let item = menuItem(text, #selector(jumpToHeading))
                item.representedObject = id
                item.indentationLevel = max(0, (heading["level"] as? Int ?? 1) - 1)
                contentsMenu.addItem(item)
            }
            if contentsMenu.items.isEmpty { contentsMenu.addItem(NSMenuItem(title: "No headings in this document", action: nil, keyEquivalent: "")) }
        case "activeHeading":
            documentIndex.setActiveHeading(body["id"] as? String)
        case "link":
            if let string = body["url"] as? String { followLink(string) }
        default: break
        }
    }

    @objc private func openPanel() {
        let panel = NSOpenPanel()
        // Markdown UTI registration varies between installed editors. Filter extensions
        // through the native panel delegate so valid .md files are always selectable.
        panel.allowsOtherFileTypes = true
        panel.delegate = self
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.title = "Open Markdown"
        panel.prompt = "Read"
        panel.beginSheetModal(for: window) { [weak self] response in
            if response == .OK, let url = panel.url { self?.open(url) }
        }
    }

    func panel(_ sender: Any, shouldEnable url: URL) -> Bool {
        if url.hasDirectoryPath { return true }
        return ["md", "markdown"].contains(url.pathExtension.lowercased())
    }

    private func open(_ url: URL) {
        let file = url.standardizedFileURL
        guard ["md", "markdown"].contains(file.pathExtension.lowercased()) else {
            showError("Choose a Markdown file.", detail: "Still reads .md and .markdown files."); return
        }
        guard ready else { pendingFile = file; return }
        do {
            let markdown = try read(file)
            monitor?.cancel()
            currentFile = file
            source = markdown
            images.directory = file.deletingLastPathComponent()
            window.title = file.lastPathComponent
            window.representedURL = file
            searchField.stringValue = ""
            hideFind()
            let positions = defaults.dictionary(forKey: "positions") ?? [:]
            render(position: positions[file.path] as? Double ?? 0)
            recentFiles.removeAll { $0 == file }
            recentFiles.insert(file, at: 0)
            recentFiles = Array(recentFiles.prefix(10))
            defaults.set(recentFiles.map(\.path), forKey: "recentFiles")
            updateRecentMenu()
            updateSidebar()
            monitor = FileMonitor(file) { [weak self] in self?.reload(showErrors: false) }
            window.makeKeyAndOrderFront(nil)
        } catch { showError("This file couldn’t be opened.", detail: error.localizedDescription) }
    }

    private func read(_ url: URL) throws -> String {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true else { throw ReaderError.message("Choose a file, rather than a folder.") }
        guard (values.fileSize ?? 0) <= 25_000_000 else { throw ReaderError.message("This document is larger than Still’s 25 MB reading limit.") }
        let data = try Data(contentsOf: url)
        if let text = String(data: data, encoding: .utf8) { return text }
        if data.starts(with: [0xff, 0xfe]) || data.starts(with: [0xfe, 0xff]), let text = String(data: data, encoding: .utf16) { return text }
        throw ReaderError.message("The document must use UTF-8 or UTF-16 text encoding.")
    }

    private func render(position: Double? = nil) {
        guard let currentFile else { return }
        var arguments: [String: Any] = ["markdown": source, "filename": currentFile.lastPathComponent]
        arguments["position"] = position ?? NSNull()
        webView.callAsyncJavaScript("window.still.render(markdown, filename, position)", arguments: arguments, in: nil, in: .page) { [weak self] result in
            if case .failure(let error) = result { self?.showError("This document couldn’t be rendered.", detail: error.localizedDescription) }
        }
    }

    private func reload(showErrors: Bool) {
        guard let currentFile else { return }
        do {
            let updated = try read(currentFile)
            guard updated != source else { return }
            source = updated
            render()
            searchResult.stringValue = ""
        } catch {
            if showErrors { showError("The document couldn’t be refreshed.", detail: error.localizedDescription) }
        }
    }

    @objc private func refresh() { reload(showErrors: true) }
    func windowDidBecomeKey(_ notification: Notification) { reload(showErrors: false) }

    private func followLink(_ string: String) {
        guard let url = URL(string: string) else { return }
        if ["https", "http", "mailto"].contains(url.scheme?.lowercased() ?? "") { NSWorkspace.shared.open(url); return }
        if url.scheme == nil, let currentFile,
           let destination = URL(string: string, relativeTo: currentFile.deletingLastPathComponent().appendingPathComponent(""))?.absoluteURL,
           destination.isFileURL, ["md", "markdown"].contains(destination.pathExtension.lowercased()) {
            open(destination)
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if navigationAction.navigationType == .other && navigationAction.request.url?.absoluteString == "about:blank" { decisionHandler(.allow); return }
        if navigationAction.navigationType == .linkActivated, let url = navigationAction.request.url { followLink(url.absoluteString) }
        decisionHandler(.cancel)
    }

    private func applyPreferences() {
        guard window != nil else { return }
        let dark = theme == "dusk" || (theme == "system" && NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua)
        window.appearance = theme == "system" ? nil : NSAppearance(named: dark ? .darkAqua : .aqua)
        window.backgroundColor = dark ? NSColor(calibratedWhite: 0.13, alpha: 1) : .white
        if ready {
            webView.callAsyncJavaScript("window.still.preferences(theme, typeface, size)", arguments: ["theme": theme, "typeface": typeface, "size": fontSize], in: nil, in: .page, completionHandler: nil)
        }
        for item in appearanceMenu?.items ?? [] {
            if let value = item.representedObject as? String { item.state = value == typeface ? .on : .off }
        }
        for item in themeMenu?.items ?? [] {
            if let value = item.representedObject as? String { item.state = value == theme ? .on : .off }
        }
        sidebar?.layer?.backgroundColor = (dark ? NSColor(calibratedWhite: 0.105, alpha: 1) : NSColor(calibratedWhite: 0.975, alpha: 1)).cgColor
        updateSidebar()
    }

    @objc private func changeTheme(_ sender: NSMenuItem) { defaults.set(sender.representedObject as? String, forKey: "theme"); applyPreferences() }
    @objc private func changeTypeface(_ sender: NSMenuItem) { defaults.set(sender.representedObject as? String, forKey: "typeface"); applyPreferences() }
    @objc private func largerType() { defaults.set(min(28, fontSize + 1), forKey: "fontSize"); applyPreferences() }
    @objc private func smallerType() { defaults.set(max(14, fontSize - 1), forKey: "fontSize"); applyPreferences() }
    @objc private func resetType() { defaults.set(17, forKey: "fontSize"); applyPreferences() }

    @objc private func toggleFocus() {
        if !focus {
            sidebarBeforeFocus = sidebarVisible
            toolbarBeforeFocus = toolbarVisible
            hideFind()
            setSidebar(false)
            toolbar.isVisible = false
            toolbarReveal.isHidden = true
            toolbarReveal.view.isHidden = true
        } else {
            setSidebar(sidebarBeforeFocus)
            toolbar.isVisible = toolbarBeforeFocus
            toolbarReveal.isHidden = toolbarBeforeFocus
            toolbarReveal.view.isHidden = toolbarBeforeFocus
        }
        focus.toggle()
        window.titleVisibility = .hidden
        for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] { window.standardWindowButton(kind)?.isHidden = focus }
        webView.callAsyncJavaScript("window.still.focus(enabled)", arguments: ["enabled": focus], in: nil, in: .page, completionHandler: nil)
        window.makeFirstResponder(webView)
    }

    private func escape() { if findVisible { hideFind() } else if focus { toggleFocus() } }
    @objc private func showFind() {
        if focus { toggleFocus() }
        findVisible = true
        searchBar.isHidden = false
        searchHeight.constant = 44
        window.makeFirstResponder(searchField)
        searchField.selectText(nil)
    }
    @objc private func hideFind() {
        findVisible = false
        searchHeight.constant = 0
        searchBar.isHidden = true
        if webView != nil { window.makeFirstResponder(webView) }
    }
    func controlTextDidChange(_ obj: Notification) { find(backwards: false) }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) { hideFind(); return true }
        if commandSelector == #selector(NSResponder.insertNewline(_:)) { find(backwards: NSApp.currentEvent?.modifierFlags.contains(.shift) == true); return true }
        return false
    }
    @objc private func findNext() { if findVisible { find(backwards: false) } else { showFind() } }
    @objc private func findPrevious() { if findVisible { find(backwards: true) } else { showFind() } }
    private func find(backwards: Bool) {
        let configuration = WKFindConfiguration()
        configuration.backwards = backwards
        configuration.caseSensitive = false
        configuration.wraps = true
        findRequest += 1
        let request = findRequest
        webView.find(searchField.stringValue, configuration: configuration) { [weak self] result in
            guard let self, request == self.findRequest else { return }
            self.searchResult.stringValue = self.searchField.stringValue.isEmpty ? "" : (result.matchFound ? "" : "No matches")
        }
    }

    @objc private func showAppearance(_ sender: Any?) { appearanceMenu.popUp(positioning: nil, at: window.mouseLocationOutsideOfEventStream, in: window.contentView) }
    @objc private func showTheme(_ sender: Any?) {
        if let button = sender as? NSButton {
            themeMenu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.isFlipped ? button.bounds.maxY : button.bounds.minY), in: button)
        } else {
            themeMenu.popUp(positioning: nil, at: window.mouseLocationOutsideOfEventStream, in: window.contentView)
        }
    }
    @objc private func showIndex() {
        if focus { toggleFocus() }
        setSidebar(true)
        indexExpanded = true
        defaults.set(true, forKey: "sidebarVisible")
        defaults.set(true, forKey: "indexExpanded")
        updateSidebarSections()
        window.makeFirstResponder(documentIndex.outline)
    }
    @objc private func jumpToHeading(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        navigateToHeading(id)
    }
    private func navigateToHeading(_ id: String) {
        documentIndex.setActiveHeading(id)
        webView.callAsyncJavaScript("window.still.jump(id)", arguments: ["id": id], in: nil, in: .page, completionHandler: nil)
    }
    @objc private func openRecent(_ sender: NSMenuItem) { if let url = sender.representedObject as? URL { open(url) } }
    @objc private func clearRecents() { recentFiles = []; defaults.removeObject(forKey: "recentFiles"); updateRecentMenu(); updateSidebar() }
    @objc private func revealFile() { if let currentFile { NSWorkspace.shared.activateFileViewerSelecting([currentFile]) } }
    @objc private func closeDocument() {
        monitor?.cancel(); monitor = nil
        currentFile = nil; source = ""; images.directory = nil
        documentIndex.update([], documentKey: nil)
        updateSidebar()
        window.title = "Still"; window.representedURL = nil
        hideFind()
        contentsMenu.removeAllItems()
        webView.callAsyncJavaScript("window.still.empty()", arguments: [:], in: nil, in: .page, completionHandler: nil)
    }

    private func showError(_ message: String, detail: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = detail
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        if let window { alert.beginSheetModal(for: window) } else { alert.runModal() }
    }

    private func menuItem(_ title: String, _ action: Selector?, key: String = "", modifiers: NSEvent.ModifierFlags = .command) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        item.keyEquivalentModifierMask = modifiers
        return item
    }
    private func submenu(_ title: String, in parent: NSMenu) -> NSMenu {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let menu = NSMenu(title: title)
        item.submenu = menu
        parent.addItem(item)
        return menu
    }
    private func makeMenus() {
        let main = NSMenu()
        let app = submenu("Still", in: main)
        let about = NSMenuItem(title: "About Still", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        app.addItem(about)
        app.addItem(.separator())
        let services = submenu("Services", in: app)
        NSApp.servicesMenu = services
        app.addItem(.separator())
        app.addItem(NSMenuItem(title: "Hide Still", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h"))
        let hideOthers = NSMenuItem(title: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        app.addItem(hideOthers)
        app.addItem(.separator())
        app.addItem(NSMenuItem(title: "Quit Still", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        let file = submenu("File", in: main)
        file.addItem(menuItem("Open Markdown…", #selector(openPanel), key: "o"))
        recentMenu = submenu("Open Recent", in: file)
        updateRecentMenu()
        file.addItem(.separator())
        file.addItem(menuItem("Refresh", #selector(refresh), key: "r"))
        file.addItem(menuItem("Reveal in Finder", #selector(revealFile)))
        file.addItem(menuItem("Close Document", #selector(closeDocument), key: "w", modifiers: [.command, .shift]))
        file.addItem(NSMenuItem(title: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"))

        let edit = submenu("Edit", in: main)
        edit.addItem(NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        edit.addItem(NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        edit.addItem(.separator())
        edit.addItem(menuItem("Find…", #selector(showFind), key: "f"))
        edit.addItem(menuItem("Find Next", #selector(findNext), key: "g"))
        edit.addItem(menuItem("Find Previous", #selector(findPrevious), key: "g", modifiers: [.command, .shift]))

        let view = submenu("View", in: main)
        view.addItem(menuItem("Show Sidebar", #selector(toggleSidebar), key: "s", modifiers: [.command, .option]))
        view.addItem(menuItem("Show Index", #selector(showIndex), key: "i", modifiers: [.command, .shift]))
        view.addItem(menuItem("Show Top Bar", #selector(toggleToolbar), key: "t", modifiers: [.command, .shift]))
        view.addItem(.separator())
        view.addItem(menuItem("Focus Mode", #selector(toggleFocus), key: "f", modifiers: [.command, .shift]))
        view.addItem(.separator())
        view.addItem(menuItem("Larger Text", #selector(largerType), key: "+"))
        view.addItem(menuItem("Smaller Text", #selector(smallerType), key: "-"))
        view.addItem(menuItem("Actual Size", #selector(resetType), key: "0"))
        themeMenu = submenu("Appearance", in: view)
        for (title, value) in [("Light", "paper"), ("Dark", "dusk"), ("System", "system")] {
            let item = menuItem(title, #selector(changeTheme)); item.representedObject = value; themeMenu.addItem(item)
        }
        themeMenu.items.last?.toolTip = "Follow the macOS appearance preference"
        appearanceMenu = submenu("Text Appearance", in: view)
        for (title, value) in [("Serif", "serif"), ("Sans Serif", "sans")] {
            let item = menuItem(title, #selector(changeTypeface)); item.representedObject = value; appearanceMenu.addItem(item)
        }
        appearanceMenu.addItem(.separator())
        appearanceMenu.addItem(menuItem("Larger Text", #selector(largerType)))
        appearanceMenu.addItem(menuItem("Smaller Text", #selector(smallerType)))
        contentsMenu = submenu("Contents", in: view)
        contentsMenu.addItem(NSMenuItem(title: "Open a document to see headings", action: nil, keyEquivalent: ""))
        let windowMenu = submenu("Window", in: main)
        windowMenu.addItem(NSMenuItem(title: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m"))
        let maximize = NSMenuItem(title: "Maximize or Restore", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "f")
        maximize.keyEquivalentModifierMask = [.command, .control]
        windowMenu.addItem(maximize)
        NSApp.windowsMenu = windowMenu
        NSApp.mainMenu = main
    }

    func windowWillUseStandardFrame(_ window: NSWindow, defaultFrame newFrame: NSRect) -> NSRect {
        window.screen?.visibleFrame ?? newFrame
    }
    private func updateRecentMenu() {
        recentMenu.removeAllItems()
        for file in recentFiles {
            let item = menuItem(file.lastPathComponent, #selector(openRecent))
            item.representedObject = file; item.toolTip = file.path
            recentMenu.addItem(item)
        }
        if !recentFiles.isEmpty { recentMenu.addItem(.separator()); recentMenu.addItem(menuItem("Clear Menu", #selector(clearRecents))) }
    }
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(toggleFocus) { menuItem.state = focus ? .on : .off }
        if menuItem.action == #selector(toggleSidebar) { menuItem.state = sidebarVisible ? .on : .off }
        if menuItem.action == #selector(toggleToolbar) { menuItem.state = toolbar.isVisible ? .on : .off }
        if [#selector(refresh), #selector(revealFile), #selector(closeDocument), #selector(showFind), #selector(findNext), #selector(findPrevious)].contains(menuItem.action) { return currentFile != nil }
        return true
    }
}

enum ReaderError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}
