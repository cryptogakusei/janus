import XCTest
import JanusShared

/// Tests for TCP length-prefix framing (TCPFramer).
///
/// Verifies correct behavior for single frames, partial delivery,
/// concatenated frames, empty payloads, and oversized frame rejection.
final class TCPFramingTests: XCTestCase {

    // MARK: - frame()

    func testFrameAdds4ByteLengthHeader() {
        let payload = Data([0x41, 0x42, 0x43])  // "ABC"
        let framed = TCPFramer.frame(payload)

        XCTAssertEqual(framed.count, 4 + 3)
        // First 4 bytes should be big-endian UInt32(3)
        let length = framed.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
        XCTAssertEqual(length, 3)
        // Remaining bytes should be the original payload
        XCTAssertEqual(framed.subdata(in: 4..<7), payload)
    }

    func testFrameEmptyPayload() {
        let framed = TCPFramer.frame(Data())
        XCTAssertEqual(framed.count, 4)
        let length = framed.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
        XCTAssertEqual(length, 0)
    }

    // MARK: - Deframer: single frame

    func testDeframerSingleCompleteFrame() {
        let deframer = TCPFramer.Deframer()
        var receivedFrames: [Data] = []
        deframer.onFrame = { receivedFrames.append($0) }

        let payload = Data("Hello, TCP!".utf8)
        deframer.append(TCPFramer.frame(payload))

        XCTAssertEqual(receivedFrames.count, 1)
        XCTAssertEqual(receivedFrames[0], payload)
    }

    // MARK: - Deframer: partial delivery

    func testDeframerPartialFrame() {
        let deframer = TCPFramer.Deframer()
        var receivedFrames: [Data] = []
        deframer.onFrame = { receivedFrames.append($0) }

        let payload = Data("Hello, TCP!".utf8)
        let framed = TCPFramer.frame(payload)

        // Deliver in 3 chunks: header only, first half of payload, rest
        let headerOnly = framed.subdata(in: 0..<4)
        let firstHalf = framed.subdata(in: 4..<8)
        let rest = framed.subdata(in: 8..<framed.count)

        deframer.append(headerOnly)
        XCTAssertEqual(receivedFrames.count, 0, "Should wait for payload")

        deframer.append(firstHalf)
        XCTAssertEqual(receivedFrames.count, 0, "Should still wait for rest of payload")

        deframer.append(rest)
        XCTAssertEqual(receivedFrames.count, 1)
        XCTAssertEqual(receivedFrames[0], payload)
    }

    // MARK: - Deframer: concatenated frames

    func testDeframerConcatenatedFrames() {
        let deframer = TCPFramer.Deframer()
        var receivedFrames: [Data] = []
        deframer.onFrame = { receivedFrames.append($0) }

        let payload1 = Data("First".utf8)
        let payload2 = Data("Second".utf8)
        let payload3 = Data("Third".utf8)

        // Deliver all three frames in a single chunk
        var combined = TCPFramer.frame(payload1)
        combined.append(TCPFramer.frame(payload2))
        combined.append(TCPFramer.frame(payload3))

        deframer.append(combined)

        XCTAssertEqual(receivedFrames.count, 3)
        XCTAssertEqual(receivedFrames[0], payload1)
        XCTAssertEqual(receivedFrames[1], payload2)
        XCTAssertEqual(receivedFrames[2], payload3)
    }

    // MARK: - Deframer: empty payload frame

    func testDeframerEmptyPayload() {
        let deframer = TCPFramer.Deframer()
        var receivedFrames: [Data] = []
        deframer.onFrame = { receivedFrames.append($0) }

        deframer.append(TCPFramer.frame(Data()))

        XCTAssertEqual(receivedFrames.count, 1)
        XCTAssertEqual(receivedFrames[0], Data())
    }

    // MARK: - Deframer: oversized frame rejection

    func testDeframerRejectsOversizedFrame() {
        let deframer = TCPFramer.Deframer()
        var receivedFrames: [Data] = []
        var receivedErrors: [Error] = []
        deframer.onFrame = { receivedFrames.append($0) }
        deframer.onError = { receivedErrors.append($0) }

        // Craft a header claiming 32MB payload (exceeds 16MB max)
        var oversizedLength = UInt32(32 * 1024 * 1024).bigEndian
        let header = Data(bytes: &oversizedLength, count: 4)

        deframer.append(header)

        XCTAssertEqual(receivedFrames.count, 0)
        XCTAssertEqual(receivedErrors.count, 1)
    }

    // MARK: - Deframer: large payload within limit

    func testDeframerLargePayloadWithinLimit() {
        let deframer = TCPFramer.Deframer()
        var receivedFrames: [Data] = []
        deframer.onFrame = { receivedFrames.append($0) }

        // 1MB payload — well within 16MB limit
        let payload = Data(repeating: 0xAB, count: 1024 * 1024)
        deframer.append(TCPFramer.frame(payload))

        XCTAssertEqual(receivedFrames.count, 1)
        XCTAssertEqual(receivedFrames[0].count, 1024 * 1024)
    }

    // MARK: - Deframer: reset

    func testDeframerReset() {
        let deframer = TCPFramer.Deframer()
        var receivedFrames: [Data] = []
        deframer.onFrame = { receivedFrames.append($0) }

        // Feed a partial frame, then reset
        let framed = TCPFramer.frame(Data("partial".utf8))
        deframer.append(framed.subdata(in: 0..<4))
        deframer.reset()

        // Now feed a complete new frame — should work independently
        let newPayload = Data("fresh".utf8)
        deframer.append(TCPFramer.frame(newPayload))

        XCTAssertEqual(receivedFrames.count, 1)
        XCTAssertEqual(receivedFrames[0], newPayload)
    }
}
