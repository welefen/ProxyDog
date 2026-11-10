import Foundation
import NIOCore

// MARK: - Parsed message

/// Result of reassembling one WebSocket logical message (data message or control frame).
struct ParsedWebSocketMessage {
    let direction: WebSocketDirection
    let kind: WebSocketMessageKind
    let timestamp: Date
    let payload: Data
    /// Real payload size in bytes, even when `payload` was truncated by the capture cap.
    let byteCount: Int
    let truncated: Bool
}

// MARK: - Incremental frame parser

/// Incremental WebSocket (RFC 6455) frame parser for one direction of a captured tunnel.
///
/// The parser is fed the raw byte buffers that the tunnel relays; it copies only payload
/// prefixes that are actually stored (up to `WebSocketCaptureLimits.maxPayloadBytes`), so
/// large frames are forwarded without extra whole-payload copies.
///
/// Limitations (intentional, documented):
/// * `permessage-deflate` is not inflated - RSV1 frames are stored as raw compressed bytes
///   under `.binary` (the payload is otherwise unmodified).
/// * Only text/binary/continuation/ping/pong/close opcodes are interpreted; reserved opcodes
///   are skipped without desynchronising the stream.
/// * WebSocket over HTTP/2 is not supported (HTTP/1.1 upgrades only).
final class WebSocketFrameParser {
    let direction: WebSocketDirection

    private enum Constants {
        static let continuationOpcode: UInt8 = 0x00
        static let textOpcode: UInt8 = 0x01
        static let binaryOpcode: UInt8 = 0x02
        static let closeOpcode: UInt8 = 0x08
        static let pingOpcode: UInt8 = 0x09
        static let pongOpcode: UInt8 = 0x0A
    }

    private var headerBytes: [UInt8] = []
    private var frameOpcode: UInt8 = 0
    private var frameFin = true
    private var frameRsv1 = false
    private var framePayloadRemaining = 0
    private var frameMaskKey: [UInt8]?
    private var frameMaskOffset = 0
    private var frameShouldCapture = false
    private var frameBuffer = Data()
    private var frameByteCount = 0

    /// State of a fragmented data message that is being reassembled.
    private var activeMessageOpcode: UInt8?
    private var activeMessageCompressed = false
    private var activeMessageBuffer = Data()
    private var activeMessageByteCount = 0
    /// Set when a reserved/unknown opcode with FIN=0 was seen; consume its continuations.
    private var skippingUnknownFragments = false

    init(direction: WebSocketDirection) {
        self.direction = direction
    }

