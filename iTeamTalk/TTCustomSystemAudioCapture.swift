import AVFoundation
import Foundation
import ScreenCaptureKit

@available(iOS 27.0, *)
final class TTCustomSystemAudioCapture: NSObject, SCContentSharingPickerObserver, SCStreamOutput, SCStreamDelegate {
    private let callbackQueue = DispatchQueue(label: "com.derrick.ttcustom.system-audio", qos: .userInitiated)
    private let stateLock = NSLock()
    private var stream: SCStream?
    private var picker: SCContentSharingPicker?
    private var acceptingCallbacks = false
    private let audioResampler = TTCustomStreamingResampler()
    private let microphoneResampler = TTCustomStreamingResampler()
    var onAudio: (([Int16]) -> Void)?
    var onMicrophoneAudio: (([Int16]) -> Void)?
    var onFailure: ((String) -> Void)?

    private var isAcceptingCallbacks: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return acceptingCallbacks
    }

    private func setAcceptingCallbacks(_ value: Bool) {
        stateLock.lock()
        acceptingCallbacks = value
        stateLock.unlock()
    }

    func presentPicker() {
        callbackQueue.async { [weak self] in
            self?.audioResampler.reset()
            self?.microphoneResampler.reset()
        }
        setAcceptingCallbacks(true)
        let picker = SCContentSharingPicker.shared
        var configuration = SCContentSharingPickerConfiguration()
        configuration.showsMicrophoneControl = true
        picker.defaultConfiguration = configuration
        picker.add(self)
        picker.isActive = true
        self.picker = picker
        picker.present()
    }

    func stop(completion: @escaping () -> Void = {}) {
        setAcceptingCallbacks(false)
        picker?.remove(self)
        picker?.isActive = false
        picker = nil
        guard let stream else {
            completion()
            return
        }
        self.stream = nil
        stream.stopCapture { _ in
            DispatchQueue.main.async {
                completion()
            }
        }
    }

    func contentSharingPicker(
        _ picker: SCContentSharingPicker,
        didUpdateWith filter: SCContentFilter,
        for stream: SCStream?
    ) {
        guard isAcceptingCallbacks else { return }
        self.stream?.stopCapture()
        self.stream = nil

        guard filter.isMicrophoneEnabled else {
            onFailure?("Microphone must be enabled in the screen-sharing controls")
            return
        }

        let configuration = SCStreamConfiguration()
        configuration.capturesAudio = true
        configuration.sampleRate = 48_000
        configuration.channelCount = 1
        configuration.excludesCurrentProcessAudio = true

        let capture = SCStream(filter: filter, configuration: configuration, delegate: self)
        do {
            try capture.addStreamOutput(
                self,
                type: .audio,
                sampleHandlerQueue: callbackQueue
            )
        } catch {
            onFailure?("Could not attach system audio capture: \(error.localizedDescription)")
            return
        }
        do {
            try capture.addStreamOutput(
                self,
                type: .microphone,
                sampleHandlerQueue: callbackQueue
            )
        } catch {
            onFailure?("Could not attach microphone capture: \(error.localizedDescription)")
            return
        }
        self.stream = capture
        capture.startCapture { [weak self] error in
            if let error {
                self?.onFailure?("System audio capture failed: \(error.localizedDescription)")
            }
        }
    }

    func contentSharingPicker(
        _ picker: SCContentSharingPicker,
        didCancelFor stream: SCStream?
    ) {
        guard isAcceptingCallbacks else { return }
        onFailure?("System audio sharing was cancelled")
    }

    func contentSharingPickerStartDidFailWithError(_ error: Error) {
        guard isAcceptingCallbacks else { return }
        onFailure?("System audio picker failed: \(error.localizedDescription)")
    }

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        guard isAcceptingCallbacks else { return }
        let resampler: TTCustomStreamingResampler
        switch type {
        case .audio:
            resampler = audioResampler
        case .microphone:
            resampler = microphoneResampler
        default:
            return
        }
        guard let samples = samples(from: sampleBuffer, resampler: resampler) else { return }
        switch type {
        case .audio:
            onAudio?(samples)
        case .microphone:
            onMicrophoneAudio?(samples)
        default:
            break
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        guard isAcceptingCallbacks else { return }
        onFailure?("System audio sharing stopped: \(error.localizedDescription)")
    }

    private func samples(from sampleBuffer: CMSampleBuffer, resampler: TTCustomStreamingResampler) -> [Int16]? {
        let sampleCount = CMSampleBufferGetNumSamples(sampleBuffer)
        guard sampleCount > 0 else { return nil }

        var retainedBlockBuffer: CMBlockBuffer?
        var bufferListSize = 0
        let sizeStatus = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: &bufferListSize,
            bufferListOut: nil,
            bufferListSize: 0,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: 0,
            blockBufferOut: &retainedBlockBuffer
        )
        guard sizeStatus == noErr || bufferListSize > 0 else { return nil }

        let rawBufferList = UnsafeMutableRawPointer.allocate(
            byteCount: bufferListSize,
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { rawBufferList.deallocate() }
        let audioBufferList = rawBufferList.bindMemory(to: AudioBufferList.self, capacity: 1)
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: audioBufferList,
            bufferListSize: bufferListSize,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: 0,
            blockBufferOut: &retainedBlockBuffer
        )
        guard status == noErr else { return nil }

        let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer)
        let streamDescription = formatDescription.flatMap {
            CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee
        }
        let isFloat = streamDescription.map {
            ($0.mFormatFlags & kAudioFormatFlagIsFloat) != 0
        } ?? false
        let bitsPerSample = Int(streamDescription?.mBitsPerChannel ?? 16)
        let bytesPerSample = max(1, bitsPerSample / 8)
        let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
        guard !buffers.isEmpty else { return nil }
        let availableFrames = min(sampleCount, buffers.reduce(sampleCount) { current, buffer in
            min(current, Int(buffer.mDataByteSize) / max(1, bytesPerSample * Int(buffer.mNumberChannels)))
        })
        guard availableFrames > 0 else { return nil }

        func normalizedSample(at byteAddress: UnsafeMutableRawPointer) -> Float {
            if isFloat && bytesPerSample >= 4 {
                var sample: Float32 = 0
                memcpy(&sample, byteAddress, MemoryLayout<Float32>.size)
                return max(-1, min(1, sample))
            }
            if bytesPerSample >= 2 {
                var sample: Int16 = 0
                memcpy(&sample, byteAddress, MemoryLayout<Int16>.size)
                return Float(sample) / Float(Int16.max)
            }
            return 0
        }

        var output = [Int16](repeating: 0, count: availableFrames)
        for frame in 0..<availableFrames {
            var sum: Float = 0
            var channelCount = 0
            for buffer in buffers {
                guard let data = buffer.mData else { continue }
                let channels = max(1, Int(buffer.mNumberChannels))
                let frameStride = bytesPerSample * channels
                let frameAddress = data.advanced(by: frame * frameStride)
                for channel in 0..<channels {
                    sum += normalizedSample(at: frameAddress.advanced(by: channel * bytesPerSample))
                    channelCount += 1
                }
            }
            let mono = channelCount > 0 ? sum / Float(channelCount) : 0
            output[frame] = Int16(max(-1, min(1, mono)) * Float(Int16.max))
        }
        return resampler.process(output, sourceRate: streamDescription?.mSampleRate ?? 48_000)
    }
}

