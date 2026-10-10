import Darwin
import XCTest
@testable import SnipSnipSnip

@MainActor
final class SingleInstanceCoordinatorTests: XCTestCase {
    func testDevelopmentAndShippingLeasesCanCoexistButRejectTheirOwnDuplicates() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("NamespaceLocks-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let dev = AppNamespace(bundleIdentifier: "com.oontz.SnipSnipSnip.Dev")
        let shipping = AppNamespace(bundleIdentifier: "com.oontz.SnipSnipSnip")
        let devURL = SingleInstanceCoordinator.lockURL(in: root, namespace: dev)
        let shippingURL = SingleInstanceCoordinator.lockURL(in: root, namespace: shipping)
        XCTAssertNotEqual(devURL, shippingURL)
        XCTAssertEqual(shippingURL, root.appendingPathComponent("SnipSnipSnip/Runtime/single-instance.lock"))
        guard case .acquired(let devLease) = try SingleInstanceLease.acquire(at: devURL),
              case .acquired(let shippingLease) = try SingleInstanceLease.acquire(at: shippingURL) else {
            return XCTFail("Different namespaces must run together.")
        }
        withExtendedLifetime((devLease, shippingLease)) {
            for url in [devURL, shippingURL] {
                do {
                    guard case .alreadyRunning = try SingleInstanceLease.acquire(at: url) else {
                        return XCTFail("Each namespace must still reject duplicate owners.")
                    }
                } catch { XCTFail("Unexpected lock error: \(error)") }
            }
        }
    }

    func testBuiltNamespaceSeparatesStorageAndRouting() throws {
        let current = AppNamespace.current
        let expectedID = BuildTarget.current == .dev ? "com.oontz.SnipSnipSnip.Dev" : "com.oontz.SnipSnipSnip"
        XCTAssertEqual(Bundle.main.bundleIdentifier, expectedID)
        if current.isDevelopment {
            XCTAssertEqual(Bundle.main.bundleURL.lastPathComponent, "SnipSnipSnip Dev.app")
            XCTAssertEqual(Bundle.main.object(forInfoDictionaryKey: "CFBundleExecutable") as? String, "SnipSnipSnip Dev")
        }
        XCTAssertEqual(Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String, AppBranding.displayName)
        let types = try XCTUnwrap(Bundle.main.object(forInfoDictionaryKey: "CFBundleURLTypes") as? [[String: Any]])
        XCTAssertEqual(types.first?["CFBundleURLSchemes"] as? [String], [current.urlScheme])
        XCTAssertEqual(DocumentRecoveryStore.defaultArchiveURL().deletingLastPathComponent().lastPathComponent, current.supportDirectoryName)
        XCTAssertEqual(ClipboardHistoryStore.defaultHistoryURL().deletingLastPathComponent().lastPathComponent, current.supportDirectoryName)
        XCTAssertEqual(PresentationSceneStore.defaultRootURL.deletingLastPathComponent().lastPathComponent, current.supportDirectoryName)
        XCTAssertTrue(VideoRecoveryStore().rootURL.path.contains("/" + current.supportDirectoryName + "/Recovery/Videos"))
        XCTAssertTrue(GuideRecoveryStore().rootURL.path.contains("/" + current.supportDirectoryName + "/Recovery/Guides"))
        let otherScheme = current.isDevelopment ? "snipsnipsnip" : "snipsnipsnip-dev"
        XCTAssertNotNil(AutomationURLRouter.request(from: try XCTUnwrap(URL(string: "\(current.urlScheme)://v1/status"))))
        XCTAssertNil(AutomationURLRouter.request(from: try XCTUnwrap(URL(string: "\(otherScheme)://v1/status"))))
        XCTAssertNil(AppImportURL.pasteboardImportRequest(from: try XCTUnwrap(URL(string: "\(otherScheme)://import-pasteboard?name=test"))))
    }

    func testLeaseRejectsAnotherOwnerUntilTheFirstLeaseIsReleased() throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("SingleInstanceCoordinatorTests-\(UUID().uuidString)", isDirectory: true)
        let lockURL = rootURL.appendingPathComponent("single-instance.lock")
        defer { try? FileManager.default.removeItem(at: rootURL) }

        var firstLease: SingleInstanceLease?
        switch try SingleInstanceLease.acquire(at: lockURL) {
        case .acquired(let lease):
            firstLease = lease
        case .alreadyRunning:
            return XCTFail("The first lease acquisition should succeed.")
        }
        XCTAssertNotNil(firstLease)

        switch try SingleInstanceLease.acquire(at: lockURL) {
        case .acquired:
            XCTFail("A second lease must not acquire the same lock.")
        case .alreadyRunning:
            break
        }

        firstLease = nil

        switch try SingleInstanceLease.acquire(at: lockURL) {
        case .acquired:
            break
        case .alreadyRunning:
            XCTFail("The OS should release the lock when its lease closes.")
        }
    }

    func testLeaseDescriptorClosesAcrossExecAndRecordsItsOwner() throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("SingleInstanceCoordinatorTests-\(UUID().uuidString)", isDirectory: true)
        let lockURL = rootURL.appendingPathComponent("single-instance.lock")
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let processIdentifier: pid_t = 12_345
        let lease: SingleInstanceLease
        switch try SingleInstanceLease.acquire(
            at: lockURL,
            processIdentifier: processIdentifier
        ) {
        case .acquired(let acquiredLease):
            lease = acquiredLease
        case .alreadyRunning:
            return XCTFail("The lease acquisition should succeed for a unique path.")
        }

        let descriptorFlags = Darwin.fcntl(lease.fileDescriptor, F_GETFD)
        XCTAssertGreaterThanOrEqual(descriptorFlags, 0)
        XCTAssertNotEqual(descriptorFlags & FD_CLOEXEC, 0)
        XCTAssertEqual(try String(contentsOf: lockURL, encoding: .utf8), "\(processIdentifier)\n")
    }
}