    /// Feeds bytes and returns every logical message completed by this chunk.
    func ingest(_ buffer: ByteBuffer) -> [ParsedWebSocketMessage] {
        guard let incoming = buffer.getBytes(at: buffer.readerIndex, length: buffer.readableBytes),
              !incoming.isEmpty
        else { return [] }

        var messages: [ParsedWebSocketMessage] = []
        var index = 0

        while true {
            if framePayloadRemaining > 0 {
                let available = incoming.count - index
                guard available > 0 else { break }
                let take = min(framePayloadRemaining, available)
                if frameShouldCapture {
                    let slice = Array(incoming[index..<(index + take)])
                    appendFramePayload(slice)
                } else {
                    frameMaskOffset += take
                }
                index += take
                framePayloadRemaining -= take
                if framePayloadRemaining == 0 {
                    finishFrame(into: &messages)
                }
                continue
            }

            // --- Frame header ---
            if headerBytes.count < 2 {
                while headerBytes.count < 2, index < incoming.count {
                    headerBytes.append(incoming[index])
                    index += 1
                }
                if headerBytes.count < 2 { break }
            }

            let first = headerBytes[0]
            let second = headerBytes[1]
            let masked = (second & 0x80) != 0
            let length7 = Int(second & 0x7F)
            var headerLength = 2
            if length7 == 126 { headerLength += 2 }
            if length7 == 127 { headerLength += 8 }
            if masked { headerLength += 4 }

            if headerBytes.count < headerLength {
                while headerBytes.count < headerLength, index < incoming.count {
                    headerBytes.append(incoming[index])
                    index += 1
                }
                if headerBytes.count < headerLength { break }
            }

            let b1 = headerBytes[0]
            let b2 = headerBytes[1]
            frameFin = (b1 & 0x80) != 0
            frameRsv1 = (b1 & 0x40) != 0
            frameOpcode = b1 & 0x0F

            var payloadLength: Int
            var cursor = 2
            switch Int(b2 & 0x7F) {
            case 126:
                payloadLength = Int(headerBytes[2]) << 8 | Int(headerBytes[3])
                cursor = 4
            case 127:
                var value: UInt64 = 0
                for offset in 0..<8 {
                    value = (value << 8) | UInt64(headerBytes[2 + offset])
                }
                payloadLength = Int(clamping: value)
                cursor = 10
            case let short:
                payloadLength = short
            }

            let isMasked = (b2 & 0x80) != 0
            if isMasked {
                frameMaskKey = Array(headerBytes[cursor..<(cursor + 4)])
            } else {
                frameMaskKey = nil
            }
            headerBytes.removeAll(keepingCapacity: true)

            frameMaskOffset = 0
            frameBuffer = Data()
            frameByteCount = 0
            frameShouldCapture = configureFrame(opcode: frameOpcode, fin: frameFin, rsv1: frameRsv1)
            framePayloadRemaining = payloadLength

            if payloadLength == 0 {
                finishFrame(into: &messages)
            }
        }

        return messages
    }

    // MARK: Frame bookkeeping

    /// Decides whether the upcoming frame payload belongs to a message we capture.
    private func configureFrame(opcode: UInt8, fin: Bool, rsv1: Bool) -> Bool {
        switch opcode {
        case Constants.textOpcode, Constants.binaryOpcode:
            // A new data message starts; a previous unfinished one is a protocol violation.
            if activeMessageOpcode != nil {
                activeMessageOpcode = nil
                activeMessageBuffer = Data()
                activeMessageByteCount = 0
                activeMessageCompressed = false
            }
            if !fin {
                activeMessageOpcode = opcode
                activeMessageCompressed = rsv1
            }
            return true

        case Constants.continuationOpcode:
            if activeMessageOpcode != nil {
                activeMessageCompressed = activeMessageCompressed || rsv1
                return true
            }
            // Continuation of an unknown/skipped fragment sequence.
            return false

        case Constants.closeOpcode, Constants.pingOpcode, Constants.pongOpcode:
            return true

        default:
            // Reserved data/control opcodes: consume safely without capturing.
            if !fin {
                skippingUnknownFragments = true
            }
            return false
        }
    }

    private func appendFramePayload(_ slice: [UInt8]) {
        var payload = slice
        if let mask = frameMaskKey {
            for offset in 0..<payload.count {
                payload[offset] ^= mask[(frameMaskOffset + offset) % 4]
            }
        }
        frameMaskOffset += slice.count
        frameByteCount += slice.count

        if frameBuffer.count < WebSocketCaptureLimits.maxPayloadBytes {
            let room = WebSocketCaptureLimits.maxPayloadBytes - frameBuffer.count
            frameBuffer.append(contentsOf: payload.prefix(room))
        }
    }

