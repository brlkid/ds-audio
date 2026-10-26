import Foundation

/// Converts capture buffers to the 48 kHz mono format used by the LiveKit
/// injection path while preserving fractional sample position between blocks.
final class TTCustomStreamingResampler {
    private var sourceRate = 48_000.0
    private var sourcePosition = 0.0
    private var pending = [Double]()

    func reset() {
        sourcePosition = 0
        pending.removeAll(keepingCapacity: true)
    }

    func process(_ samples: [Int16], sourceRate: Double) -> [Int16] {
        guard !samples.isEmpty, sourceRate > 0 else { return [] }
        if abs(sourceRate - self.sourceRate) > 0.5 {
            self.sourceRate = sourceRate
            reset()
        }
        guard abs(sourceRate - 48_000) > 0.5 else { return samples }
        pending.append(contentsOf: samples.map(Double.init))
        let ratio = sourceRate / 48_000.0
        var output = [Int16]()
        output.reserveCapacity(max(1, Int(Double(samples.count) / ratio)))
        while sourcePosition + 1 < Double(pending.count) {
            let lowerIndex = Int(sourcePosition)
            let fraction = sourcePosition - Double(lowerIndex)
            let value = pending[lowerIndex] + (pending[lowerIndex + 1] - pending[lowerIndex]) * fraction
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
