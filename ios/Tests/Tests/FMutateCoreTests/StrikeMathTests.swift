// FMStrikeMath (ios/FMutateStrikeMath.swift): the same cases as StrikeMathTest.kt, and the table both ports read
// (test/fixtures/strike_math.json).

import CoreGraphics
import Foundation
import XCTest
@testable import FMutateCore

final class StrikeMathTests: XCTestCase {
    // a level's gain on FMutate's OberVave (native/patches/obervave/poly-aftertouch.patch: a square law), in dB
    private func db(_ level: Int) -> Double { 40 * log10(Double(level) / 127) }

    // a strip's default range: velocity 40 at the back edge (front 0), 127 at the front edge (front 1)
    private func strike(_ front: CGFloat) -> (vel: Int, level: Int) {
        let vel = FMStrikeMath.velocity(front, 40, 127)
        return (vel, FMStrikeMath.strikeLevel(vel))
    }

    private struct Table: Decodable {
        struct Velocity: Decodable { let `case`: String; let front: Double; let min: Int; let max: Int; let vel: Int }
        struct Strike: Decodable { let `case`: String; let vel: Int; let level: Int }
        struct Held: Decodable { let `case`: String; let front: Double; let struck: Double; let strike: Int; let level: Int }
        let velocity: [Velocity]
        let strikeLevel: [Strike]
        let heldLevel: [Held]
    }

    // the repo's test/fixtures/strike_math.json, found from this file up
    private func table() throws -> Table {
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while dir.path != "/" {
            let file = dir.appendingPathComponent("test/fixtures/strike_math.json")
            if FileManager.default.fileExists(atPath: file.path) {
                return try JSONDecoder().decode(Table.self, from: Data(contentsOf: file))
            }
            dir = dir.deletingLastPathComponent()
        }
        throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: "test/fixtures/strike_math.json"])
    }

    func testBothPortsGiveTheSharedTable() throws {
        let t = try table()
        XCTAssertFalse(t.velocity.isEmpty || t.strikeLevel.isEmpty || t.heldLevel.isEmpty)
        for r in t.velocity {
            XCTAssertEqual(FMStrikeMath.velocity(CGFloat(r.front), r.min, r.max), r.vel, "velocity: \(r.case)")
        }
        for r in t.strikeLevel {
            XCTAssertEqual(FMStrikeMath.strikeLevel(r.vel), r.level, "strikeLevel: \(r.case)")
        }
        for r in t.heldLevel {
            let got = FMStrikeMath.heldLevel(CGFloat(r.front), CGFloat(r.struck), r.strike)
            XCTAssertEqual(got, r.level, "heldLevel: \(r.case)")
        }
    }

    func testStrikingTheTopOfAKeyIsQuietAndTheBottomLoud() {
        let top = strike(0), mid = strike(0.5), bottom = strike(1)
        XCTAssertEqual(top.vel, 40)
        XCTAssertEqual(mid.vel, 84)
        XCTAssertEqual(bottom.vel, 127)
        // the bottom (front edge) plays as the synth plays the note; the top is clearly quieter even on a patch whose
        // own velocity response is shallow, the middle in between
        XCTAssertEqual(bottom.level, 127)
        XCTAssertLessThanOrEqual(db(top.level), -15, "top")
        XCTAssertTrue((-12.0 ... -5.0).contains(db(mid.level)), "middle \(db(mid.level)) dB")
        // never silent: a strike at the very top edge, even at velocity 1, still sounds
        XCTAssertGreaterThanOrEqual(db(FMStrikeMath.strikeLevel(1)), -30)
    }

    func testAStrikesLevelFallsInEqualStepsWithItsVelocity() {
        let levels = (1 ... 127).map(FMStrikeMath.strikeLevel)
        XCTAssertTrue(zip(levels, levels.dropFirst()).allSatisfy { $0 <= $1 })
        // equal dB steps: velocity 40 to 84 drops about as much as 84 to 127
        let lower = db(FMStrikeMath.strikeLevel(84)) - db(FMStrikeMath.strikeLevel(40))
        let upper = db(FMStrikeMath.strikeLevel(127)) - db(FMStrikeMath.strikeLevel(84))
        XCTAssertEqual(lower, upper, accuracy: 1.0)
    }

    func testAHeldNoteFollowsTheFingerFromItsStrikeLevel() {
        let struck: CGFloat = 0.25
        let level = FMStrikeMath.strikeLevel(FMStrikeMath.velocity(struck, 40, 127))
        // where it struck: as struck, so a tap plays its strike
        XCTAssertEqual(FMStrikeMath.heldLevel(struck, struck, level), level)
        // slid toward the top (back edge): quieter, to silence at the edge
        XCTAssertLessThan(FMStrikeMath.heldLevel(0.1, struck, level), level)
        XCTAssertEqual(FMStrikeMath.heldLevel(0, struck, level), 0)
        // slid toward the bottom (front edge): louder, to the note's full level at the edge
        XCTAssertGreaterThan(FMStrikeMath.heldLevel(0.6, struck, level), level)
        XCTAssertEqual(FMStrikeMath.heldLevel(1, struck, level), 127)
        let path = (0 ... 100).map { FMStrikeMath.heldLevel(CGFloat($0) / 100, struck, level) }
        XCTAssertTrue(zip(path, path.dropFirst()).allSatisfy { $0 <= $1 })
        // struck at either edge
        XCTAssertEqual(FMStrikeMath.heldLevel(1, 1, 127), 127)
        XCTAssertEqual(FMStrikeMath.heldLevel(0.5, 1, 127), 64)
        XCTAssertEqual(FMStrikeMath.heldLevel(0, 0, level), level)
        XCTAssertEqual(FMStrikeMath.heldLevel(1, 0, level), 127)
    }
}
