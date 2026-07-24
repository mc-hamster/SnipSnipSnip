import AppKit
import Darwin
import Foundation
import OSLog

final class SingleInstanceLease {
    enum Acquisition {
        case acquired(SingleInstanceLease)
        case alreadyRunning
    }

    enum LeaseError: Error {
        case openFailed(URL, errno: Int32)
        case lockFailed(URL, errno: Int32)
    }

    let fileDescriptor: Int32
    let lockURL: URL

    private init(fileDescriptor: Int32, lockURL: URL) {
        self.fileDescriptor = fileDescriptor
        self.lockURL = lockURL
    }

    deinit {
        _ = Darwin.close(fileDescriptor)
    }

    static func acquire(
        at lockURL: URL,
        fileManager: FileManager = .default,
        processIdentifier: pid_t = getpid()
    ) throws -> Acquisition {
        try fileManager.createDirectory(
            at: lockURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let fileDescriptor = lockURL.path.withCString {
            Darwin.open($0, O_RDWR | O_CREAT | O_CLOEXEC, mode_t(S_IRUSR | S_IWUSR))
        }
        guard fileDescriptor >= 0 else {
            throw LeaseError.openFailed(lockURL, errno: errno)
        }

        guard acquireExclusiveLock(on: fileDescriptor) == 0 else {
            let lockError = errno
            _ = Darwin.close(fileDescriptor)

            if lockError == EACCES || lockError == EWOULDBLOCK || lockError == EAGAIN {
                return .alreadyRunning
            }
            throw LeaseError.lockFailed(lockURL, errno: lockError)
        }

        writeOwnerProcessIdentifier(processIdentifier, to: fileDescriptor)
        return .acquired(SingleInstanceLease(fileDescriptor: fileDescriptor, lockURL: lockURL))
    }

    private static func acquireExclusiveLock(on fileDescriptor: Int32) -> Int32 {
        var lock = Darwin.flock()
        lock.l_start = 0
        lock.l_len = 0
        lock.l_pid = 0
        lock.l_type = Int16(F_WRLCK)
        lock.l_whence = Int16(SEEK_SET)

        return withUnsafeMutablePointer(to: &lock) {
            Darwin.fcntl(fileDescriptor, F_OFD_SETLK, UnsafeMutableRawPointer($0))
        }
    }

    private static func writeOwnerProcessIdentifier(_ processIdentifier: pid_t, to fileDescriptor: Int32) {
        guard Darwin.ftruncate(fileDescriptor, 0) == 0,
              Darwin.lseek(fileDescriptor, 0, SEEK_SET) >= 0 else {
            return
        }

        let bytes = Array("\(processIdentifier)\n".utf8)
        bytes.withUnsafeBytes { buffer in
            guard let address = buffer.baseAddress else {
                return
            }
            _ = Darwin.write(fileDescriptor, address, buffer.count)
        }
    }
}

@MainActor
enum SingleInstanceCoordinator {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.oontz.SnipSnipSnip",
        category: "SingleInstance"
    )
    private static var lease: SingleInstanceLease?

    static func enforceAtLaunch() {
        guard lease == nil else {
            return
        }

        let lockURL: URL
        do {
            lockURL = try defaultLockURL()
        } catch {
            logger.fault("Unable to resolve the single-instance lock location: \(error.localizedDescription, privacy: .public)")
            Darwin.exit(EXIT_FAILURE)
        }

        do {
            switch try SingleInstanceLease.acquire(at: lockURL) {
            case .acquired(let acquiredLease):
                lease = acquiredLease
                logger.debug("Acquired single-instance lease at \(lockURL.path, privacy: .private)")
            case .alreadyRunning:
                let activated = activateExistingApplication()
                logger.notice("Rejected a duplicate process; activatedExistingApplication=\(activated, privacy: .public)")
                Darwin.exit(EXIT_SUCCESS)
            }
        } catch {
            logger.fault("Unable to enforce the single-instance lease: \(String(describing: error), privacy: .public)")
            Darwin.exit(EXIT_FAILURE)
        }
    }

    private static func defaultLockURL(fileManager: FileManager = .default) throws -> URL {
        let applicationSupportURL = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return applicationSupportURL
            .appendingPathComponent("SnipSnipSnip", isDirectory: true)
            .appendingPathComponent("Runtime", isDirectory: true)
            .appendingPathComponent("single-instance.lock")
    }

    @discardableResult
    private static func activateExistingApplication() -> Bool {
        guard let bundleIdentifier = Bundle.main.bundleIdentifier else {
            return false
        }

        let currentProcessIdentifier = ProcessInfo.processInfo.processIdentifier
        guard let application = NSRunningApplication
            .runningApplications(withBundleIdentifier: bundleIdentifier)
            .first(where: {
                $0.processIdentifier != currentProcessIdentifier && !$0.isTerminated
            }) else {
            return false
        }

        return application.activate(options: [])
    }
}
