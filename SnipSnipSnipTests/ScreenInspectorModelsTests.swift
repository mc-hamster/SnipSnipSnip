import CoreGraphics
import XCTest
@testable import SnipSnipSnip

final class ScreenInspectorModelsTests: XCTestCase {
    func testMeasurementDistanceRoundsPixelLength() {
        let measurement = ScreenInspectorMeasurement(
            start: CGPoint(x: 10, y: 20),
            end: CGPoint(x: 13, y: 24)
        )

        XCTAssertEqual(measurement.distance, 5, accuracy: 0.0001)
        XCTAssertEqual(measurement.description, "5 px")
    }
}
