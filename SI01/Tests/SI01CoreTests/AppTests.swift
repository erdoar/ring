import XCTest
@testable import SI01Core

final class AppTests: XCTestCase {
    func testModeIsDeviceWideAndFixedWhileRunning() throws {
        var session = Session()
        try session.setChannels(2)
        try session.setMode(.low)
        XCTAssertEqual(session.delaySamples, 127)
        session.start()
        XCTAssertThrowsError(try session.setMode(.zero)) { error in
            XCTAssertEqual(error as? SessionError, .whileRunning)
        }
        XCTAssertEqual(session.delaySamples, 127)
        session.stop()
        try session.setMode(.zero)
        XCTAssertEqual(session.delaySamples, 0)
    }

    func testQuitListIsNotInTheLoginItem() {
        let list = QuitList(names: ["Safari", "WindowServer", "Finder", "Mail"], onOpen: true, atLogin: true)
        XCTAssertEqual(list.askable(), ["Safari", "Mail"])
        XCTAssertEqual(list.afterOpen(), ["Safari", "Mail"])
        var atLoginOnly = list
        atLoginOnly.onOpen = false
        XCTAssertEqual(atLoginOnly.afterOpen(), [])
    }

    func testBlockCopiesAndDoesNotSendSamples() throws {
        let app = App()
        try app.setChannels(1)
        app.start()
        var input: [Float] = [0.25, -0.5]
        var output: [Float] = [9, 9]
        try input.withUnsafeMutableBufferPointer { source in
            try output.withUnsafeMutableBufferPointer { dest in
                try app.processBlock(input: source.baseAddress!, output: dest.baseAddress!, frames: 2, channel: 0)
            }
        }
        XCTAssertEqual(output, input)
        let frame = try XCTUnwrap(app.snapshot())
        XCTAssertFalse(frame.contains("0.25"))
        XCTAssertTrue(frame.contains("\"mode\":\"zero\""))
        XCTAssertTrue(frame.contains("\"likelihood\":[0]"))
    }

    func testLatchSurvivesAFailedSend() throws {
        let app = App()
        app.start()
        app.noteFault(missed: 1, overrun: 2)
        let first = try XCTUnwrap(app.snapshot())
        XCTAssertTrue(first.contains("\"missed\":1"))
        XCTAssertTrue(first.contains("\"overrun\":2"))
        let second = try XCTUnwrap(app.snapshot())
        XCTAssertEqual(first.contains("\"missed\":1"), second.contains("\"missed\":1"))
        app.didSendSnapshot()
        let cleared = try XCTUnwrap(app.snapshot())
        XCTAssertTrue(cleared.contains("\"missed\":0"))
        XCTAssertTrue(cleared.contains("\"overrun\":0"))
    }

    func testOpenCounterIsNotSent() {
        let app = App()
        app.holdSnapshotOpen()
        XCTAssertNil(app.snapshot())
        app.releaseSnapshot()
        XCTAssertNotNil(app.snapshot())
    }

    func testEightChannelsRejectedPastTheCap() throws {
        let app = App()
        try app.setChannels(8)
        XCTAssertThrowsError(try app.setChannels(9))
        app.start()
        XCTAssertThrowsError(try app.setChannels(1))
    }
}
