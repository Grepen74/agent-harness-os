import Darwin
import Foundation
import Synchronization

/// One harness per repo storage: an exclusive `flock` on `<storage>/harness.lock`, held while a window has the repo
/// open. Two windows or two copies of the app on one repo would each append to the ledger from their own memory and
/// fork its chain; the second one gets `StorageLock.Busy` instead.
public final class StorageLock: Sendable {
    public struct Busy: Error, CustomStringConvertible {
        public let directory: URL
        /// The process that holds the lock, as it wrote it into the lock file.
        public let holder: String?

        public var description: String {
            "This repo is open in another AgentOS window or app" + (holder.map { " (\($0))" } ?? "")
                + ". Close it there, then rescan here."
        }
    }

    private let descriptor: Mutex<Int32?>

    public init(directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appending(path: "harness.lock").path
        let descriptor = open(path, O_RDWR | O_CREAT | O_CLOEXEC, 0o644)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            close(descriptor)
            guard code == EWOULDBLOCK else { throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO) }
            let holder = (try? String(contentsOfFile: path, encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw Busy(directory: directory, holder: holder?.isEmpty == false ? holder : nil)
        }
        let info = ProcessInfo.processInfo
        let note = Data("\(info.processName), pid \(info.processIdentifier)\n".utf8)
        ftruncate(descriptor, 0)
        _ = note.withUnsafeBytes { pwrite(descriptor, $0.baseAddress, $0.count, 0) }
        self.descriptor = Mutex(descriptor)
    }

    /// Lets another window or app open the repo. Also done when the lock goes away.
    public func release() {
        descriptor.withLock { descriptor in
            if let open = descriptor { close(open) }
            descriptor = nil
        }
    }

    deinit { release() }
}
