import XCTest

final class LibraryKeyboardNavigationUITests: XCTestCase {
    @MainActor
    func testArrowsCrossViewportAndReverseAfterBothBoundaries() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "--keyboard-navigation-test", "-mainViewIsGrid", "NO",
            "-ApplePersistenceIgnoreState", "YES",
            "-mainSortKey", "title", "-mainSortAscending", "YES",
            "-advancedPasswordLockEnabled", "NO"
        ]
        app.launch()
        defer { app.terminate() }
        if !app.windows.firstMatch.waitForExistence(timeout: 3) {
            app.menuBars.menuBarItems["File"].click()
            app.menuItems["New Window"].click()
        }

        func row(_ number: Int) -> XCUIElement {
            app.descendants(matching: .any).matching(identifier: String(format: "libraryRow-Keyboard row %02d", number)).firstMatch
        }
        func expectSelection(_ number: Int) {
            let element = row(number)
            let selected = NSPredicate(format: "selected == true")
            let expectation = XCTNSPredicateExpectation(predicate: selected, object: element)
            XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 5), .completed, "Selection should reach row \(number)")
            XCTAssertTrue(element.isHittable, "Selected row must remain visible")
        }

        guard row(0).waitForExistence(timeout: 10) else {
            let screenshot = XCTAttachment(screenshot: app.screenshot())
            screenshot.lifetime = .keepAlways
            add(screenshot)
            XCTFail("Fixture row unavailable: \(app.debugDescription)")
            return
        }
        row(0).click()
        expectSelection(0)
        // More rows than the viewport can hold, then extra presses at the end.
        for _ in 0..<45 { app.typeKey(.downArrow, modifierFlags: []) }
        expectSelection(35)
        app.typeKey(.upArrow, modifierFlags: [])
        expectSelection(34)
        for _ in 0..<45 { app.typeKey(.upArrow, modifierFlags: []) }
        expectSelection(0)
        app.typeKey(.downArrow, modifierFlags: [])
        expectSelection(1)
    }
}
