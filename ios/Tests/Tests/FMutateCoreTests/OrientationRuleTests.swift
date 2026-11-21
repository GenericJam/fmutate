// FMOrientationRule (ios/FMutateOrientationRule.swift): what the instrument holds, when holding changes nothing, and
// which way the scene turns on letting go.

import XCTest
@testable import FMutateCore

final class OrientationRuleTests: XCTestCase {
    private let all: [FMDeviceOrientation] = [.unknown, .portrait, .portraitUpsideDown, .landscapeLeft, .landscapeRight,
                                              .faceUp, .faceDown]

    func testALayoutHoldsLandscapeEitherWayRoundOrPortraitAndLettingGoHoldsNothing() {
        XCTAssertEqual(FMOrientationRule.hold(true, held: [], hasScene: true), .landscape)
        XCTAssertEqual(FMOrientationRule.hold(false, held: [], hasScene: true), .portrait)
        XCTAssertEqual(FMOrientationRule.hold(nil, held: .landscape, hasScene: true), [])
        XCTAssertEqual(FMOrientationRule.hold(false, held: .landscape, hasScene: true), .portrait)
        XCTAssertEqual(FMOrientationRule.hold(true, held: .portrait, hasScene: true), .landscape)
        // landscape is both ways round, so the phone can turn over while the instrument is up
        XCTAssertEqual(FMOrientationMask.landscape, [.landscapeLeft, .landscapeRight])
    }

    func testHoldingWhatIsHeldOrWithoutASceneDoesNothing() {
        XCTAssertNil(FMOrientationRule.hold(true, held: .landscape, hasScene: true))
        XCTAssertNil(FMOrientationRule.hold(false, held: .portrait, hasScene: true))
        XCTAssertNil(FMOrientationRule.hold(nil, held: [], hasScene: true))
        for landscape in [true, false, nil] as [Bool?] {
            for held in [[], .portrait, .landscape] as [FMOrientationMask] {
                XCTAssertNil(FMOrientationRule.hold(landscape, held: held, hasScene: false), "\(String(describing: landscape)) \(held)")
            }
        }
    }

    func testWhileHoldingTheSceneTurnsToTheHeldFrameWhateverThePhone() {
        for o in all {
            XCTAssertEqual(FMOrientationRule.turn(.landscape, o), .landscape, "\(o)")
            XCTAssertEqual(FMOrientationRule.turn(.portrait, o), .portrait, "\(o)")
        }
    }

    func testLettingGoTurnsTheSceneUprightForThePhoneAndStaysPutWhenFlatOrUnknown() {
        XCTAssertEqual(FMOrientationRule.turn([], .portrait), .portrait)
        XCTAssertEqual(FMOrientationRule.turn([], .portraitUpsideDown), .portraitUpsideDown)
        // a device turned left shows the interface turned right
        XCTAssertEqual(FMOrientationRule.turn([], .landscapeLeft), .landscapeRight)
        XCTAssertEqual(FMOrientationRule.turn([], .landscapeRight), .landscapeLeft)
        XCTAssertNil(FMOrientationRule.turn([], .faceUp))
        XCTAssertNil(FMOrientationRule.turn([], .faceDown))
        XCTAssertNil(FMOrientationRule.turn([], .unknown))
    }

    // the mirrors carry UIKit's raw values (UIInterfaceOrientationMask, UIDeviceOrientation): AppDelegate.m reads the
    // held mask's raw value, and FMOrientation converts both ways by raw value
    func testTheMirrorsCarryUIKitsRawValues() {
        XCTAssertEqual(FMOrientationMask.portrait.rawValue, 2)
        XCTAssertEqual(FMOrientationMask.portraitUpsideDown.rawValue, 4)
        XCTAssertEqual(FMOrientationMask.landscapeRight.rawValue, 8)
        XCTAssertEqual(FMOrientationMask.landscapeLeft.rawValue, 16)
        XCTAssertEqual(FMOrientationMask.landscape.rawValue, 24)
        XCTAssertEqual(all.map(\.rawValue), Array(0 ... 6))
    }
}
