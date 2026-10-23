import AVFoundation
import Foundation
import Network
import ReplayKit

final class BroadcastSampleHandler: RPBroadcastSampleHandler {
    private let queue = DispatchQueue(label: "com.derrick.ttcustom.replaykit-sample", qos: .userInitiated)
    private var connection: NWConnection?

    override func broadcastStarted(withSetupInfo setupInfo: [String : NSObject]?) {
        let connection = NWConnection(host: "127.0.0.1", port: 39_551, using: .udp)
        self.connection = connection
        connection.start(queue: queue)
    }

    override func broadcastFinished() {
        connection?.cancel()
        connection = nil
    }

    override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer, with sampleBufferType: RPSampleBufferType) {
        let source: UInt8
        switch sampleBufferType {
        case .audioMic: source = 1
        case .audioApp: source = 2
        default: return
        }
        guard let samples = Self.samples(from: sampleBuffer) else { return }
        var packet = Data([0x54, 0x54, 0x41, 0x55, source])
        packet.append(contentsOf: withUnsafeBytes(of: UInt32(48_000).littleEndian, Array.init))
        packet.append(contentsOf: withUnsafeBytes(of: UInt16(samples.count).littleEndian, Array.init))
        for sample in samples {
            packet.append(contentsOf: withUnsafeBytes(of: sample.littleEndian, Array.init))
        }
        connection?.send(content: packet, completion: .contentProcessed { _ in })
    }

    private static func samples(from sampleBuffer: CMSampleBuffer) -> [Int16]? {
        let count = CMSampleBufferGetNumSamples(sampleBuffer)
        guard count > 0 else { return nil }
        var listSize = 0
        var retained: CMBlockBuffer?
        guard CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: &listSize,
            bufferListOut: nil,
            bufferListSize: 0,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: 0,
            blockBufferOut: &retained
        ) == noErr else { return nil }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: listSize, alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        let list = raw.bindMemory(to: AudioBufferList.self, capacity: 1)
        guard CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: list,
            bufferListSize: listSize,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: 0,
            blockBufferOut: &retained
        ) == noErr else { return nil }
        let buffers = UnsafeMutableAudioBufferListPointer(list)
        guard !buffers.isEmpty else { return nil }
        let format = CMSampleBufferGetFormatDescription(sampleBuffer).flatMap {
            CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee
        }
        let isFloat = format.map { ($0.mFormatFlags & kAudioFormatFlagIsFloat) != 0 } ?? false
        let bits = max(16, Int(format?.mBitsPerChannel ?? 16))
        let bytesPerSample = bits / 8
        var output = [Int16](repeating: 0, count: count)
        for frame in 0..<count {
            var sum: Float = 0
            var channels = 0
            for buffer in buffers {
                guard let data = buffer.mData else { continue }
                let channelCount = max(1, Int(buffer.mNumberChannels))
                let stride = bytesPerSample * channelCount
                let address = data.advanced(by: frame * stride)
                for channel in 0..<channelCount {
                    let sampleAddress = address.advanced(by: channel * bytesPerSample)
                    if isFloat && bytesPerSample >= 4 {
                        var value: Float = 0
                        memcpy(&value, sampleAddress, 4)
                        sum += max(-1, min(1, value))
                    } else {
                        var value: Int16 = 0
                        memcpy(&value, sampleAddress, 2)
                        sum += Float(value) / Float(Int16.max)
                    }
                    channels += 1
                }
            }
            output[frame] = Int16(max(-1, min(1, sum / Float(max(1, channels)))) * Float(Int16.max))
        }
        return output
    }
}
