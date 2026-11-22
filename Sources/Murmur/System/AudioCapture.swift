import AudioToolbox
import AVFoundation
import CoreAudio
import Foundation
import MurmurCore

enum CaptureError: LocalizedError {
    case noInput, converter

    var errorDescription: String? {
        switch self {
        case .noInput: return "No microphone is available."
        case .converter: return "The microphone's audio format isn't supported."
        }
    }
}

/// An available macOS audio input device.
struct AudioInputDevice: Identifiable, Hashable, Sendable {
    let uid: String
    let deviceID: AudioDeviceID
    let name: String
    let isDefault: Bool
    var id: String { uid }
}

/// Enumerates connected microphones via CoreAudio so users can pin a preferred
/// input (for example, MacBook Pro Microphone instead of AirPods HFP).
enum AudioDevices {
    static func inputs() -> [AudioInputDevice] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        let sys = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(sys, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(sys, &address, 0, nil, &size, &ids) == noErr else { return [] }

        let defaultID = defaultInputDeviceID()
        var list: [AudioInputDevice] = []
        for id in ids {
            guard hasInputStreams(id),
                  let uid = stringProperty(id, kAudioDevicePropertyDeviceUID), !uid.isEmpty,
                  let name = stringProperty(id, kAudioObjectPropertyName), !name.isEmpty else { continue }
            list.append(AudioInputDevice(uid: uid, deviceID: id, name: name, isDefault: id == defaultID))
        }
        return list.sorted {
            if $0.isDefault != $1.isDefault { return $0.isDefault }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    static func deviceID(forUID uid: String) -> AudioDeviceID? {
        guard !uid.isEmpty else { return nil }
        return inputs().first { $0.uid == uid }?.deviceID
    }

    static func defaultInputName() -> String? {
        guard let id = defaultInputDeviceID() else { return nil }
        return stringProperty(id, kAudioObjectPropertyName)
    }

    private static func defaultInputDeviceID() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id) == noErr,
              id != kAudioObjectUnknown else { return nil }
        return id
    }

    private static func hasInputStreams(_ id: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr && size > 0
    }

    private static func stringProperty(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var unmanaged: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &unmanaged) { ptr in
            AudioObjectGetPropertyData(id, &address, 0, nil, &size, ptr)
        }
        guard status == noErr, let cf = unmanaged?.takeRetainedValue() else { return nil }
        return cf as String
    }
}

/// The microphone, converted for Doubao, with loudness for the waveform.
final class AudioCapture: @unchecked Sendable {
    let tape = PCMTape()
    let preferredDeviceUID: String
    /// Loudness, 0...1, about every 20 ms; called on the main queue.
    var onLevels: (@Sendable ([Float]) -> Void)?
    /// The microphone went away and no other could take over; called on
    /// the main queue. What was recorded until then is on the tape.
    var onLost: (@Sendable () -> Void)?

    private var engine: AVAudioEngine?
    private var configObserver: NSObjectProtocol?
    private let lock = NSLock()
    private var running = false

    init(preferredDeviceUID: String = "") {
        self.preferredDeviceUID = preferredDeviceUID
    }

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
            onLost?()
        }
    }

    private func install(on engine: AVAudioEngine) throws {
        let input = engine.inputNode
        if var deviceID = AudioDevices.deviceID(forUID: preferredDeviceUID), let audioUnit = input.audioUnit {
            _ = AudioUnitSetProperty(
                audioUnit,
                kAudioOutputUnitProperty_CurrentDevice,
                kAudioUnitScope_Global,
                0,
                &deviceID,
                UInt32(MemoryLayout<AudioDeviceID>.size)
            )
        }
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
