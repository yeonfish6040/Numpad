import XCTest
@testable import TrackpadCore

final class TouchFeedbackTests: XCTestCase {
    private let anchor = Touch(id: 1, x: 0.3, y: 0.625)
    private let seven = Touch(id: 2, x: 0.1, y: 0.875)

    func testLargerCenterRegionExpandsEntryAndExitWithHysteresis() {
        var original = CenterCrossingFeedback()
        var enlarged = CenterCrossingFeedback(radiusScale: 2)
        let outside = Touch(id: 7, x: 0.34, y: 0.625)
        let entry = Touch(id: 7, x: 0.31, y: 0.625)
        _ = original.processEvents([outside])
        _ = enlarged.processEvents([outside])
        XCTAssertTrue(original.processEvents([entry]).isEmpty)
        XCTAssertEqual(enlarged.processEvents([entry]), .entered)
        // Beyond the entry radius but within the exit radius: no extra pulse.
        XCTAssertTrue(enlarged.processEvents([Touch(id: 7, x: 0.32, y: 0.625)]).isEmpty)
        XCTAssertEqual(enlarged.processEvents([Touch(id: 7, x: 0.324, y: 0.625)]), .exited)
        // A new contact landing in the expanded region must still not pulse.
        _ = enlarged.processEvents([])
        XCTAssertTrue(enlarged.processEvents([entry]).isEmpty)
    }

    func testCenterEntryAndExitAreReportedSeparately() {
        var feedback = CenterCrossingFeedback()
        let outside = Touch(id: 7, x: 0.4, y: 0.625)
        let center = Touch(id: 7, x: 0.3, y: 0.625)
        XCTAssertTrue(feedback.processEvents([outside]).isEmpty)
        XCTAssertEqual(feedback.processEvents([center]), .entered)
        XCTAssertTrue(feedback.processEvents([center]).isEmpty)
        XCTAssertEqual(feedback.processEvents([outside]), .exited)
        XCTAssertTrue(feedback.processEvents([]).isEmpty)
        XCTAssertTrue(feedback.processEvents([center]).isEmpty)
    }

    func testCenterCrossingPulsesOnceAndRequiresLeavingOuterRegion() {
        var feedback = CenterCrossingFeedback()
        XCTAssertFalse(feedback.process([seven]))
        let center = Touch(id: 2, x: 0.3, y: 0.625)
        XCTAssertTrue(feedback.process([center]))
        XCTAssertFalse(feedback.process([center]))
        XCTAssertFalse(feedback.process([Touch(id: 2, x: 0.306, y: 0.625)]))
        XCTAssertFalse(feedback.process([center]))
        XCTAssertTrue(feedback.process([seven])) // Exit produces feedback too.
        XCTAssertTrue(feedback.process([center]))
        XCTAssertFalse(feedback.process([]))
        XCTAssertFalse(feedback.process([center]))
    }

    func testCenterFeedbackTracksMovingFingerAlongsideAnchor() {
        var feedback = CenterCrossingFeedback()
        XCTAssertFalse(feedback.process([anchor, seven]))
        XCTAssertTrue(feedback.process([anchor, Touch(id: 2, x: 0.303, y: 0.625)]))
        XCTAssertFalse(feedback.process([anchor, Touch(id: 2, x: 0.303, y: 0.625)]))
    }

    func testRestingAnchorAllowsRepeatedTapsAndDoesNotTypeOnLift() {
        var recognizer = AnchoredTapRecognizer()
        XCTAssertNil(recognizer.process([anchor], at: 1))
        XCTAssertNil(recognizer.process([anchor], at: 2))
        XCTAssertNil(recognizer.process([anchor, seven], at: 2.1))
        XCTAssertEqual(recognizer.process([anchor], at: 2.2)?.label, "7")
        XCTAssertNil(recognizer.process([anchor], at: 2.3))
        let nine = Touch(id: 3, x: 0.5, y: 0.875)
        XCTAssertNil(recognizer.process([anchor, nine], at: 3))
        XCTAssertEqual(recognizer.process([anchor], at: 3.1)?.label, "9")
        XCTAssertNil(recognizer.process([], at: 3.2))
    }

    func testOrdinaryFiveTapStillWorksAndCenterLandingDoesNotPulse() {
        var recognizer = AnchoredTapRecognizer()
        var feedback = CenterCrossingFeedback()
        XCTAssertFalse(feedback.process([anchor]))
        XCTAssertNil(recognizer.process([anchor], at: 1))
        XCTAssertFalse(feedback.process([]))
        XCTAssertEqual(recognizer.process([], at: 1.1)?.label, "5")
    }

    func testTwoNonAnchorContactsCancel() {
        var recognizer = AnchoredTapRecognizer()
        let nine = Touch(id: 3, x: 0.5, y: 0.875)
        _ = recognizer.process([seven], at: 1)
        _ = recognizer.process([seven, nine], at: 1.02)
        _ = recognizer.process([seven], at: 1.05)
        XCTAssertNil(recognizer.process([], at: 1.1))
    }

