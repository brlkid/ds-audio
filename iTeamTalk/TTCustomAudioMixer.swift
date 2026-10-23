import AVFoundation
import Foundation
import OSLog

final class TTCustomAudioMixer {
    private let logger = Logger(subsystem: "com.derrick.ttcustom", category: "mixer")
    private let queue = DispatchQueue(label: "com.derrick.ttcustom.audio-mixer", qos: .userInitiated)
    private let client: TTCustomAudioOutput
    private let engine = AVAudioEngine()
    private let blockIntervalNanoseconds: UInt64 = 20_000_000
    private var schedulerGeneration: UInt64 = 0
    private var schedulerRunning = false
    private var schedulerTimer: DispatchSourceTimer?
    private var schedulerNextDeadline: UInt64 = 0
    // One second per source bounds latency if ScreenCaptureKit stalls or
    // delivers a burst. The mixer owns these rings on `queue`.
    private var micSamples = TTCustomSampleRing(capacity: 48_000)
    private var systemSamples = TTCustomSampleRing(capacity: 48_000)
    private var micEnabled = true
    private var systemEnabled = true
    private var micGain = 1.0
    private var systemGain = 1.0
    private var masterGain = 1.0
    private var automaticGainControl = true
    private var automaticGain = TTCustomAGC()
    private var noiseGateEnabled = false
    private var compressorEnabled = false
    private var limiterEnabled = true
    private var streamID: Int32 = 1
    private let frameCount = 960
    private var micBlock = [Int16](repeating: 0, count: 960)
    private var systemBlock = [Int16](repeating: 0, count: 960)
    private var mixValues = [Double](repeating: 0, count: 960)
    private var mixedBlock = [Int16](repeating: 0, count: 960)
    private var micUnderruns = 0
    private var systemUnderruns = 0
    private var lateBlocks = 0
    private var maxLatenessNanoseconds: UInt64 = 0
    private var lastPeak = 0.0
    private var lastRMS = 0.0
    private var micRecoveryEvents = 0
    private var systemRecoveryEvents = 0
    private var micWasUnderrunning = false
    private var systemWasUnderrunning = false
    private var micAppendBlocks = 0
    private var systemAppendBlocks = 0

    private func trace(_ message: String) {
        logger.info("\(message, privacy: .public)")
        print("[TTMixer] \(message)")
    }

    init(client: TTCustomAudioOutput) {
        self.client = client
    }

    func start(micEnabled: Bool, systemEnabled: Bool, micGain: Double, systemGain: Double, masterGain: Double, automaticGainControl: Bool, noiseGateEnabled: Bool, compressorEnabled: Bool, limiterEnabled: Bool, useEngineMicrophone: Bool = true) throws {
        let alreadyRunning = queue.sync { schedulerRunning }
        if alreadyRunning {
            stop()
        }
        self.micEnabled = micEnabled
        self.systemEnabled = systemEnabled
        self.micGain = micGain
        self.systemGain = systemGain
        self.masterGain = masterGain
        self.automaticGainControl = automaticGainControl
        self.noiseGateEnabled = noiseGateEnabled
        self.compressorEnabled = compressorEnabled
        self.limiterEnabled = limiterEnabled
        automaticGain.reset()
        trace("mixer start: micEnabled=\(micEnabled), systemEnabled=\(systemEnabled), engineMic=\(useEngineMicrophone)")
        if useEngineMicrophone {
            let input = engine.inputNode
            input.removeTap(onBus: 0)
            if #available(iOS 13.0, *) {
                try input.setVoiceProcessingEnabled(true)
            }
            installMicrophoneTap(on: input)
            engine.prepare()
            try engine.start()
        }

