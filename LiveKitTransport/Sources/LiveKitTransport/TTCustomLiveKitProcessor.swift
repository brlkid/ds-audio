import Foundation
import LiveKit

/// Allocation-free post-mix safety processing for the outgoing track.
final class TTCustomLiveKitProcessor: NSObject, AudioCustomProcessingDelegate, @unchecked Sendable {
    struct Metrics: Sendable {
        let processedFrames: Int64
        let processedBlocks: Int64
        let nonSilentBlocks: Int64
        let lastPeak: Double
        let lastRMS: Double
    }

    private let lock = NSLock()
    private var limiterEnabled = true
    private var processedFrames: Int64 = 0
    private var processedBlocks: Int64 = 0
    private var nonSilentBlocks: Int64 = 0
    private var lastPeak = 0.0
    private var lastRMS = 0.0

    func setLimiterEnabled(_ enabled: Bool) {
        lock.lock()
        limiterEnabled = enabled
        lock.unlock()
    }

    func metrics() -> Metrics {
        lock.lock()
        defer { lock.unlock() }
        return Metrics(
            processedFrames: processedFrames,
            processedBlocks: processedBlocks,
            nonSilentBlocks: nonSilentBlocks,
            lastPeak: lastPeak,
            lastRMS: lastRMS
        )
    }

    func audioProcessingInitialize(sampleRate sampleRateHz: Int, channels: Int) {}

    func audioProcessingProcess(audioBuffer: LKAudioBuffer) {
        let frames = audioBuffer.frames
        let channels = audioBuffer.channels
        guard frames > 0, channels > 0 else { return }

        lock.lock()
        let enabled = limiterEnabled
        lock.unlock()

        let sampleScale = Float(Int16.max)
        var sumSquares: Double = 0
        var peak: Float = 0
        for channel in 0..<channels {
            let samples = audioBuffer.rawBuffer(forChannel: channel)
            for frame in 0..<frames {
                let sample = samples[frame]
                peak = max(peak, abs(sample))
                sumSquares += Double(sample) * Double(sample)
            }
        }

        var gain: Float = 1
        if enabled {
            // LKAudioBuffer exposes Int16-scale samples through a Float
            // pointer. The values are not normalized to [-1, 1].
            let ceiling = sampleScale * 0.95
            if peak > ceiling {
                gain = ceiling / peak
                for channel in 0..<channels {
                    let samples = audioBuffer.rawBuffer(forChannel: channel)
                    for frame in 0..<frames { samples[frame] *= gain }
                }
                peak = ceiling
            }
        }

        let rms = sqrt(sumSquares / Double(frames * channels)) * Double(gain) / Double(sampleScale)
        lock.lock()
        processedFrames += Int64(frames)
        processedBlocks += 1
        if peak > sampleScale * 0.0001 { nonSilentBlocks += 1 }
        lastPeak = Double(peak) / Double(sampleScale)
        lastRMS = rms
        lock.unlock()
    }

    func audioProcessingRelease() {}
}
