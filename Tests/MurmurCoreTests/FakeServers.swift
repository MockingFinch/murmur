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

    /// Recognise "sentences" from the audio itself: each second whose
    /// samples hold the value v is heard as "第v句。", confirmed once the
    /// second is complete. Resuming at the wrong place repeats or skips one.
    var sentences = false
    /// Connections (1-based) closed once they have received this much audio.
    var dropAfterBytes: [Int: Int] = [:]
    /// Connections (1-based) closed as soon as they ask to start.
    var refuse: (Int) -> Bool = { _ in false }
    /// From this connection on, the start request is answered with an error.
    var refuseFrom: (connection: Int, code: UInt32, message: String)?
    private var connections = 0
    private var perConnection: [ObjectIdentifier: (index: Int, audio: Data)] = [:]
    var connectionCount: Int { lock.withLock { connections } }

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
            self.lock.withLock {
                self.connections += 1
                self.perConnection[ObjectIdentifier(conn)] = (self.connections, Data())
            }
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
        let index = lock.withLock { perConnection[ObjectIdentifier(conn)]?.index ?? 0 }
        if sentences { return handleSentences(frame, conn, index) }
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

    private func handleSentences(_ frame: DoubaoFrame, _ conn: NWConnection, _ index: Int) {
        switch frame.kind {
        case .fullClientRequest:
            if refuse(index) { conn.cancel(); return }
            if let r = refuseFrom, index >= r.connection {
                send(DoubaoFrame(kind: .serverError, serialization: .json, errorCode: r.code,
                                 payload: Data("{\"message\":\"\(r.message)\"}".utf8)), conn)
                return
            }
            send(response(text: "", seq: 1, last: false), conn)
        case .audioOnlyRequest:
            let audio: Data = lock.withLock {
                audioBytes += frame.payload.count
                perConnection[ObjectIdentifier(conn)]?.audio.append(frame.payload)
                return perConnection[ObjectIdentifier(conn)]?.audio ?? Data()
            }
            if let limit = dropAfterBytes[index], audio.count >= limit { conn.cancel(); return }
            send(sentenceResponse(audio, seq: frame.sequence, last: frame.isLast), conn)
        default:
            break
        }
    }

    /// Whole seconds are confirmed sentences; a part of one is still in progress.
    private func sentenceResponse(_ audio: Data, seq: Int32, last: Bool) -> DoubaoFrame {
        let second = 32_000
        var utterances: [[String: Any]] = []
        var start = 0
        while start < audio.count {
            let end = min(audio.count, start + second)
            let value = audio.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: start, as: Int16.self) }
            let whole = end - start == second
            utterances.append(["text": whole || last ? "第\(value)句。" : "第\(value)",
                               "start_time": start / 32, "end_time": end / 32, "definite": whole || last])
            start = end
        }
        let text = utterances.map { $0["text"] as! String }.joined()
        let body: [String: Any] = ["audio_info": ["duration": audio.count / 32], "result": ["text": text, "utterances": utterances]]
        let json = (try? JSONSerialization.data(withJSONObject: body)) ?? Data()
        return DoubaoFrame(kind: .fullServerResponse, flags: last ? [.sequence, .last] : .sequence, serialization: .json,
                           compression: .gzip, sequence: last ? -abs(seq) : seq, payload: json)
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
