import CoreLocation
import XCTest

final class ParkingFlow: XCTestCase {
  @MainActor func testManualSpotAndDeadlineSurviveRelaunch() {
    XCUIDevice.shared.location = XCUILocation(
      location: CLLocation(latitude: 37.3317, longitude: -122.0301))
    let app = XCUIApplication()
    app.launch()
    addUIInterruptionMonitor(withDescription: "Parking permissions") { alert in
      for label in ["Allow", "Allow While Using App", "Don’t Allow", "Don't Allow"]
      where alert.buttons[label].exists {
        alert.buttons[label].tap()
        return true
      }
      return false
    }
    app.buttons["Park here"].tap()
    XCTAssertTrue(app.buttons["Save parking"].waitForExistence(timeout: 15))
    app.buttons["Save parking"].tap()
    let details = app.buttons["Expand parking details"]
    XCTAssertTrue(details.waitForExistence(timeout: 15))
    details.tap()
    app.buttons["Edit sign or time"].tap()
    let limit = app.textFields["Time limit in minutes"]
    limit.tap()
    limit.typeText("45")
    app.buttons["Save"].tap()
    app.terminate()
    app.launch()
    XCTAssertTrue(app.staticTexts["Posted sign limit"].waitForExistence(timeout: 15))
    let photo = XCTAttachment(screenshot: app.screenshot())
    photo.name = "Saved parking and move deadline"
    photo.lifetime = .keepAlways
    add(photo)
    app.buttons["Expand parking details"].tap()
    app.buttons["End parking"].tap()
    let confirm = app.buttons["End session"]
    XCTAssertTrue(confirm.waitForExistence(timeout: 5))
    confirm.tap()
    XCTAssertTrue(app.buttons["Park here"].waitForExistence(timeout: 10))
  }

  @MainActor func testNearbyCurbsAndDraggablePin() throws {
    let device = XCUIDevice.shared
    let originalLocation = device.location
    device.location = XCUILocation(location: CLLocation(latitude: 37.77655, longitude: -122.42599))
    defer { device.location = originalLocation }
    let app = XCUIApplication()
    app.launch()
    app.buttons["Find my location"].tap()
    app.buttons["Park here"].tap()
    app.buttons["Save parking"].tap()

    let pin = app.descendants(matching: .any).matching(identifier: "parking-pin").firstMatch
    XCTAssertTrue(pin.waitForExistence(timeout: 10))
    let start = pin.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4))
    start.press(forDuration: 0.3, thenDragTo: start.withOffset(CGVector(dx: 70, dy: -44)))
    XCTAssertTrue(app.buttons["Save parking"].waitForExistence(timeout: 5))
    app.buttons["Save parking"].tap()
    app.buttons["Find another curb"].tap()
    XCTAssertTrue(app.staticTexts["Nearby curbs"].waitForExistence(timeout: 5))

    let option = app.buttons["curb-option-1"]
    XCTAssertTrue(option.waitForExistence(timeout: 30))
    option.tap()
    let maps = app.buttons["Driving directions in Apple Maps"]
    XCTAssertTrue(maps.waitForExistence(timeout: 8))
    let preview = XCTAttachment(screenshot: app.screenshot())
    preview.name = "Nearby curb and driving directions"
    preview.lifetime = .keepAlways
    add(preview)
    maps.tap()
    XCTAssertTrue(
      XCUIApplication(bundleIdentifier: "com.apple.Maps").wait(for: .runningForeground, timeout: 10)
    )
    app.activate()
    app.buttons["Close nearby curbs"].tap()
    app.buttons["Expand parking details"].tap()
    app.buttons["End parking"].tap()
    app.buttons["End session"].tap()
  }
}
