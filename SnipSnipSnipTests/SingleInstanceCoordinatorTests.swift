import Darwin
import XCTest
@testable import SnipSnipSnip

@MainActor
final class SingleInstanceCoordinatorTests: XCTestCase {
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
