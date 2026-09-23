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
            app.tables["libraryTable"].tableRows.element(boundBy: number)
        }
        let table = app.tables["libraryTable"]
        func expectSelection(_ number: Int) -> Bool {
            let element = row(number)
            let selected = NSPredicate(format: "selected == true")
            let expectation = XCTNSPredicateExpectation(predicate: selected, object: element)
            let selectedResult = XCTWaiter.wait(for: [expectation], timeout: 5) == .completed
            XCTAssertTrue(selectedResult, "Selection should reach row \(number)")
            let visible = element.isHittable
            XCTAssertTrue(visible, "Selected row must remain visible")
            return selectedResult && visible
        }

        guard row(0).waitForExistence(timeout: 10) else {
            let screenshot = XCTAttachment(screenshot: app.screenshot())
            screenshot.lifetime = .keepAlways
            add(screenshot)
            XCTFail("Fixture row unavailable: \(app.debugDescription)")
            return
        }
        row(0).click()
        guard expectSelection(0) else { return }
        // More rows than the viewport can hold, then extra presses at the end.
        table.typeKey(.downArrow, modifierFlags: [])
        guard expectSelection(1) else { return }
        for _ in 0..<44 { table.typeKey(.downArrow, modifierFlags: []) }
        guard expectSelection(35) else { return }
        table.typeKey(.upArrow, modifierFlags: [])
        guard expectSelection(34) else { return }
        for _ in 0..<45 { table.typeKey(.upArrow, modifierFlags: []) }
        guard expectSelection(0) else { return }
        table.typeKey(.downArrow, modifierFlags: [])
        _ = expectSelection(1)
    }
}