    private func finishFrame(into messages: inout [ParsedWebSocketMessage]) {
        let opcode = frameOpcode
        let fin = frameFin
        let captured = frameShouldCapture
        let framePayload = frameBuffer
        let payloadByteCount = frameByteCount
        let truncated = payloadByteCount > framePayload.count

        frameBuffer = Data()
        frameByteCount = 0
        frameShouldCapture = false

        guard captured else {
            if opcode == Constants.continuationOpcode {
                if fin { skippingUnknownFragments = false }
            } else if (opcode & 0x08) == 0, fin {
                skippingUnknownFragments = false
            }
            return
        }

        switch opcode {
        case Constants.closeOpcode:
            messages.append(
                ParsedWebSocketMessage(
                    direction: direction,
                    kind: .close,
                    timestamp: Date(),
                    payload: framePayload,
                    byteCount: payloadByteCount,
                    truncated: truncated
                )
            )

        case Constants.pingOpcode:
            messages.append(
                ParsedWebSocketMessage(
                    direction: direction,
                    kind: .ping,
                    timestamp: Date(),
                    payload: framePayload,
                    byteCount: payloadByteCount,
                    truncated: truncated
                )
            )

        case Constants.pongOpcode:
            messages.append(
                ParsedWebSocketMessage(
                    direction: direction,
                    kind: .pong,
                    timestamp: Date(),
                    payload: framePayload,
                    byteCount: payloadByteCount,
                    truncated: truncated
                )
            )

        case Constants.textOpcode, Constants.binaryOpcode:
            if fin {
                messages.append(
                    makeMessage(
                        opcode: opcode,
                        compressed: frameRsv1,
                        payload: framePayload,
                        byteCount: payloadByteCount,
                        truncated: truncated
                    )
                )
            } else {
                activeMessageOpcode = opcode
                activeMessageCompressed = frameRsv1
                activeMessageBuffer = framePayload
                activeMessageByteCount = payloadByteCount
            }

        case Constants.continuationOpcode:
            guard activeMessageOpcode != nil else {
                if fin { skippingUnknownFragments = false }
                return
            }
            let remainingRoom = WebSocketCaptureLimits.maxPayloadBytes - activeMessageBuffer.count
            if remainingRoom > 0 {
                activeMessageBuffer.append(contentsOf: framePayload.prefix(remainingRoom))
            }
            activeMessageByteCount += payloadByteCount
            guard fin else { return }

            let message = makeMessage(
                opcode: activeMessageOpcode ?? Constants.binaryOpcode,
                compressed: activeMessageCompressed,
                payload: activeMessageBuffer,
                byteCount: activeMessageByteCount,
                truncated: activeMessageByteCount > activeMessageBuffer.count
            )
            messages.append(message)
            activeMessageOpcode = nil
            activeMessageBuffer = Data()
            activeMessageByteCount = 0
            activeMessageCompressed = false

        default:
            if fin { skippingUnknownFragments = false }
        }
    }

    private func makeMessage(
        opcode: UInt8,
        compressed: Bool,
        payload: Data,
        byteCount: Int,
        truncated: Bool
    ) -> ParsedWebSocketMessage {
        // permessage-deflate is not inflated: keep the raw compressed bytes as binary.
        let kind: WebSocketMessageKind
        if compressed {
            kind = .binary
        } else if opcode == Constants.textOpcode {
            kind = .text
        } else {
            kind = .binary
        }
        return ParsedWebSocketMessage(
            direction: direction,
            kind: kind,
            timestamp: Date(),
            payload: payload,
            byteCount: byteCount,
            truncated: truncated
        )
    }
}

// MARK: - Capture session (caps + throttled sink updates)

/// Accumulates parsed WebSocket messages for one upgraded exchange and publishes throttled
/// `CapturedRequest` snapshots to the capture sink. Both directions share one session; the
/// message array and caps are guarded by a lock because the two tunnel directions may in
/// principle be driven from different event loops.
final class WebSocketCaptureSession: @unchecked Sendable {
    private let sink: CaptureSink
    private let eventLoop: EventLoop
    private let lock = NSLock()
    private let parserLock = NSLock()
    private let throttleInterval: TimeAmount

    private var request: CapturedRequest
    private var parsers: [WebSocketDirection: WebSocketFrameParser] = [:]
    private var pendingFlush: Scheduled<Void>?
    private var dirty = false
    private var finished = false
    private var stopAppending = false
    private var storedMessages = 0
    private var storedPayloadBytes = 0

