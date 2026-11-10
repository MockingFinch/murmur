import AVFoundation
import Foundation
import MurmurCore

/// Everything recorded in a session, as 16 kHz 16-bit mono PCM. The live
/// stream reads from it as it grows; a retry replays all of it.
final class PCMTape: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ chunk: Data) { lock.withLock { data.append(chunk) } }
    var count: Int { lock.withLock { data.count } }
    var all: Data { lock.withLock { data } }
    var seconds: Double { Double(count) / Double(DoubaoAPI.sampleRate * 2) }

    func slice(from start: Int, to end: Int) -> Data {
        lock.withLock {
            let s = max(0, min(start, data.count))
            let e = max(s, min(end, data.count))
            return data.subdata(in: s ..< e)
        }
    }
}

enum CaptureError: LocalizedError {
    case noInput, converter

    var errorDescription: String? {
        switch self {
        case .noInput: return "No microphone is available."
        case .converter: return "The microphone's audio format isn't supported."
        }
    }
}

/// The microphone, converted for Doubao, with loudness for the waveform.
final class AudioCapture: @unchecked Sendable {
    let tape = PCMTape()
    /// Loudness, 0...1, about every 20 ms; called on the main queue.
    var onLevels: (@Sendable ([Float]) -> Void)?

    private var engine: AVAudioEngine?
    private var configObserver: NSObjectProtocol?
    private let lock = NSLock()
    private var running = false

    func start() throws {
        let engine = AVAudioEngine()
        try install(on: engine)
        engine.prepare()
        try engine.start()
        lock.withLock {
            self.engine = engine
            running = true
        }
        // A headset plugged in or out mid-sentence: carry on with the new microphone.
        configObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            self?.restart()
        }
    }

    func stop() {
        let engine: AVAudioEngine? = lock.withLock {
            running = false
            let e = self.engine
            self.engine = nil
            return e
        }
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        configObserver = nil
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
    }

    private func restart() {
        guard let engine = lock.withLock({ running ? self.engine : nil }) else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        do {
            try install(on: engine)
            engine.prepare()
            try engine.start()
        } catch {
            NSLog("Murmur: could not restart the microphone: \(error)")
        }
    }

    private func install(on engine: AVAudioEngine) throws {
        let input = engine.inputNode
        let inFormat = input.outputFormat(forBus: 0)
        guard inFormat.sampleRate > 0, inFormat.channelCount > 0 else { throw CaptureError.noInput }
        guard let outFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: Double(DoubaoAPI.sampleRate),
                                            channels: 1, interleaved: true),
              let converter = AVAudioConverter(from: inFormat, to: outFormat) else { throw CaptureError.converter }
        converter.downmix = true

        let tape = self.tape
        let onLevels = self.onLevels
        let window = max(1, Int(inFormat.sampleRate * 0.02))
        let ratio = outFormat.sampleRate / inFormat.sampleRate

        input.installTap(onBus: 0, bufferSize: 1024, format: inFormat) { buffer, _ in
            if let onLevels, let channels = buffer.floatChannelData {
                let samples = channels[0]
                let n = Int(buffer.frameLength)
                var levels: [Float] = []
                var start = 0
                while start < n {
                    let end = min(n, start + window)
                    var sum: Float = 0
                    for i in start ..< end { sum += samples[i] * samples[i] }
                    let rms = sqrt(sum / Float(max(1, end - start)))
                    let db = 20 * log10(max(rms, 1e-6))
                    levels.append(min(1, max(0, (db + 52) / 40)))
                    start = end
                }
                DispatchQueue.main.async { onLevels(levels) }
            }

            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
            guard let out = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: capacity) else { return }
            var supplied = false
            var error: NSError?
            let status = converter.convert(to: out, error: &error) { _, inputStatus in
                if supplied {
                    inputStatus.pointee = .noDataNow
                    return nil
                }
                supplied = true
                inputStatus.pointee = .haveData
                return buffer
            }
            if status != .error, out.frameLength > 0, let pcm = out.int16ChannelData {
                tape.append(Data(bytes: pcm[0], count: Int(out.frameLength) * 2))
            }
        }
    }
}
