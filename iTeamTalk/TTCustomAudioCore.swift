import AVFoundation
import Foundation
@preconcurrency import TeamTalkKit

func ttCustomIsValidPort(_ value: String) -> Bool {
    guard let port = Int(value) else { return false }
    return (1...65_535).contains(port)
}

func ttCustomReferenceVolume(_ percent: Double) -> Int {
    let clampedPercent = min(200, max(0, percent))
    guard clampedPercent > 0 else { return 0 }
    return max(0, Int(82.832 * exp(0.0508 * clampedPercent) - 50))
}

func ttCustomReferencePercent(_ volume: Int) -> Double {
    guard volume > 0 else { return 0 }
    let normalizedVolume = max(0, Double(volume))
    return max(0, (log((normalizedVolume + 50.0) / 82.832) / 0.0508) + 0.5)
}

/// TeamTalk's master output volume uses 1000 as its default rather than a
/// percentage. Keep the UI percentage-based while preserving that default.
func ttCustomOutputVolume(_ percent: Double) -> Int32 {
    Int32(min(32_000, max(0, (percent * 10).rounded())))
}

func ttCustomResampleTo48k(_ samples: [Int16], sourceRate: Double) -> [Int16] {
    guard !samples.isEmpty, sourceRate > 0, abs(sourceRate - 48_000) > 0.5 else {
        return samples
    }
    let outputCount = max(1, Int((Double(samples.count) * 48_000.0 / sourceRate).rounded()))
    let ratio = sourceRate / 48_000.0
    var output = [Int16](repeating: 0, count: outputCount)
    for index in 0..<outputCount {
        let position = Double(index) * ratio
        let lower = min(samples.count - 1, Int(position))
        let upper = min(samples.count - 1, lower + 1)
        let fraction = position - Double(lower)
        let value = Double(samples[lower]) + (Double(samples[upper]) - Double(samples[lower])) * fraction
        output[index] = Int16(max(Double(Int16.min), min(Double(Int16.max), value)))
    }
    return output
}

/// Linear resampler that preserves fractional source position across capture
/// callbacks. Capture callbacks rarely contain an exact number of output
/// frames, so resetting interpolation state for every callback can create
/// small discontinuities at block boundaries.
final class TTCustomStreamingResampler {
    private var sourceRate = 48_000.0
    private var sourcePosition = 0.0
    private var pending = [Double]()

    func reset() {
        sourcePosition = 0
        pending.removeAll(keepingCapacity: true)
    }

    func process(_ samples: [Int16], sourceRate: Double) -> [Int16] {
        guard samples.isEmpty == false, sourceRate > 0 else { return [] }
        if abs(sourceRate - self.sourceRate) > 0.5 {
            self.sourceRate = sourceRate
            reset()
        }
        guard abs(sourceRate - 48_000) > 0.5 else {
            reset()
            self.sourceRate = sourceRate
            return samples
        }

        pending.append(contentsOf: samples.map(Double.init))
        let ratio = sourceRate / 48_000.0
        var output = [Int16]()
        output.reserveCapacity(max(1, Int(Double(samples.count) / ratio)))

        while sourcePosition + 1 < Double(pending.count) {
            let lowerIndex = Int(sourcePosition)
            let fraction = sourcePosition - Double(lowerIndex)
            let lower = pending[lowerIndex]
            let upper = pending[lowerIndex + 1]
            let value = lower + (upper - lower) * fraction
            output.append(Int16(max(Double(Int16.min), min(Double(Int16.max), value))))
            sourcePosition += ratio
        }

        let consumed = min(Int(sourcePosition), max(0, pending.count - 1))
        if consumed > 0 {
            pending.removeFirst(consumed)
            sourcePosition -= Double(consumed)
        }
        return output
    }
}

struct TTCustomSampleRing {
    private var storage: [Int16]
    private var readIndex = 0
    private var writeIndex = 0
    private(set) var count = 0
    private(set) var droppedSamples = 0

    var capacity: Int { storage.count }

    init(capacity: Int) {
        storage = [Int16](repeating: 0, count: max(1, capacity))
    }

