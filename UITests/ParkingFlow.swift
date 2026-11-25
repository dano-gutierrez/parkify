import XCTest

final class ParkingFlow: XCTestCase {
  @MainActor func testManualSpotAndDeadlineSurviveRelaunch() {
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
}
