import XCTest

extension XCUIApplication {
    /// A tab item by RN's testID, wherever the tab bar draws it: a button of the bottom tab bar on
    /// an iPhone (and an iPad in a narrow window); on an iPad, a button of the top tab bar or a
    /// cell of the sidebar, whichever shows (neither is a tab bar to XCUITest).
    func shellTab(_ identifier: String) -> XCUIElement {
        if tabBars.firstMatch.exists { return tabBars.buttons[identifier] }
        let sidebarRow = cells.matching(identifier: identifier).firstMatch
        if sidebarRow.exists, sidebarRow.isHittable { return sidebarRow }
        return buttons.matching(identifier: identifier).firstMatch
    }

    /// Whether this runs on an iPad.
    var shellIsPad: Bool { UIDevice.current.userInterfaceIdiom == .pad }
}

extension XCTestCase {
    /// Waits until `element` is gone.
    func shellWaitForAbsence(_ element: XCUIElement, timeout: TimeInterval = 5) -> Bool {
        let gone = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: element)
        return XCTWaiter().wait(for: [gone], timeout: timeout) == .completed
    }
}