    mutating func append(_ samples: [Int16]) {
        for sample in samples {
            if count == storage.count {
                readIndex = (readIndex + 1) % storage.count
                count -= 1
                droppedSamples += 1
            }
            storage[writeIndex] = sample
            writeIndex = (writeIndex + 1) % storage.count
            count += 1
        }
    }

    mutating func pop(into output: inout [Int16]) -> Int {
        guard output.isEmpty == false else { return 0 }
        output.withUnsafeMutableBufferPointer { buffer in
            buffer.initialize(repeating: 0)
        }
        let available = min(output.count, count)
        for index in 0..<available {
            output[index] = storage[readIndex]
            readIndex = (readIndex + 1) % storage.count
        }
        count -= available
        if count == 0 {
            readIndex = writeIndex
        }
        return available
    }

    mutating func removeAll() {
        readIndex = 0
        writeIndex = 0
        count = 0
        droppedSamples = 0
    }
}

struct TTCustomMixerStats: Equatable {
    var active = false
    var micFrames = 0
    var systemFrames = 0
    var micCapacity = 0
    var systemCapacity = 0
    var droppedMicFrames = 0
    var droppedSystemFrames = 0
    var micUnderruns = 0
    var systemUnderruns = 0
    var lateBlocks = 0
    var maxLatenessMilliseconds = 0.0
    var peak = 0.0
    var rms = 0.0
    var micRecoveryEvents = 0
    var systemRecoveryEvents = 0

    var micFillPercent: Double {
        guard micCapacity > 0 else { return 0 }
        return min(100, Double(micFrames) / Double(micCapacity) * 100)
    }

    var systemFillPercent: Double {
        guard systemCapacity > 0 else { return 0 }
        return min(100, Double(systemFrames) / Double(systemCapacity) * 100)
    }
}

/// Owns the iOS audio graph while TeamTalk is used only for transport and
/// codec work. No TeamTalk sound input/output device is opened by this type.
final class TTCustomAppleAudioPipeline {
    private let client: TeamTalkClient
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let transportQueue = DispatchQueue(label: "com.derrick.ttcustom.apple-audio-transport", qos: .userInitiated)
    private let playbackQueue = DispatchQueue(label: "com.derrick.ttcustom.apple-audio-playback", qos: .userInitiated)
    private let outputFormat = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
    private let playbackLock = NSLock()
    private var queuedPlaybackFrames = 0
    private var running = false
    private var microphoneEnabled = true
    private var echoCancellation = true

    init(client: TeamTalkClient) {
        self.client = client
    }

