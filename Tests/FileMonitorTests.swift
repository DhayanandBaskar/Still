import Foundation
import Darwin

@main
struct FileMonitorTests {
    static var monitor: FileMonitor?
    static var stage = 0
    static var directory: URL!

    static func main() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("still-monitor-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("reading.md")
        try "initial".write(to: file, atomically: false, encoding: .utf8)
        monitor = FileMonitor(file) {
            guard let value = try? String(contentsOf: file, encoding: .utf8) else { return }
            switch (stage, value) {
            case (0, "direct write"):
                print("PASS In-place editor saves are observed")
                stage = 1
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    let replacement = directory.appendingPathComponent("replacement.tmp")
                    try! "atomic replacement".write(to: replacement, atomically: false, encoding: .utf8)
                    precondition(Darwin.rename(replacement.path, file.path) == 0)
                }
            case (1, "atomic replacement"):
                print("PASS Atomic editor saves are observed")
                stage = 2
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    try! "write to replacement".write(to: file, atomically: false, encoding: .utf8)
                }
            case (2, "write to replacement"):
                print("PASS The watcher follows the replacement inode")
                stage = 3
                try! FileManager.default.removeItem(at: file)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    try! "recreated file".write(to: file, atomically: false, encoding: .utf8)
                }
            case (3, "recreated file"):
                print("PASS A temporarily deleted file can reappear")
                monitor?.cancel()
                try! FileManager.default.removeItem(at: directory)
                print("4 file monitoring checks passed.")
                exit(0)
            default: break
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            try! "direct write".write(to: file, atomically: false, encoding: .utf8)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
            monitor?.cancel()
            try? FileManager.default.removeItem(at: directory)
            fputs("FAIL File monitoring stopped at stage \(stage)\n", stderr)
            exit(1)
        }
        RunLoop.main.run()
    }
}
