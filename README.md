# Still

A small, native macOS app for reading Markdown. A clean white page inspired by Typora, comfortable typography, and a quiet window. **It never edits or saves your Markdown files.**

**Free and open source under [Apache 2.0](LICENSE).** [Download for Mac](https://github.com/DhayanandBaskar/Still/releases/latest/download/Still.dmg) · [Screenshots and setup guide](https://dhayanandbaskar.github.io/apps/still/) · [Release notes and checksum](https://github.com/DhayanandBaskar/Still/releases/latest)

![Still reading its bundled Welcome.md with a nested heading outline](https://dhayanandbaskar.github.io/apps/assets/screenshots/still-reader.jpg)

## Run

Download the DMG from this repository’s Releases, open it, and drag **Still** into **Applications**. Launch Still, then open or drop a `.md` or `.markdown` file. Finder’s **Open With → Still** also works. A local source build produces `build/Still.app`, which can also be launched directly.

Requires macOS 13 or newer. The downloadable build runs on Apple silicon. Intel users can build from source on their Mac using the same script. The release is signed ad hoc and is not notarized. If macOS blocks the first launch, use **System Settings → Privacy & Security → Open Anyway** for Still.

## Build from source

Apple’s Command Line Tools are sufficient; no Xcode project, npm install, or network connection is needed.

```sh
./scripts/build.sh
open build/Still.app
```

To open a file directly:

```sh
open -a "$PWD/build/Still.app" "$PWD/Resources/Welcome.md"
```

To build a disk image with the app and an Applications shortcut:

```sh
./scripts/make-dmg.sh
```

The DMG and its SHA-256 checksum appear in `build/`. Use `./scripts/make-dmg.sh --skip-build` to package an existing build.

To keep a release build separate from your development app:

```sh
STILL_BUILD_DIR="$PWD/build/release" ./scripts/make-dmg.sh
```

## Reading

| Shortcut | Action |
| --- | --- |
| ⌘O | Open a Markdown file |
| ⇧⌘F | Enter or leave focus mode |
| ⌥⌘S | Show or hide the recent-files sidebar |
| ⇧⌘I | Show and focus the document index |
| ⇧⌘T | Show or hide the top bar |
| Escape | Leave focus mode or close find |
| ⌘F | Find text |
| ⌘G / ⇧⌘G | Next / previous match |
| ⌘+ / ⌘− / ⌘0 | Larger / smaller / default text |
| ⌘R | Refresh |
| ⌃⌘F | Maximize or restore the window |
| ⇧⌘W | Close the current document |

Use the labeled **Open** button at the top to choose a file. The sidebar places a nested **Index** above **Recent Files**. Click a heading to jump to that section; disclosure arrows collapse individual branches, and the current section is highlighted as you scroll. Long heading labels wrap. Click either section header to collapse or expand it independently; both choices are remembered. Files without headings have a quiet empty state. The ten most recent documents appear below the index; click one to reopen it. Drag the divider to resize the sidebar or collapse the whole sidebar with its button. The top bar also collapses with its up arrow. A small down arrow remains in the title bar to restore it. Focus mode hides both and restores their previous state when you leave.

The sidebar starts with **70% of its height for Index and 30% for Recent Files**. Drag the horizontal divider between them to adjust that balance; the app remembers your split and preserves it when the window resizes. Each section scrolls independently with its header always visible. Collapsing one section gives the other the available space, and expanding it restores your chosen split.

The compact top bar uses the standard macOS traffic lights: red closes, yellow minimizes, and green maximizes to the available screen space. Click green again to restore the previous window size. These controls remain available when the app toolbar is collapsed.

Use the top-bar **Appearance ▾** menu to choose **Light**, **Dark**, or **System**. System follows the macOS appearance preference and updates when it changes. The selected option is checked, and the choice is remembered between launches. Use **Aa** for serif or sans serif text and text size. Recent files, window size, sidebar visibility, and reading position are also remembered locally. Index branches keep their collapsed state when an external editor saves the current file.

Documents update automatically when another editor saves, including editors that replace files atomically. The app watches the containing directory and also refreshes when it regains focus. If a file is temporarily unavailable, the last readable version stays on screen.

## Markdown support

Headings, lists, read-only task lists, quotes, links, fenced code, tables, strikethrough, images, and safe HTML. Code blocks show their language and preserve whitespace; syntax highlighting, math, and Mermaid rendering are outside this small app’s scope.

Relative images inside the document’s folder are supported, including nested folders and spaces. Images outside that folder are blocked. HTTPS/HTTP images load from their original hosts. External web and email links open in the default app. Relative Markdown links open in Still. UTF-8 and BOM-marked UTF-16 documents are supported, up to 25 MB.

## Implementation

The window, menus, file picker, drag and drop, and search are native AppKit. A WKWebView renders the reading page with locally bundled [Marked](https://marked.js.org/) 18.1.0 and [DOMPurify](https://github.com/cure53/DOMPurify) 3.4.16. The app uses a nonpersistent WebKit data store; document HTML is sanitized, scripts and forms are removed, and the reader’s content security policy blocks document connections and navigation. A custom scheme handler serves only image files inside the opened document’s folder. No source-file write API exists in the application.

Third-party licenses and pinned resource hashes are included under `Resources/`. Preferences are stored in the app’s own UserDefaults domain.

## Verification

Run `./scripts/test.sh` to check the actual reader in macOS WebKit. This verifies GFM rendering, preserved code text, local image loading, heading targets, empty files, appearance controls, read-only task lists, and removal of document scripts, forms, event handlers, and editable elements. Native image-handler checks cover path traversal and invalid requests. File-monitor checks exercise in-place saves, atomic replacement, writes to the new inode, and deletion followed by recreation. The test harnesses create disposable fixtures in the system temporary directory.

Run `bash scripts/test-window.sh` to check the actual app window: compact toolbar, visible traffic lights, maximize and restore, nested heading navigation, independent section collapse, the adjustable 70/30 split, separate scrolling, toolbar collapse and expansion, minimize, and close. AppKit checks require a macOS desktop session.

## License

Copyright 2026 Dhayanand Baskar. Still's original source code is licensed under the [Apache License, Version 2.0](LICENSE). See [NOTICE](NOTICE) for attribution. Marked and DOMPurify retain their own licenses, included under `Resources/` and inside the app bundle. The downloadable DMG also includes LICENSE and NOTICE.
