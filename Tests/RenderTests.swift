import AppKit
import WebKit

final class CapturedImageTask: NSObject, WKURLSchemeTask {
    let request: URLRequest
    var data: Data?
    var finished = false
    var error: Error?
    init(_ url: String) { request = URLRequest(url: URL(string: url)!) }
    func didReceive(_ response: URLResponse) {}
    func didReceive(_ data: Data) { self.data = data }
    func didFinish() { finished = true }
    func didFailWithError(_ error: Error) { self.error = error }
}

@main
struct RenderTests {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let runner = TestRunner()
        app.delegate = runner
        app.run()
    }
}

final class TestRunner: NSObject, NSApplicationDelegate, WKScriptMessageHandler {
    private var webView: WKWebView!
    private var window: NSWindow!
    private var started = false
    private var checks = 0
    private var fixtures: URL!
    private let images = LocalImages()
    private var capturedHeadings: [[String: Any]] = []
    private var activeHeadings: [String] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            fixtures = FileManager.default.temporaryDirectory.appendingPathComponent("still-tests-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: fixtures, withIntermediateDirectories: true)
            try "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"30\" height=\"20\"><rect width=\"30\" height=\"20\" fill=\"blue\"/></svg>".write(to: fixtures.appendingPathComponent("cover image.svg"), atomically: true, encoding: .utf8)
            images.directory = fixtures
            let config = WKWebViewConfiguration()
            config.websiteDataStore = .nonPersistent()
            config.userContentController.add(self, name: "reader")
            config.setURLSchemeHandler(images, forURLScheme: "still-image")
            webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 900, height: 650), configuration: config)
            window = NSWindow(contentRect: NSRect(x: -3000, y: 0, width: 900, height: 650), styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = webView
            window.orderFront(nil)
            let resources = URL(fileURLWithPath: CommandLine.arguments[1])
            var html = try String(contentsOf: resources.appendingPathComponent("reader.html"), encoding: .utf8)
            for (token, filename) in [("/*STILL_STYLE*/", "reader.css"), ("/*STILL_MARKED*/", "marked.js"), ("/*STILL_PURIFY*/", "purify.js"), ("/*STILL_READER*/", "reader.js")] {
                html = html.replacingOccurrences(of: token, with: try String(contentsOf: resources.appendingPathComponent(filename), encoding: .utf8))
            }
            webView.loadHTMLString(html, baseURL: nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 20) { self.finish(error: "Timed out loading the actual WKWebView reader") }
        } catch { finish(error: error.localizedDescription) }
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let value = message.body as? [String: Any], let action = value["action"] as? String else { return }
        if action == "headings" { capturedHeadings = value["items"] as? [[String: Any]] ?? []; return }
        if action == "activeHeading" { if let id = value["id"] as? String { activeHeadings.append(id) }; return }
        guard action == "ready", !started else { return }
        started = true
        testLocalImages()
        let script = #"""
        const results = [];
        function check(name, condition) { results.push({name, pass: Boolean(condition)}); }
        const markdown = '# Hello, reader\n\nA **bold** word and *quiet* thought.\n\n## Details\n\n> A quote\n\n- [x] Finished\n- [ ] To read\n\n| Name | Value |\n| --- | --- |\n| Still | 42 |\n\n```swift\nlet html = "<script>literal</script>"\n```\n\n~~gone~~\n\n![Local image](cover%20image.svg)';
        window.still.render(markdown, 'notes.md', 0);
        const article = document.getElementById('article');
        check('GFM headings and inline styles', article.querySelectorAll('h1,h2').length === 2 && article.querySelector('strong')?.textContent === 'bold');
        check('Quotes, tables, and strikethrough', article.querySelector('blockquote') && article.querySelector('table td')?.textContent === 'Still' && article.querySelector('del'));
        check('Task lists cannot be edited', article.querySelectorAll('input').length === 0 && article.querySelectorAll('.task-box').length === 2 && article.querySelectorAll('.task-box.checked').length === 1);
        check('Code content is preserved', article.querySelector('pre code')?.textContent.includes('<script>literal</script>') && article.querySelector('.code-language')?.textContent === 'swift');
        check('Headings can be navigated', article.querySelector('h2')?.id === 'still-heading-1');
        check('Relative images use the native image handler', article.querySelector('img')?.getAttribute('src') === 'still-image://document/cover%20image.svg');
        const image = article.querySelector('img');
        await Promise.race([new Promise(resolve => { if (image.complete) resolve(); else { image.onload = resolve; image.onerror = resolve; } }), new Promise(resolve => setTimeout(resolve, 3000))]);
        check('Local image actually loads in WebKit', image.naturalWidth === 30);
        check('Document and reading time are visible', !document.getElementById('document').hidden && document.getElementById('welcome').hidden && document.getElementById('reading-time').textContent === '1 min read');
        const hostile = '<script>window.__owned = true</script><img src="missing.svg" onerror="window.__owned=true"><iframe srcdoc="<script>alert(1)</script>"></iframe><form><input autofocus type="text"><button>Send</button></form><div contenteditable="true" style="position:fixed">safe words</div><a href="javascript:window.__owned=true">bad link</a><svg onload="window.__owned=true"></svg>';
        window.still.render(hostile, 'hostile.md', 0);
        await new Promise(resolve => setTimeout(resolve, 150));
        check('Document scripts and embedded frames are removed', !article.querySelector('script,iframe,object,embed,svg,form,button,input') && window.__owned === undefined);
        check('Editable DOM, event handlers, and document styles are removed', !article.querySelector('[contenteditable],[onerror],[onload],[style]'));
        check('Script links cannot survive sanitization', !article.querySelector('a')?.hasAttribute('href'));
        window.still.render('![Secret](file:///etc/passwd)\n\n![Absolute](/etc/passwd)', 'paths.md', 0);
        check('Absolute local images are blocked', Array.from(article.querySelectorAll('img')).every(image => !image.hasAttribute('src')));
        window.still.render('', 'empty.md', 0);
        check('Empty files have a useful empty state', !document.getElementById('empty-document').hidden);
        window.still.preferences('dusk', 'sans', 22);
        check('Appearance and text size apply', document.documentElement.dataset.theme === 'dusk' && document.documentElement.style.getPropertyValue('--body-size') === '22px');
        window.still.focus(true);
        check('Focus mode is available', document.body.classList.contains('focus'));
        window.still.empty();
        check('Closing a document clears its content', article.textContent === '' && !document.getElementById('welcome').hidden && document.getElementById('document').hidden);
        window.still.focus(false);
        const prose = ('A quiet paragraph with enough room to read.\n\n').repeat(35);
        window.still.render('# Title\n\n' + prose + '## Section\n\n' + prose + '### Detail\n\n' + prose, 'index.md', 0);
        await new Promise(resolve => setTimeout(resolve, 250));
        window.still.jump('still-heading-2');
        await new Promise(resolve => setTimeout(resolve, 900));
        check('Index navigation scrolls to the requested heading', window.scrollY > 0 && Math.abs(document.getElementById('still-heading-2').getBoundingClientRect().top - 38) < 4);
        return results;
        """#
        webView.callAsyncJavaScript(script, arguments: [:], in: nil, in: .page) { result in
            switch result {
            case .failure(let error): self.finish(error: error.localizedDescription)
            case .success(let value):
                guard let rows = value as? [[String: Any]] else { self.finish(error: "Invalid test result") }
                var failures: [String] = []
                for row in rows {
                    let name = row["name"] as? String ?? "Unnamed check"
                    let pass = row["pass"] as? Bool ?? false
                    print("\(pass ? "PASS" : "FAIL") \(name)")
                    self.checks += 1
                    if !pass { failures.append(name) }
                }
                let hierarchy = self.capturedHeadings.compactMap { $0["level"] as? Int }
                let hierarchyPass = hierarchy == [1, 2, 3] && self.capturedHeadings.compactMap { $0["text"] as? String } == ["Title", "Section", "Detail"]
                print("\(hierarchyPass ? "PASS" : "FAIL") Renderer sends the native index its full heading hierarchy")
                self.checks += 1
                if !hierarchyPass { failures.append("Native heading hierarchy") }
                let activePass = self.activeHeadings.contains("still-heading-0") && self.activeHeadings.last == "still-heading-2"
                if !activePass { print("Observed active headings: \(self.activeHeadings)") }
                print("\(activePass ? "PASS" : "FAIL") Reading position updates the active index heading")
                self.checks += 1
                if !activePass { failures.append("Active heading updates") }
                self.finish(error: failures.isEmpty ? nil : failures.joined(separator: ", "))
            }
        }
    }

    private func testLocalImages() {
        let allowed = CapturedImageTask("still-image://document/cover%20image.svg")
        images.webView(webView, start: allowed)
        assert(allowed.finished && allowed.data != nil, "Image with a space in its name must load")
        checks += 1; print("PASS Native handler serves images with spaces")
        for url in ["still-image://document/..%2F..%2Fetc%2Fpasswd", "still-image://document/%2Fetc%2Fpasswd", "still-image://other/cover%20image.svg", "still-image://document/missing.svg"] {
            let blocked = CapturedImageTask(url)
            images.webView(webView, start: blocked)
            assert(blocked.error != nil && blocked.data == nil, "Blocked image path was served")
            checks += 1
        }
        print("PASS Native handler rejects traversal, absolute paths, other hosts, and missing images")
    }

    private func finish(error: String?) -> Never {
        if let fixtures { try? FileManager.default.removeItem(at: fixtures) }
        if let error { fputs("FAIL \(error)\n", stderr); exit(1) }
        print("\(checks) checks passed in real macOS WebKit.")
        exit(0)
    }
}
