// A MIDI binding's destination ("to": synth, out, both; FMutate.MIDI.Out) in ios/FMutateLayout.swift: what the surface
// sends, and rule 7's keys, which FMutate.MIDI.Controls.target_key/1 must match (MidiDestinationTest.kt on Android).

import XCTest
@testable import FMutateCore

final class MidiDestinationTests: XCTestCase {
    private let json = """
        {"format":"fmutate.layout/1","id":"m","name":"m","firmware":{"id":"obervave"},"frame":"landscape",
        "grid":{"cols":14,"rows":6},"pages":[{"id":"p","controls":[
        {"id":"xy","type":"xy_pad","at":{"col":0,"row":0,"w":3,"h":3},"bindings":[
          {"on":"x","to":{"midi":{"type":"cc","number":74,"to":"out"}}},
          {"on":"y","to":{"midi":{"type":"cc","number":71,"to":"both"}}}]},
        {"id":"k","type":"knob","at":{"col":4,"row":0,"w":1,"h":1},"bindings":[{"on":"value","to":{"midi":{"type":"cc","number":74}}}]},
        {"id":"t","type":"motion","at":{"col":5,"row":0,"w":1,"h":1},"bindings":[{"on":"y","to":{"midi":{"type":"pitch_bend","channel":2,"to":"out"}}}]}
        ]}]}
        """

    private func target(_ id: String, _ on: String) -> FMTarget {
        let layout = FMLayout.parse(json)!
        return layout.pages[0].controls.first { $0.id == id }!.binding(on)!.to
    }

    func testAnOutOnlyMessageHasItsOwnRule7ValueAndBothSharesTheSynths() {
        XCTAssertEqual(target("xy", "x").absoluteKey, "out:cc:1:74")
        XCTAssertEqual(target("k", "value").absoluteKey, "cc:1:74")
        XCTAssertEqual(target("xy", "y").absoluteKey, "cc:1:71")
        XCTAssertEqual(target("t", "y").absoluteKey, "out:bend:2")
    }

    func testThePayloadSaysWhereItGoesUnlessThatIsTheSynth() {
        let bytes = [0xB0, 74, 64]
        XCTAssertEqual(target("xy", "x").midiPayload(bytes)["to"] as? String, "out")
        XCTAssertNil(target("k", "value").midiPayload(bytes)["to"])
        let both = target("xy", "y").midiPayload(bytes, ["c": "xy"])
        XCTAssertEqual(both["to"] as? String, "both")
        XCTAssertEqual(both["bytes"] as? [Int], bytes)
        XCTAssertEqual(both["c"] as? String, "xy")
    }

    func testANewEngineGetsOnlyWhatGoesToTheSynth() {
        XCTAssertNil(target("xy", "x").synthSide)
        XCTAssertEqual(target("xy", "y").synthSide,
                       .midi(type: "cc", channel: 1, number: 71, jump: false, on: 127, off: 0, to: "synth"))
        XCTAssertEqual(target("k", "value").synthSide, target("k", "value"))
    }
}