    func start(echoCancellation: Bool, microphoneEnabled: Bool) throws {
        guard !running else { return }
        self.echoCancellation = echoCancellation
        self.microphoneEnabled = microphoneEnabled

        let input = engine.inputNode
        // Do not enable AVAudioEngine voice processing in this baseline path.
        // It changes the I/O graph and was the second independent source of
        // VoiceOver disruption. Echo processing will be added after the plain
        // Apple capture/playback path is verified.
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw TTCustomAppleAudioPipelineError.invalidInputFormat
        }

        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: outputFormat)
        input.installTap(onBus: 0, bufferSize: 960, format: inputFormat) { [weak self] buffer, _ in
            self?.capture(buffer)
        }

        client.setRawAudioBlockHandler { [weak self] samples, sampleRate, channels, _ in
            self?.receive(samples: samples, sampleRate: sampleRate, channels: channels)
        }
        guard client.enableRawMixedVoiceAudio() else {
            input.removeTap(onBus: 0)
            engine.disconnectNodeOutput(player)
            engine.detach(player)
            client.setRawAudioBlockHandler(nil)
            throw TTCustomAppleAudioPipelineError.rawAudioUnavailable
        }

        do {
            try engine.start()
            player.play()
            running = true
        } catch {
            input.removeTap(onBus: 0)
            client.disableRawMixedVoiceAudio()
            client.setRawAudioBlockHandler(nil)
            engine.disconnectNodeOutput(player)
            engine.detach(player)
            throw error
        }
    }

    func stop() {
        guard running || client.isStarted else { return }
        running = false
        let input = engine.inputNode
        input.removeTap(onBus: 0)
        player.stop()
        engine.stop()
        client.endInsertedAudioBlock()
        client.disableRawMixedVoiceAudio()
        client.setRawAudioBlockHandler(nil)
        if engine.attachedNodes.contains(player) {
            engine.disconnectNodeOutput(player)
            engine.detach(player)
        }
        playbackLock.lock()
        queuedPlaybackFrames = 0
        playbackLock.unlock()
    }

    func setMicrophoneEnabled(_ enabled: Bool) {
        transportQueue.async { [weak self] in self?.microphoneEnabled = enabled }
    }

    private func capture(_ buffer: AVAudioPCMBuffer) {
        guard running, microphoneEnabled, let channels = buffer.floatChannelData else { return }
        let channelCount = Int(buffer.format.channelCount)
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0 else { return }
        var samples = [Int16](repeating: 0, count: frameCount)
        for frame in 0..<frameCount {
            var value: Float = 0
            for channel in 0..<channelCount { value += channels[channel][frame] }
            value /= Float(channelCount)
            samples[frame] = Int16(max(-1, min(1, value)) * Float(Int16.max))
        }
        let sourceRate = buffer.format.sampleRate
        transportQueue.async { [weak self] in
            guard let self, self.running, self.microphoneEnabled else { return }
            let output = ttCustomResampleTo48k(samples, sourceRate: sourceRate)
            guard !output.isEmpty else { return }
            _ = self.client.insertAudioBlock(samples: output, sampleRate: 48_000, channels: 1, streamID: 1)
        }
    }

    private func receive(samples: [Int16], sampleRate: Int32, channels: Int32) {
        guard running, !samples.isEmpty else { return }
        playbackQueue.async { [weak self] in
            guard let self, self.running else { return }
            let mono = self.downmix(samples: samples, channels: Int(channels))
            let output = ttCustomResampleTo48k(mono, sourceRate: Double(sampleRate))
            guard !output.isEmpty else { return }
            self.play(output)
        }
    }

    private func downmix(samples: [Int16], channels: Int) -> [Int16] {
        guard channels > 1 else { return samples }
        let frameCount = samples.count / channels
        var mono = [Int16](repeating: 0, count: frameCount)
        for frame in 0..<frameCount {
            var sum = 0
            for channel in 0..<channels { sum += Int(samples[frame * channels + channel]) }
            mono[frame] = Int16(max(Int(Int16.min), min(Int(Int16.max), sum / channels)))
        }
        return mono
    }

    private func play(_ samples: [Int16]) {
        playbackLock.lock()
        let canQueue = queuedPlaybackFrames + samples.count <= 9_600
        if canQueue { queuedPlaybackFrames += samples.count }
        playbackLock.unlock()
        guard canQueue else { return }

        guard let buffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: AVAudioFrameCount(samples.count)) else { return }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        guard let destination = buffer.floatChannelData?[0] else { return }
        for index in samples.indices { destination[index] = Float(samples[index]) / Float(Int16.max) }
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            guard let self else { return }
            self.playbackLock.lock()
            self.queuedPlaybackFrames = max(0, self.queuedPlaybackFrames - samples.count)
            self.playbackLock.unlock()
        }
    }
}

enum TTCustomAppleAudioPipelineError: LocalizedError {
    case invalidInputFormat
    case rawAudioUnavailable

    var errorDescription: String? {
        switch self {
        case .invalidInputFormat: return "iOS did not provide a usable microphone format"
        case .rawAudioUnavailable: return "TeamTalk could not enable decoded raw voice audio"
        }
    }
}

struct TTCustomAudioHealth: Equatable {
    var sampleRate = 0.0
    var bufferDuration = 0.0
    var inputRoute = "—"
    var outputRoute = "—"
    var mixerStats = TTCustomMixerStats()
}

struct TTCustomAGC {
    private(set) var gain = 1.0

    mutating func reset() {
        gain = 1.0
    }

    mutating func process(rms: Double, enabled: Bool) -> Double {
        guard enabled else {
            reset()
            return 1.0
        }

        let target = Double(Int16.max) * 0.16
        let requestedGain = rms > 250
            ? min(2.5, max(0.4, target / rms))
            : 1.0
        // Correct loud blocks quickly, but recover slowly. This avoids
        // audible pumping caused by applying the same response in both
        // directions.
        let coefficient = requestedGain < gain ? 0.25 : 0.05
        gain += (requestedGain - gain) * coefficient
        return gain
    }
}
