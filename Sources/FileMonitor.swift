import Foundation
import Darwin

/// Observe both direct writes and atomic replacements, without writing to the document.
final class FileMonitor {
    private let file: URL
    private let changed: () -> Void
    private let queue = DispatchQueue(label: "still.file-monitor", qos: .utility)
    private let lock = NSLock()
    private var directorySource: DispatchSourceFileSystemObject?
    private var fileSource: DispatchSourceFileSystemObject?
    private var pending: DispatchWorkItem?
    private var cancelled = false

    init(_ file: URL, changed: @escaping () -> Void) {
        self.file = file
        self.changed = changed
        // Opening a directory can wait for macOS privacy or a cloud provider.
        // Keep both that operation and monitor reattachment off the reading UI.
        queue.async { [weak self] in
            guard let self, !self.isCancelled else { return }
            self.attachFile()
            self.directorySource = self.source(file.deletingLastPathComponent(), events: [.write, .rename, .delete])
        }
    }

    private var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }

    private func source(_ url: URL, events: DispatchSource.FileSystemEvent) -> DispatchSourceFileSystemObject? {
        guard !isCancelled else { return nil }
        let descriptor = Darwin.open(url.path, O_EVTONLY)
        guard descriptor >= 0 else { return nil }
        guard !isCancelled else { Darwin.close(descriptor); return nil }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: events, queue: queue)
        source.setEventHandler { [weak self] in self?.schedule() }
        source.setCancelHandler { Darwin.close(descriptor) }
        source.resume()
        return source
    }

    private func attachFile() {
        fileSource?.cancel()
        fileSource = source(file, events: [.write, .extend, .attrib, .rename, .delete])
    }

    private func schedule() {
        guard !isCancelled else { return }
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.isCancelled else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.isCancelled else { return }
                self.changed()
            }
            // A directory event may signal a replacement inode, even if its text is identical.
            self.attachFile()
        }
        pending = work
        queue.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    func cancel() {
        lock.lock(); cancelled = true; lock.unlock()
        queue.async { [self] in stopSources() }
    }

    private func stopSources() {
        pending?.cancel()
        directorySource?.cancel()
        fileSource?.cancel()
        directorySource = nil
        fileSource = nil
    }

    deinit { stopSources() }
}
