import XCTest

extension XCUIApplication {

    /// Scroll the instrument column, not the 3D view.
    ///
    /// `swipeUp()` starts in the middle of the screen, which on a phone is
    /// inside the SceneKit viewer. That view has camera control enabled, so it
    /// consumes the gesture and ORBITS THE MOLECULE instead of scrolling: the
    /// test looks like it is scrolling, the panel never arrives, and the
    /// failure reads as a missing view rather than a misdirected swipe.
    ///
    /// Starting near the bottom lands in the instrument column, whatever the
    /// layout has done with the viewer's height.
    func scrollInstruments() {
        let start = coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.92))
        let end = coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.42))
        start.press(forDuration: 0.05, thenDragTo: end)
    }

    /// Scroll until an element is hittable, or give up.
    @discardableResult
    func scrollUntilHittable(_ element: XCUIElement, attempts: Int = 12) -> Bool {
        var tries = 0
        while !element.isHittable && tries < attempts {
            scrollInstruments()
            tries += 1
        }
        return element.isHittable
    }

    /// Scroll until an element exists, or give up.
    @discardableResult
    func scrollUntilExists(_ element: XCUIElement, attempts: Int = 12) -> Bool {
        var tries = 0
        while !element.exists && tries < attempts {
            scrollInstruments()
            tries += 1
        }
        return element.exists
    }
}