    func testThirdFingerCancelsTapButRestingAnchorCanBeReused() {
        var recognizer = AnchoredTapRecognizer()
        _ = recognizer.process([anchor, seven], at: 1)
        _ = recognizer.process([anchor, seven, Touch(id: 3, x: 0.5, y: 0.875)], at: 1.02)
        XCTAssertNil(recognizer.process([anchor], at: 1.1))
        _ = recognizer.process([anchor, seven], at: 2)
        XCTAssertEqual(recognizer.process([anchor], at: 2.1)?.label, "7")
    }

    func testAnchorReleaseOrMovementCancelsPendingTap() {
        for remaining in [[seven], [Touch(id: 1, x: 0.7, y: 0.625), seven]] {
            var recognizer = AnchoredTapRecognizer()
            _ = recognizer.process([anchor, seven], at: 1)
            XCTAssertNil(recognizer.process(remaining, at: 1.05))
            XCTAssertNil(recognizer.process([], at: 1.1))
            _ = recognizer.process([seven], at: 2)
            XCTAssertEqual(recognizer.process([], at: 2.1)?.label, "7")
        }
    }

    func testAnchorDoesNotMakeSwipesIntoTaps() {
        var recognizer = AnchoredTapRecognizer()
        _ = recognizer.process([anchor, seven], at: 1)
        _ = recognizer.process([anchor, Touch(id: 2, x: 0.5, y: 0.875)], at: 1.05)
        XCTAssertNil(recognizer.process([anchor], at: 1.1))
    }

    func testPhysicalClickCancelsNumberWhileKeepingAnchorReusable() {
        var recognizer = AnchoredTapRecognizer()
        _ = recognizer.process([anchor, seven], at: 1)
        recognizer.cancelCurrentTap()
        XCTAssertNil(recognizer.process([anchor], at: 1.1))
        _ = recognizer.process([anchor, seven], at: 2)
        XCTAssertEqual(recognizer.process([anchor], at: 2.1)?.label, "7")
    }

    func testRestingFingerAnywhereAllowsOtherFingerTap() {
        for layout in KeypadLayout.allCases {
            var recognizer = AnchoredTapRecognizer(layout: layout)
            let resting = Touch(id: 10, x: 0.05, y: 0.1)
            let center = layout.center(of: "8")
            let typing = Touch(id: 11, x: center.x, y: center.y)
            _ = recognizer.process([resting], at: 1)
            _ = recognizer.process([resting], at: 1.5)
            _ = recognizer.process([resting, typing], at: 1.6)
            XCTAssertEqual(recognizer.process([resting], at: 1.7)?.label, "8")
            _ = recognizer.process([resting, typing], at: 2)
            XCTAssertEqual(recognizer.process([resting], at: 2.1)?.label, "8")
            XCTAssertNil(recognizer.process([], at: 2.2))
        }
    }

    func testFingerHeldThroughActivationGracePeriodCanAnchor() {
        var recognizer = AnchoredTapRecognizer(layout: .left)
        let rest = Touch(id: 10, x: 0.1, y: 0.1)
        let typing = Touch(id: 11, x: 0.7, y: 0.875)
        _ = recognizer.process([rest], at: 1, suppressInput: true)
        _ = recognizer.process([rest], at: 1.2, suppressInput: true)
        _ = recognizer.process([rest, typing], at: 1.3)
        XCTAssertEqual(recognizer.process([rest], at: 1.4)?.label, "8")
    }

    func testTapHasOneDownEventAndOneConfirmedRelease() {
        var recognizer = AnchoredTapRecognizer(layout: .left)
        let finger = Touch(id: 1, x: 0.7, y: 0.875)
        XCTAssertNil(recognizer.process([finger], at: 1))
        XCTAssertEqual(recognizer.beganKey?.label, "8")
        XCTAssertNil(recognizer.process([finger], at: 1.03))
        XCTAssertNil(recognizer.beganKey)
        XCTAssertEqual(recognizer.process([], at: 1.1)?.label, "8")
        XCTAssertNil(recognizer.beganKey)
        XCTAssertNil(recognizer.process([], at: 1.2))
    }

    func testRestingAnchorDoesNotHideOtherFingerDownAndReleaseEvents() {
        var recognizer = AnchoredTapRecognizer(layout: .left)
        let rest = Touch(id: 1, x: 0.1, y: 0.1)
        let typing = Touch(id: 2, x: 0.7, y: 0.875)
        _ = recognizer.process([rest], at: 1)
        _ = recognizer.process([rest], at: 1.2)
        XCTAssertNil(recognizer.beganKey)
        _ = recognizer.process([rest, typing], at: 1.3)
        XCTAssertEqual(recognizer.beganKey?.label, "8")
        _ = recognizer.process([rest, typing], at: 1.33)
        XCTAssertNil(recognizer.beganKey)
        XCTAssertEqual(recognizer.process([rest], at: 1.4)?.label, "8")
        XCTAssertNil(recognizer.beganKey)
        XCTAssertNil(recognizer.process([], at: 1.5))
    }
}
