import AVFoundation
import CoreImage
import Foundation
import OSLog
import ScreenCaptureKit
@preconcurrency import TeamTalkKit

@available(iOS 27.0, *)
final class TTCustomSystemAudioCapture: NSObject, SCContentSharingPickerObserver, SCStreamOutput, SCStreamDelegate {
    private let logger = Logger(subsystem: "com.derrick.ttcustom", category: "screen-capture")
    private let callbackQueue = DispatchQueue(label: "com.derrick.ttcustom.system-audio", qos: .userInitiated)
    private let stateLock = NSLock()
    private var stream: SCStream?
    private var picker: SCContentSharingPicker?
    private var acceptingCallbacks = false
    private var capturesMicrophone = false
    private var capturesVideo = false
    private var audioCallbackCount = 0
    private var microphoneCallbackCount = 0
    private var lastScreenFrameTime = CMTime.invalid
    private let screenContext = CIContext(options: [.cacheIntermediates: false])

    private func trace(_ message: String) {
        logger.info("\(message, privacy: .public)")
        print("[TTCapture] \(message)")
    }
    private let audioResampler = TTCustomStreamingResampler()
    private let microphoneResampler = TTCustomStreamingResampler()
    var onAudio: (([Int16]) -> Void)?
    var onMicrophoneAudio: (([Int16]) -> Void)?
    var onScreenFrame: ((TeamTalkDesktopFrame) -> Void)?
    var onVideoFailure: ((String) -> Void)?
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

    func presentPicker(capturesMicrophone: Bool = false, capturesVideo: Bool = false) {
        trace("presentPicker: configuring system content-sharing picker")
        self.capturesMicrophone = capturesMicrophone
        self.capturesVideo = capturesVideo
        callbackQueue.async { [weak self] in
            self?.audioResampler.reset()
            self?.microphoneResampler.reset()
            self?.audioCallbackCount = 0
            self?.microphoneCallbackCount = 0
        }
        setAcceptingCallbacks(true)
        let picker = SCContentSharingPicker.shared
        var configuration = SCContentSharingPickerConfiguration()
        configuration.showsMicrophoneControl = capturesMicrophone
        picker.defaultConfiguration = configuration
        picker.add(self)
        picker.isActive = true
        self.picker = picker
        picker.present()
        trace("presentPicker: picker presented; waiting for filter update")
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
        trace("picker didUpdate: microphoneEnabled=\(filter.isMicrophoneEnabled)")
        self.stream?.stopCapture()
        self.stream = nil

        let configuration = SCStreamConfiguration()
        configuration.capturesAudio = true
        configuration.sampleRate = 48_000
        configuration.channelCount = 1
        configuration.excludesCurrentProcessAudio = true

        let capture = SCStream(filter: filter, configuration: configuration, delegate: self)
        trace("creating SCStream: sampleRate=\(configuration.sampleRate), channels=\(configuration.channelCount)")
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
        if capturesVideo {
            do {
                try capture.addStreamOutput(
                    self,
                    type: .screen,
                    sampleHandlerQueue: callbackQueue
                )
            } catch {
                capturesVideo = false
                onVideoFailure?("Screen video unavailable; system audio sharing continues")
            }
        }
        if capturesMicrophone && filter.isMicrophoneEnabled {
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
        }
        self.stream = capture
        capture.startCapture { [weak self] error in
            if let error {
                self?.logger.error("SCStream start failed: \(error.localizedDescription, privacy: .public)")
                self?.trace("SCStream start failed: \(error.localizedDescription)")
                self?.onFailure?("System audio capture failed: \(error.localizedDescription)")
            } else {
                self?.trace("SCStream start completed")
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
            audioCallbackCount += 1
            if audioCallbackCount == 1 || audioCallbackCount % 100 == 0 {
                self.trace("audio callback #\(self.audioCallbackCount)")
            }
            resampler = audioResampler
        case .microphone:
            microphoneCallbackCount += 1
            if microphoneCallbackCount == 1 || microphoneCallbackCount % 100 == 0 {
                self.trace("microphone callback #\(self.microphoneCallbackCount)")
            }
            resampler = microphoneResampler
        case .screen:
            let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            if timestamp.isValid,
               lastScreenFrameTime.isValid,
               CMTimeGetSeconds(timestamp - lastScreenFrameTime) < 0.5 {
                return
            }
            if timestamp.isValid {
                lastScreenFrameTime = timestamp
            }
            guard let frame = desktopFrame(from: sampleBuffer) else {
                trace("screen frame conversion returned no frame")
                return
            }
            onScreenFrame?(frame)
            return
        default:
            return
        }
        guard let samples = samples(from: sampleBuffer, resampler: resampler) else {
            let streamName = type == .microphone ? "microphone" : "audio"
            logger.error("\(streamName, privacy: .public) sample conversion returned no samples")
            trace("\(streamName) sample conversion returned no samples")
            return
        }
        if type == .microphone && microphoneCallbackCount == 1 {
            trace("first microphone block converted: \(samples.count) samples")
        }
        switch type {
        case .audio:
            onAudio?(samples)
        case .microphone:
            onMicrophoneAudio?(samples)
        default:
            break
        }
    }

    private func desktopFrame(from sampleBuffer: CMSampleBuffer) -> TeamTalkDesktopFrame? {
        guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return nil }
        CVPixelBufferLockBaseAddress(imageBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(imageBuffer, .readOnly) }
        guard CVPixelBufferGetBaseAddress(imageBuffer) != nil else { return nil }

        let sourceWidth = CVPixelBufferGetWidth(imageBuffer)
        let sourceHeight = CVPixelBufferGetHeight(imageBuffer)
        let longestSide = max(sourceWidth, sourceHeight)
        let scale = min(1.0, 640.0 / Double(longestSide))
        let width = max(1, Int((Double(sourceWidth) * scale).rounded()))
        let height = max(1, Int((Double(sourceHeight) * scale).rounded()))

        var scaledBuffer: CVPixelBuffer?
        let createStatus = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary,
            &scaledBuffer
        )
        guard createStatus == kCVReturnSuccess, let scaledBuffer else { return nil }
        let scaleTransform = CGAffineTransform(scaleX: scale, y: scale)
        screenContext.render(
            CIImage(cvPixelBuffer: imageBuffer).transformed(by: scaleTransform),
            to: scaledBuffer,
            bounds: CGRect(x: 0, y: 0, width: width, height: height),
            colorSpace: CGColorSpaceCreateDeviceRGB()
        )
        CVPixelBufferLockBaseAddress(scaledBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(scaledBuffer, .readOnly) }
        guard let scaledBaseAddress = CVPixelBufferGetBaseAddress(scaledBuffer) else { return nil }
        let bytesPerLine = CVPixelBufferGetBytesPerRow(scaledBuffer)
        let pixels = Data(bytes: scaledBaseAddress, count: bytesPerLine * height)
        return TeamTalkDesktopFrame(
            width: Int32(width),
            height: Int32(height),
            bytesPerLine: Int32(bytesPerLine),
            pixels: pixels
        )
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