        queue.sync {
            micSamples.removeAll()
            systemSamples.removeAll()
            micUnderruns = 0
            systemUnderruns = 0
            lateBlocks = 0
            maxLatenessNanoseconds = 0
            lastPeak = 0
            lastRMS = 0
            micRecoveryEvents = 0
            systemRecoveryEvents = 0
            micWasUnderrunning = false
            systemWasUnderrunning = false
            micAppendBlocks = 0
            systemAppendBlocks = 0
            schedulerRunning = true
            startScheduler()
        }
    }

    private func installMicrophoneTap(on input: AVAudioInputNode) {
        let format = input.inputFormat(forBus: 0)
        let resampler = TTCustomStreamingResampler()
        input.installTap(onBus: 0, bufferSize: 960, format: format) { [weak self] buffer, _ in
            guard let self, let channels = buffer.floatChannelData else { return }
            let frames = Int(buffer.frameLength)
            let sampleRate = format.sampleRate
            self.queue.async {
                var samples = [Int16](repeating: 0, count: frames)
                for frame in 0..<frames {
                    var value = channels[0][frame]
                    if sampleRate != 48_000 {
                        value = max(-1, min(1, value))
                    }
                    samples[frame] = Int16(max(-1, min(1, value)) * Float(Int16.max))
                }
                self.micSamples.append(resampler.process(samples, sourceRate: sampleRate))
            }
        }
    }

    func restartMicrophoneCapture() {
        queue.async { [weak self] in
            guard let self else { return }
            let input = self.engine.inputNode
            input.removeTap(onBus: 0)
            self.engine.stop()
            do {
                if #available(iOS 13.0, *) {
                    try input.setVoiceProcessingEnabled(true)
                }
                self.installMicrophoneTap(on: input)
                self.engine.prepare()
                try self.engine.start()
            } catch {
                // The session will retry on the next route change or capture
                // start. Do not tear down system audio for a transient input
                // interruption.
            }
        }
    }

    func appendSystemAudio(_ samples: [Int16]) {
        queue.async { [weak self] in
            guard let self else { return }
            self.systemAppendBlocks += 1
            self.systemSamples.append(samples)
            if self.systemAppendBlocks == 1 || self.systemAppendBlocks % 100 == 0 {
                self.trace("system append #\(self.systemAppendBlocks): \(samples.count) samples, queue=\(self.systemSamples.count)")
            }
        }
    }

    func appendMicrophoneAudio(_ samples: [Int16]) {
        queue.async { [weak self] in
            guard let self else { return }
            self.micAppendBlocks += 1
            self.micSamples.append(samples)
            if self.micAppendBlocks == 1 || self.micAppendBlocks % 100 == 0 {
                self.trace("microphone append #\(self.micAppendBlocks): \(samples.count) samples, queue=\(self.micSamples.count)")
            }
        }
    }

    func setMicrophoneEnabled(_ enabled: Bool) {
        queue.async { [weak self] in self?.micEnabled = enabled }
    }

    func setSystemAudioEnabled(_ enabled: Bool) {
        queue.async { [weak self] in self?.systemEnabled = enabled }
    }

    func setMicGain(_ gain: Double) {
        queue.async { [weak self] in self?.micGain = max(0, gain) }
    }

    func setSystemGain(_ gain: Double) {
        queue.async { [weak self] in self?.systemGain = max(0, gain) }
    }

    func setMasterGain(_ gain: Double) {
        queue.async { [weak self] in self?.masterGain = max(0, gain) }
    }

    func setAutomaticGainControl(_ enabled: Bool) {
        queue.async { [weak self] in
            self?.automaticGainControl = enabled
            if !enabled { self?.automaticGain.reset() }
        }
    }

    func setNoiseGateEnabled(_ enabled: Bool) {
        queue.async { [weak self] in self?.noiseGateEnabled = enabled }
    }

    func setCompressorEnabled(_ enabled: Bool) {
        queue.async { [weak self] in self?.compressorEnabled = enabled }
    }

    func setLimiterEnabled(_ enabled: Bool) {
        queue.async { [weak self] in self?.limiterEnabled = enabled }
    }

    func snapshot() -> TTCustomMixerStats {
        queue.sync {
            TTCustomMixerStats(
                active: schedulerRunning,
                micFrames: micSamples.count,
                systemFrames: systemSamples.count,
                micCapacity: micSamples.capacity,
                systemCapacity: systemSamples.capacity,
                droppedMicFrames: micSamples.droppedSamples,
                droppedSystemFrames: systemSamples.droppedSamples,
                micUnderruns: micUnderruns,
                systemUnderruns: systemUnderruns,
                lateBlocks: lateBlocks,
                maxLatenessMilliseconds: Double(maxLatenessNanoseconds) / 1_000_000,
                peak: lastPeak,
                rms: lastRMS,
                micRecoveryEvents: micRecoveryEvents,
                systemRecoveryEvents: systemRecoveryEvents
            )
        }
    }

    func flushBuffers() {
        queue.sync {
            micSamples.removeAll()
            systemSamples.removeAll()
            micUnderruns = 0
            systemUnderruns = 0
            lateBlocks = 0
            maxLatenessNanoseconds = 0
            lastPeak = 0
            lastRMS = 0
            micRecoveryEvents = 0
            systemRecoveryEvents = 0
            micWasUnderrunning = false
            systemWasUnderrunning = false
        }
        client.endInsertedAudioBlock()
    }

    func stop() {
        queue.sync {
            // Scheduled callbacks cannot be cancelled individually. Advancing
            // the generation makes any callback already in the queue a no-op.
            schedulerRunning = false
            schedulerGeneration &+= 1
            schedulerTimer?.setEventHandler {}
            schedulerTimer?.cancel()
            schedulerTimer = nil
            schedulerNextDeadline = 0
        }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        queue.sync {
            micSamples.removeAll()
            systemSamples.removeAll()
            micUnderruns = 0
            systemUnderruns = 0
            lateBlocks = 0
            maxLatenessNanoseconds = 0
            lastPeak = 0
            lastRMS = 0
            micRecoveryEvents = 0
            systemRecoveryEvents = 0
            micWasUnderrunning = false
            systemWasUnderrunning = false
        }
        client.endInsertedAudioBlock()
    }

    private func startScheduler() {
        schedulerGeneration &+= 1
        let generation = schedulerGeneration
        schedulerNextDeadline = DispatchTime.now().uptimeNanoseconds + blockIntervalNanoseconds
        let timer = DispatchSource.makeTimerSource(flags: .strict, queue: queue)
        timer.schedule(
            deadline: .now() + .nanoseconds(Int(blockIntervalNanoseconds)),
            repeating: .nanoseconds(Int(blockIntervalNanoseconds)),
            leeway: .milliseconds(2)
        )
        timer.setEventHandler { [weak self] in
            guard let self, self.schedulerRunning, self.schedulerGeneration == generation else { return }
            let now = DispatchTime.now().uptimeNanoseconds
            if now > self.schedulerNextDeadline {
                let lateness = now - self.schedulerNextDeadline
                self.lateBlocks += 1
                self.maxLatenessNanoseconds = max(self.maxLatenessNanoseconds, lateness)
            }
            self.sendNextBlock()
            self.schedulerNextDeadline += self.blockIntervalNanoseconds
            while self.schedulerNextDeadline <= DispatchTime.now().uptimeNanoseconds {
                self.schedulerNextDeadline += self.blockIntervalNanoseconds
            }
        }
        schedulerTimer = timer
        timer.resume()
    }

    private func sendNextBlock() {
        // Always emit one fixed 20 ms block. Missing input is zero-filled;
        // this prevents bursts and keeps the TeamTalk stream clock stable.
        let micAvailable = micSamples.pop(into: &micBlock)
        let systemAvailable = systemSamples.pop(into: &systemBlock)
        let micUnderrun = micEnabled && micAvailable < frameCount
        let systemUnderrun = systemEnabled && systemAvailable < frameCount
        if micUnderrun { micUnderruns += 1 }
        if systemUnderrun { systemUnderruns += 1 }
        if (micUnderrun || systemUnderrun) && (micUnderruns + systemUnderruns == 1 || (micUnderruns + systemUnderruns) % 100 == 0) {
            trace("mixer underrun: micAvailable=\(micAvailable), systemAvailable=\(systemAvailable), micUnderruns=\(self.micUnderruns), systemUnderruns=\(self.systemUnderruns)")
        }
        if micWasUnderrunning && !micUnderrun { micRecoveryEvents += 1 }
        if systemWasUnderrunning && !systemUnderrun { systemRecoveryEvents += 1 }
        micWasUnderrunning = micUnderrun
        systemWasUnderrunning = systemUnderrun
        var micPower = 0.0
        var peak = 0.0
        for index in 0..<frameCount {
            var mic = micEnabled ? Double(micBlock[index]) * micGain : 0
            if noiseGateEnabled && abs(mic) < 700 { mic = 0 }
            micPower += mic * mic
            mixValues[index] = mic
        }
        if automaticGainControl {
            let rms = sqrt(micPower / Double(frameCount))
            _ = automaticGain.process(rms: rms, enabled: true)
        }
        for index in 0..<frameCount {
            var mic = mixValues[index] * (automaticGainControl ? automaticGain.gain : 1.0)
            let system = systemEnabled ? Double(systemBlock[index]) * systemGain : 0
            if compressorEnabled {
                let threshold = Double(Int16.max) * 0.55
                let magnitude = abs(mic)
                if magnitude > threshold {
                    let compressed = threshold + (magnitude - threshold) * 0.25
                    mic = mic.sign == .minus ? -compressed : compressed
                }
            }
            let value = (mic + system) * masterGain
            mixValues[index] = value
            peak = max(peak, abs(value))
        }
        // Apply one transparent gain reduction to the block only when needed;
        // unlike tanh, this does not reshape every sample and avoids audible
        // nonlinear distortion.
        let limiterScale = limiterEnabled && peak > Double(Int16.max)
            ? Double(Int16.max) / peak
            : 1.0
        var outputPower = 0.0
        var outputPeak = 0.0
        for index in 0..<frameCount {
            let value = mixValues[index] * limiterScale
            let clipped = max(Double(Int16.min), min(Double(Int16.max), value))
            mixedBlock[index] = Int16(clipped)
            outputPower += clipped * clipped
            outputPeak = max(outputPeak, abs(clipped))
        }
        lastPeak = outputPeak / Double(Int16.max)
        lastRMS = sqrt(outputPower / Double(frameCount)) / Double(Int16.max)
        _ = client.insertAudioBlock(
            samples: mixedBlock,
            sampleRate: 48_000,
            channels: 1,
            streamID: streamID
        )
    }
}