    init(
        request: CapturedRequest,
        sink: CaptureSink,
        eventLoop: EventLoop,
        throttleInterval: TimeAmount = .milliseconds(150)
    ) {
        self.request = request
        self.sink = sink
        self.eventLoop = eventLoop
        self.throttleInterval = throttleInterval
    }

    /// Feeds relayed bytes into the parser for `direction`.
    func ingest(_ buffer: ByteBuffer, direction: WebSocketDirection) {
        parserLock.lock()
        let parser: WebSocketFrameParser
        if let existing = parsers[direction] {
            parser = existing
        } else {
            let created = WebSocketFrameParser(direction: direction)
            parsers[direction] = created
            parser = created
        }
        parserLock.unlock()

        let parsed = parser.ingest(buffer)
        guard !parsed.isEmpty else { return }
        for message in parsed {
            append(message)
        }
    }

    /// Applies a late client-process attribution to the base capture and re-emits it.
    func applyClientProcess(_ process: ClientProcess?) {
        guard let process else { return }
        lock.lock()
        var updated = request
        updated.applyClientProcess(process)
        request = updated
        if !finished {
            dirty = true
            scheduleFlushLocked()
        }
        lock.unlock()
    }

    /// Publishes the final snapshot (safe to call multiple times).
    func flushFinal() {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        finished = true
        pendingFlush?.cancel()
        pendingFlush = nil
        dirty = false
        let snapshot = request
        lock.unlock()
        sink.captureDidUpdate(snapshot)
    }

    // MARK: Private

    private func append(_ parsed: ParsedWebSocketMessage) {
        lock.lock()
        guard !finished, !stopAppending else {
            lock.unlock()
            return
        }
        if storedMessages >= WebSocketCaptureLimits.maxMessages {
            stopAppending = true
            lock.unlock()
            return
        }
        if storedPayloadBytes + parsed.payload.count > WebSocketCaptureLimits.maxTotalPayloadBytes {
            stopAppending = true
            lock.unlock()
            return
        }

        request.webSocketMessages.append(
            WebSocketMessage(
                direction: parsed.direction,
                kind: parsed.kind,
                timestamp: parsed.timestamp,
                payload: parsed.payload.isEmpty ? nil : parsed.payload,
                byteCount: parsed.byteCount,
                truncated: parsed.truncated
            )
        )
        storedMessages += 1
        storedPayloadBytes += parsed.payload.count
        dirty = true
        scheduleFlushLocked()
        lock.unlock()
    }

    private func scheduleFlushLocked() {
        guard pendingFlush == nil, !finished else { return }
        pendingFlush = eventLoop.scheduleTask(in: throttleInterval) { [weak self] in
            self?.flushScheduled()
        }
    }

    private func flushScheduled() {
        lock.lock()
        pendingFlush = nil
        guard !finished, dirty else {
            lock.unlock()
            return
        }
        dirty = false
        let snapshot = request
        lock.unlock()
        sink.captureDidUpdate(snapshot)
    }
}

// MARK: - Pipeline handler

/// Sits in front of the raw tunnel relay on one direction, parses WebSocket frames and
/// forwards the original bytes unchanged (so tunnel throughput/behaviour is untouched).
final class WebSocketFrameCaptureHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer

    private let direction: WebSocketDirection
    private let session: WebSocketCaptureSession

    init(direction: WebSocketDirection, session: WebSocketCaptureSession) {
        self.direction = direction
        self.session = session
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let buffer = Self.unwrapInboundIn(data)
        session.ingest(buffer, direction: direction)
        context.fireChannelRead(data)
    }

    func channelInactive(context: ChannelHandlerContext) {
        session.flushFinal()
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        session.flushFinal()
        context.fireErrorCaught(error)
    }
}
