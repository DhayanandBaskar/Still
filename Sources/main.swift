import AppKit
import WebKit
import UniformTypeIdentifiers

let application = NSApplication.shared
let delegate = ReaderApp()
application.delegate = delegate
application.setActivationPolicy(.regular)
application.run()
