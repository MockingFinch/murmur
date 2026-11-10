import Foundation
import Network
@testable import MurmurCore

/// A tiny HTTP/1.1 server on loopback that plays a script per request.
final class FakeHTTPServer: @unchecked Sendable {
    enum Step { case write(String), wait(TimeInterval) }

    private let listener: NWListener
    private let queue = DispatchQueue(label: "fake-http")
    private let script: (Int, String) -> [Step]
    private let lock = NSLock()
    private var count = 0
    private(set) var requests: [String] = []
    var port: UInt16 { listener.port?.rawValue ?? 0 }
    var base: URL { URL(string: "http://127.0.0.1:\(port)/api/v1")! }

    init(script: @escaping (_ index: Int, _ request: String) -> [Step]) throws {
        self.script = script
        listener = try NWListener(using: .tcp, on: .any)
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { if case .ready = $0 { ready.signal() } }
        listener.newConnectionHandler = { [weak self] conn in self?.accept(conn) }
        listener.start(queue: queue)
        _ = ready.wait(timeout: .now() + 5)
    }

    deinit { listener.cancel() }

    var requestCount: Int { lock.withLock { count } }
    var allRequests: [String] { lock.withLock { requests } }

    private func accept(_ conn: NWConnection) {
        conn.start(queue: queue)
        read(conn, buffer: Data())
    }

    private func read(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, done, error in
            guard let self else { return }
            var buf = buffer
            if let data { buf.append(data) }
            if let text = String(data: buf, encoding: .utf8), let headerEnd = text.range(of: "\r\n\r\n") {
                let head = text[..<headerEnd.lowerBound].lowercased()
                var length = 0
                if let line = head.split(separator: "\r\n").first(where: { $0.hasPrefix("content-length:") }) {
                    length = Int(line.split(separator: ":")[1].trimmingCharacters(in: .whitespaces)) ?? 0
                }
                let bodyBytes = buf.count - text[..<headerEnd.upperBound].utf8.count
                if bodyBytes >= length {
                    let index: Int = self.lock.withLock {
                        self.count += 1
                        self.requests.append(text)
                        return self.count
                    }
                    play(script(index, text), on: conn)
                    return
                }
            }
            if done || error != nil { conn.cancel(); return }
            read(conn, buffer: buf)
        }
    }

    private func play(_ steps: [Step], on conn: NWConnection) {
        guard let step = steps.first else {
            conn.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in conn.cancel() })
            return
        }
        let rest = Array(steps.dropFirst())
        switch step {
        case .write(let s):
            conn.send(content: Data(s.utf8), completion: .contentProcessed { [weak self] _ in self?.play(rest, on: conn) })
        case .wait(let t):
            queue.asyncAfter(deadline: .now() + t) { [weak self] in self?.play(rest, on: conn) }
        }
    }

    static func head(_ status: Int, _ reason: String, contentType: String = "text/event-stream") -> String {
        "HTTP/1.1 \(status) \(reason)\r\nContent-Type: \(contentType)\r\nConnection: close\r\n\r\n"
    }

    static func chunk(_ content: String, finish: String? = nil) -> String {
        let delta = (try? JSONSerialization.data(withJSONObject: ["content": content])).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        let f = finish.map { "\"\($0)\"" } ?? "null"
        return "data: {\"model\":\"fake/model\",\"choices\":[{\"delta\":\(delta),\"finish_reason\":\(f)}]}\n\n"
    }
}

/// A WebSocket server speaking Doubao's binary protocol.
final class FakeDoubaoServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "fake-doubao")
    private let lock = NSLock()
    private(set) var audioBytes = 0
    private(set) var sawLast = false
    /// Error to answer the start request with, instead of accepting it.
    var refuseWith: (code: UInt32, message: String)?
    /// Stay silent after the last packet (to test the final timeout).
    var neverFinish = false
    var finalText = "你好，世界。"

    var url: URL { URL(string: "ws://127.0.0.1:\(listener.port?.rawValue ?? 0)/api/v3/sauc/bigmodel_async")! }

    init() throws {
        let params = NWParameters.tcp
        let ws = NWProtocolWebSocket.Options()
        ws.autoReplyPing = true
        let headerQueue = DispatchQueue(label: "fake-doubao-headers")
        let box = HeaderBox()
        headerBox = box
        ws.setClientRequestHandler(headerQueue) { _, additional in
            box.store(additional)
            return NWProtocolWebSocket.Response(status: .accept, subprotocol: nil)
        }
        params.defaultProtocolStack.applicationProtocols.insert(ws, at: 0)
        listener = try NWListener(using: params, on: .any)
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { if case .ready = $0 { ready.signal() } }
        listener.newConnectionHandler = { [weak self] conn in
            guard let self else { return }
            conn.start(queue: self.queue)
            self.receive(conn)
        }
        listener.start(queue: queue)
        _ = ready.wait(timeout: .now() + 5)
    }

    deinit { listener.cancel() }

    private var headerBox: HeaderBox?
    var capturedHeaders: [String: String] { headerBox?.all ?? [:] }
    var receivedAudioBytes: Int { lock.withLock { audioBytes } }

    private func receive(_ conn: NWConnection) {
        conn.receiveMessage { [weak self] data, _, _, error in
            guard let self, error == nil, let data, let frame = try? DoubaoCodec.decode(data) else { return }
            self.handle(frame, conn)
            self.receive(conn)
        }
    }

    private func handle(_ frame: DoubaoFrame, _ conn: NWConnection) {
        switch frame.kind {
        case .fullClientRequest:
            if let refuse = refuseWith {
                send(DoubaoFrame(kind: .serverError, serialization: .json, errorCode: refuse.code,
                                 payload: Data("{\"message\":\"\(refuse.message)\"}".utf8)), conn)
                return
            }
            send(response(text: "", seq: 1, last: false), conn)
        case .audioOnlyRequest:
            lock.withLock { audioBytes += frame.payload.count }
            if frame.isLast {
                lock.withLock { sawLast = true }
                if !neverFinish { send(response(text: finalText, seq: frame.sequence, last: true), conn) }
            } else {
                send(response(text: "你好", seq: frame.sequence, last: false), conn)
            }
        default:
            break
        }
    }

    private func response(text: String, seq: Int32, last: Bool) -> DoubaoFrame {
        let json = "{\"audio_info\":{\"duration\":1000},\"result\":{\"text\":\"\(text)\"}}"
        return DoubaoFrame(kind: .fullServerResponse, flags: last ? [.sequence, .last] : .sequence, serialization: .json,
                           compression: .gzip, sequence: last ? -abs(seq) : seq, payload: Data(json.utf8))
    }

    private func send(_ frame: DoubaoFrame, _ conn: NWConnection) {
        guard let bytes = try? DoubaoCodec.encode(frame) else { return }
        let meta = NWProtocolWebSocket.Metadata(opcode: .binary)
        let ctx = NWConnection.ContentContext(identifier: "frame", metadata: [meta])
        conn.send(content: bytes, contentContext: ctx, isComplete: true, completion: .contentProcessed { _ in })
    }
}

final class HeaderBox: @unchecked Sendable {
    private let lock = NSLock()
    private var headers: [String: String] = [:]
    func store(_ list: [(name: String, value: String)]) {
        lock.withLock { for h in list { headers[h.name.lowercased()] = h.value } }
    }
    var all: [String: String] { lock.withLock { headers } }
}
