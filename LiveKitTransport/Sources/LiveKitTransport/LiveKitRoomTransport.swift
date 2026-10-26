import Foundation
import AVFoundation
import OSLog
import LiveKit

/// Small, UI-agnostic LiveKit transport used by TT Custom during the backend
/// migration. It intentionally owns only room/media lifecycle; authentication
/// stays in the app because the app already owns the saved server credentials.
@MainActor
public final class LiveKitRoomTransport: NSObject {
    private final class RoomEventDelegate: NSObject, @unchecked Sendable, RoomDelegate {
        var onChatMessage: ((String, String) -> Void)?
        var onAnnouncement: ((String) -> Void)?

        func room(_ room: Room,
                  participant: RemoteParticipant?,
                  didReceiveData data: Data,
                  forTopic topic: String,
                  encryptionType: EncryptionType) {
            if topic == "announcements",
               let payload = try? JSONDecoder().decode(AnnouncementPayload.self, from: data),
               payload.type == 1,
               !payload.announcement.isEmpty {
                onAnnouncement?(payload.announcement)
                return
            }
            guard topic == "chat",
                  let payload = try? JSONDecoder().decode(ChatPayload.self, from: data),
                  !payload.text.isEmpty else { return }
            let sender = participant?.name?.isEmpty == false
                ? participant!.name!
                : (participant.map { String(describing: $0.identity) } ?? "Participant")
            onChatMessage?(sender, payload.text)
        }

        private struct ChatPayload: Decodable {
            let text: String
        }

        private struct AnnouncementPayload: Decodable {
            let type: Int
            let announcement: String
        }
    }

    private let logger = Logger(subsystem: "com.derrick.dsaudio", category: "livekit-transport")
    private final class AudioInjectionState: @unchecked Sendable {
        private let lock = NSLock()
        private var _gain: Float = 1

        var gain: Float {
            lock.lock()
            defer { lock.unlock() }
            return _gain
        }

        func setGain(_ value: Float) {
            lock.lock()
            _gain = value
            lock.unlock()
        }
    }

    /// Prevents ScreenCaptureKit's real-time callback from entering the
    /// LiveKit mixer while its audio graph is being reconfigured. AVAudio
    /// player-node failures are Objective-C exceptions, so they cannot be
    /// recovered from with Swift do/catch after the fact.
    private final class AudioInjectionGate: @unchecked Sendable {
        private let condition = NSCondition()
        private var paused = false
        private var activeCalls = 0

        func withPermit(_ body: () -> Void) {
            condition.lock()
            guard !paused else {
                condition.unlock()
                return
            }
            activeCalls += 1
            condition.unlock()
            defer {
                condition.lock()
                activeCalls -= 1
                if activeCalls == 0 { condition.broadcast() }
                condition.unlock()
            }
            body()
        }

        func pauseAndWait() {
            condition.lock()
            paused = true
            while activeCalls > 0 { condition.wait() }
            condition.unlock()
        }

        func resume() {
            condition.lock()
            paused = false
            condition.broadcast()
            condition.unlock()
        }
    }

    public struct RemoteParticipantSnapshot: Identifiable, Sendable {
        public let id: String
        public let name: String
        public let isSpeaking: Bool
        public let volume: Double

        public init(id: String, name: String, isSpeaking: Bool, volume: Double) {
            self.id = id
            self.name = name
            self.isSpeaking = isSpeaking
            self.volume = volume
        }
    }

    public struct Diagnostics: Sendable {
        public struct AudioStream: Identifiable, Sendable {
            public let id: String
            public let codec: String?
            public let clockRate: UInt?
            public let channels: UInt?
            public let packets: UInt64?
            public let packetsLost: Int64?
            public let bytes: UInt64?
            public let measuredBitrate: Double?
            public let targetBitrate: Double?
            public let jitterMilliseconds: Double?
            public let jitterBufferDelayMilliseconds: Double?
            public let concealedSamples: UInt64?
            public let silentConcealedSamples: UInt64?
            public let concealmentEvents: UInt64?
            public let audioLevel: Double?
            public let retransmittedPackets: UInt64?
            public let retransmittedBytes: UInt64?

            public init(id: String,
                        codec: String?,
                        clockRate: UInt?,
                        channels: UInt?,
                        packets: UInt64?,
                        packetsLost: Int64?,
                        bytes: UInt64?,
                        measuredBitrate: Double?,
                        targetBitrate: Double?,
                        jitterMilliseconds: Double?,
                        jitterBufferDelayMilliseconds: Double?,
                        concealedSamples: UInt64?,
                        silentConcealedSamples: UInt64?,
                        concealmentEvents: UInt64?,
                        audioLevel: Double?,
                        retransmittedPackets: UInt64?,
                        retransmittedBytes: UInt64?) {
                self.id = id
                self.codec = codec
                self.clockRate = clockRate
                self.channels = channels
                self.packets = packets
                self.packetsLost = packetsLost
                self.bytes = bytes
                self.measuredBitrate = measuredBitrate
                self.targetBitrate = targetBitrate
                self.jitterMilliseconds = jitterMilliseconds
                self.jitterBufferDelayMilliseconds = jitterBufferDelayMilliseconds
                self.concealedSamples = concealedSamples
                self.silentConcealedSamples = silentConcealedSamples
                self.concealmentEvents = concealmentEvents
                self.audioLevel = audioLevel
                self.retransmittedPackets = retransmittedPackets
                self.retransmittedBytes = retransmittedBytes
            }
        }

        public struct Connection: Sendable {
            public let roundTripTimeMilliseconds: Double?
            public let availableOutgoingBitrate: Double?
            public let availableIncomingBitrate: Double?
            public let packetsSent: UInt64?
            public let packetsReceived: UInt64?
            public let bytesSent: UInt64?
            public let bytesReceived: UInt64?

            public init(roundTripTimeMilliseconds: Double?,
                        availableOutgoingBitrate: Double?,
                        availableIncomingBitrate: Double?,
                        packetsSent: UInt64?,
                        packetsReceived: UInt64?,
                        bytesSent: UInt64?,
                        bytesReceived: UInt64?) {
                self.roundTripTimeMilliseconds = roundTripTimeMilliseconds
                self.availableOutgoingBitrate = availableOutgoingBitrate
                self.availableIncomingBitrate = availableIncomingBitrate
                self.packetsSent = packetsSent
                self.packetsReceived = packetsReceived
                self.bytesSent = bytesSent
                self.bytesReceived = bytesReceived
            }
        }

        public let connectionState: String
        public let microphonePublished: Bool
        public let microphoneMuted: Bool
        public let audioEngineRunning: Bool
        public let microphoneMixerVolume: Double
        public let outputMixerVolume: Double
        public let remoteParticipantCount: Int
        public let remoteAudioTrackCount: Int
        public let subscribedRemoteAudioTrackCount: Int
        public let capturedFrames: Int64
        public let capturedBlocks: Int64
        public let nonSilentCapturedBlocks: Int64
        public let lastCapturePeak: Double
        public let lastCaptureRMS: Double
        public let connectionStatistics: Connection?
        public let outboundAudio: AudioStream?
        public let inboundAudio: [AudioStream]

        public init(connectionState: String,
                    microphonePublished: Bool,
                    microphoneMuted: Bool,
                    audioEngineRunning: Bool,
                    microphoneMixerVolume: Double,
                    outputMixerVolume: Double,
                    remoteParticipantCount: Int,
                    remoteAudioTrackCount: Int,
                    subscribedRemoteAudioTrackCount: Int,
                    capturedFrames: Int64,
                    capturedBlocks: Int64,
                    nonSilentCapturedBlocks: Int64,
                    lastCapturePeak: Double,
                    lastCaptureRMS: Double,
                    connectionStatistics: Connection? = nil,
                    outboundAudio: AudioStream? = nil,
                    inboundAudio: [AudioStream] = []) {
            self.connectionState = connectionState
            self.microphonePublished = microphonePublished
            self.microphoneMuted = microphoneMuted
            self.audioEngineRunning = audioEngineRunning
            self.microphoneMixerVolume = microphoneMixerVolume
            self.outputMixerVolume = outputMixerVolume
            self.remoteParticipantCount = remoteParticipantCount
            self.remoteAudioTrackCount = remoteAudioTrackCount
            self.subscribedRemoteAudioTrackCount = subscribedRemoteAudioTrackCount
            self.capturedFrames = capturedFrames
            self.capturedBlocks = capturedBlocks
            self.nonSilentCapturedBlocks = nonSilentCapturedBlocks
            self.lastCapturePeak = lastCapturePeak
            self.lastCaptureRMS = lastCaptureRMS
            self.connectionStatistics = connectionStatistics
            self.outboundAudio = outboundAudio
            self.inboundAudio = inboundAudio
        }
    }

    public var onChatMessage: ((String, String) -> Void)?
    public var onAnnouncement: ((String) -> Void)?
    public let room: Room
    private let roomEventDelegate = RoomEventDelegate()
    private var localTracks: [String: LocalAudioTrack] = [:]
    private let audioInjectionState = AudioInjectionState()
    private let audioInjectionGate = AudioInjectionGate()
    private var lastProcessing = AudioCaptureOptions()
    private var ioBufferMilliseconds = 20.0
    private var defaultsToSpeaker = true
    private var microphoneVolume = 1.0
    private var microphoneInputEnabled = true
    private var callKitOwnsAudioRoute = false
    private var systemAudioMixingEnabled = false
    private var audioMaxBitrate: Int? = 48_000
    private var audioDTX = true
    private var audioRED = true
    private let customProcessor = TTCustomLiveKitProcessor()

    private func captureOptions(appleEchoCancellation: Bool,
                                appleNoiseSuppression: Bool,
                                appleAutomaticGainControl: Bool,
                                webRTCEchoCancellation: Bool,
                                webRTCNoiseSuppression: Bool,
                                webRTCAutomaticGainControl: Bool,
                                highpassFilter: Bool,
                                typingNoiseDetection: Bool) -> AudioCaptureOptions {
        let echoMode: EchoCancellationMode = appleEchoCancellation ? .platform : .software
        let noiseMode: NoiseSuppressionMode = appleNoiseSuppression ? .platform : .software
        let gainMode: AutoGainControlMode = appleAutomaticGainControl ? .platform : .software
        return AudioCaptureOptions(
            echoCancellation: appleEchoCancellation || webRTCEchoCancellation,
            autoGainControl: appleAutomaticGainControl || webRTCAutomaticGainControl,
            noiseSuppression: appleNoiseSuppression || webRTCNoiseSuppression,
            highpassFilter: highpassFilter,
            typingNoiseDetection: typingNoiseDetection,
            echoCancellationMode: echoMode,
            autoGainControlMode: gainMode,
            noiseSuppressionMode: noiseMode
        )
    }

    private func runtimeProcessingOptions(from capture: AudioCaptureOptions) -> AudioProcessingOptions {
        AudioProcessingOptions(
            echoCancellation: capture.echoCancellation,
            autoGainControl: capture.autoGainControl,
            noiseSuppression: capture.noiseSuppression,
            highpassFilter: capture.highpassFilter,
            echoCancellationMode: capture.echoCancellationMode,
            autoGainControlMode: capture.autoGainControlMode,
            noiseSuppressionMode: capture.noiseSuppressionMode,
            highpassFilterMode: capture.highpassFilterMode
        )
    }

    public override init() {
        room = Room(roomOptions: RoomOptions(reportRemoteTrackStatistics: true))
        super.init()
        room.delegates.add(delegate: roomEventDelegate)
        roomEventDelegate.onChatMessage = { [weak self] sender, text in
            Task { @MainActor in self?.onChatMessage?(sender, text) }
        }
        roomEventDelegate.onAnnouncement = { [weak self] announcement in
            Task { @MainActor in self?.onAnnouncement?(announcement) }
        }
        AudioManager.shared.capturePostProcessingDelegate = customProcessor
    }

    public var isConnected: Bool {
        room.connectionState == .connected
    }

    public func connect(url: String, token: String) async throws {
        logger.info("room connect requested url=\(url, privacy: .private(mask: .hash))")
        let options = ConnectOptions(
            autoSubscribe: true,
            enableMicrophone: false
        )
        try await room.connect(url: url, token: token, connectOptions: options)
        logger.info("room connected state=\(String(describing: self.room.connectionState), privacy: .public)")
    }

    /// Mirrors the old client's proven startup order: configure and activate
    /// the duplex AVAudioSession before LiveKit opens its recording device.
    /// LiveKit's audio engine remains responsible for capture/playout; this
    /// only establishes the session and route it must use.
    private func prepareAudioSession(for processing: AudioCaptureOptions) throws {
        #if os(iOS)
        // Let LiveKit configure its audio device before the first capture
        // track is created. Taking ownership here caused the engine to start
        // briefly and then publish only DTX/silence on some iOS routes.
        AudioManager.shared.audioSession.isAutomaticConfigurationEnabled = true
        guard AudioManager.shared.isEngineRunning else { return }

        let usesVoiceProcessing = processing.echoCancellationMode == .platform ||
            processing.noiseSuppressionMode == .platform ||
            processing.autoGainControlMode == .platform
        var options: AVAudioSession.CategoryOptions = [
            .allowBluetoothHFP,
            .allowAirPlay,
            .mixWithOthers,
        ]
        if usesVoiceProcessing == false {
            options.insert(.allowBluetoothA2DP)
        }
        if defaultsToSpeaker && !callKitOwnsAudioRoute {
            options.insert(.defaultToSpeaker)
        }
        try AVAudioSession.sharedInstance().setCategory(
            .playAndRecord,
            mode: usesVoiceProcessing ? .voiceChat : .default,
            options: options
        )
        try AVAudioSession.sharedInstance().setPreferredIOBufferDuration(ioBufferMilliseconds / 1000)
        try AVAudioSession.sharedInstance().setActive(true)
        let session = AVAudioSession.sharedInstance()
        if callKitOwnsAudioRoute {
            // CallKit owns the native output route while its call UI is active.
        } else if defaultsToSpeaker, session.currentRoute.outputs.first?.portType == .builtInReceiver {
            try session.overrideOutputAudioPort(.speaker)
        } else if !defaultsToSpeaker {
            try session.overrideOutputAudioPort(.none)
        }
        #endif
    }

    public var isAudioEngineRunning: Bool {
        AudioManager.shared.isEngineRunning
    }

    /// Reasserts the manually-owned session after an interruption or route
    /// change. LiveKit keeps the room alive, but iOS can stop the underlying
    /// audio engine independently.
    public func reconcileAudioSession() throws {
        logger.debug("reconciling audio session engineRunning=\(AudioManager.shared.isEngineRunning, privacy: .public)")
        audioInjectionGate.pauseAndWait()
        defer { audioInjectionGate.resume() }
        try prepareAudioSession(for: lastProcessing)
        if localTracks[Track.microphoneName] != nil && !AudioManager.shared.isEngineRunning {
            try AudioManager.shared.startLocalRecording(audioProcessingOptions: runtimeProcessingOptions(from: lastProcessing))
        }
        applyMixerState()
        logger.info("audio session reconciled engineRunning=\(AudioManager.shared.isEngineRunning, privacy: .public) micGain=\(self.microphoneMixerVolumeForLog, privacy: .public) outputGain=\(self.outputMixerVolumeForLog, privacy: .public)")
    }

    public func setIOBufferMilliseconds(_ milliseconds: Double) throws {
        ioBufferMilliseconds = min(40, max(5, milliseconds))
        try AVAudioSession.sharedInstance().setPreferredIOBufferDuration(ioBufferMilliseconds / 1000)
    }

    public func setDefaultOutputSpeaker(_ enabled: Bool) {
        defaultsToSpeaker = enabled
    }

    /// CallKit owns the native route picker while a system call is active.
    public func setCallKitAudioRouteOwnership(_ ownsRoute: Bool) {
        callKitOwnsAudioRoute = ownsRoute
        logger.info("CallKit audio route ownership \(ownsRoute ? "enabled" : "disabled", privacy: .public)")
    }

    public func publishMicrophone(enabled: Bool, processing: AudioCaptureOptions = AudioCaptureOptions()) async throws {
        logger.info("microphone publish requested enabled=\(enabled, privacy: .public) existing=\(self.localTracks[Track.microphoneName] != nil, privacy: .public)")
        lastProcessing = processing
        try prepareAudioSession(for: processing)

        if let track = localTracks[Track.microphoneName] {
            if systemAudioMixingEnabled {
                // Keep the published track alive while system audio is mixed
                // into the same LiveKit publication. The mixer controls the
                // microphone component in this mode.
                try await track.unmute()
                setMicrophoneInputEnabled(enabled)
            } else {
                // Preserve LiveKit's known-good native microphone path when
                // there is no injected system audio. This avoids routing a
                // normal microphone through an uninitialized mixer graph.
                enabled ? try await track.unmute() : try await track.mute()
                microphoneInputEnabled = enabled
            }
            logger.info("microphone existing track reasserted enabled=\(enabled, privacy: .public) engineRunning=\(AudioManager.shared.isEngineRunning, privacy: .public)")
            return
        }

        guard enabled else { return }
        let track = await LocalAudioTrack.createTrack(
            name: Track.microphoneName,
            options: processing,
            reportStatistics: true
        )
        _ = try await room.localParticipant.publish(
            audioTrack: track,
            options: AudioPublishOptions(
                name: Track.microphoneName,
                encoding: audioMaxBitrate.map { AudioEncoding(maxBitrate: $0) },
                dtx: audioDTX,
                red: audioRED,
                streamName: "Microphone"
            )
        )
        localTracks[Track.microphoneName] = track
        microphoneInputEnabled = enabled
        if systemAudioMixingEnabled {
            setMicrophoneInputEnabled(enabled)
        }
        logger.info("microphone track published enabled=\(enabled, privacy: .public) engineRunning=\(AudioManager.shared.isEngineRunning, privacy: .public)")
        guard AudioManager.shared.isEngineRunning else {
            throw LiveKitTransportError.audioEngineNotRunning
        }
    }

    public func publishMicrophone(enabled: Bool,
                                  appleEchoCancellation: Bool,
                                  appleNoiseSuppression: Bool,
                                  appleAutomaticGainControl: Bool,
                                  webRTCEchoCancellation: Bool,
                                  webRTCNoiseSuppression: Bool,
                                  webRTCAutomaticGainControl: Bool,
                                  highpassFilter: Bool,
                                  typingNoiseDetection: Bool) async throws {
        try await publishMicrophone(
            enabled: enabled,
            processing: captureOptions(
                appleEchoCancellation: appleEchoCancellation,
                appleNoiseSuppression: appleNoiseSuppression,
                appleAutomaticGainControl: appleAutomaticGainControl,
                webRTCEchoCancellation: webRTCEchoCancellation,
                webRTCNoiseSuppression: webRTCNoiseSuppression,
                webRTCAutomaticGainControl: webRTCAutomaticGainControl,
                highpassFilter: highpassFilter,
                typingNoiseDetection: typingNoiseDetection
            )
        )
    }

    public func setTrackMuted(name: String, muted: Bool) async throws {
        guard let track = localTracks[name] else { return }
        muted ? try await track.mute() : try await track.unmute()
    }

    public func setMicrophoneProcessing(appleEchoCancellation: Bool,
                                        appleNoiseSuppression: Bool,
                                        appleAutomaticGainControl: Bool,
                                        webRTCEchoCancellation: Bool,
                                        webRTCNoiseSuppression: Bool,
                                        webRTCAutomaticGainControl: Bool,
                                        highpassFilter: Bool,
                                        typingNoiseDetection: Bool) throws {
        guard let track = localTracks[Track.microphoneName] else { return }
        let processing = captureOptions(
            appleEchoCancellation: appleEchoCancellation,
            appleNoiseSuppression: appleNoiseSuppression,
            appleAutomaticGainControl: appleAutomaticGainControl,
            webRTCEchoCancellation: webRTCEchoCancellation,
            webRTCNoiseSuppression: webRTCNoiseSuppression,
            webRTCAutomaticGainControl: webRTCAutomaticGainControl,
            highpassFilter: highpassFilter,
            typingNoiseDetection: typingNoiseDetection
        )
        lastProcessing = processing
        audioInjectionGate.pauseAndWait()
        defer { audioInjectionGate.resume() }
        try prepareAudioSession(for: processing)
        _ = try track.setAudioProcessingOptions(runtimeProcessingOptions(from: processing))
    }

    public func setLimiterEnabled(_ enabled: Bool) {
        customProcessor.setLimiterEnabled(enabled)
    }

    /// Sets the gain applied to incoming system-audio blocks. This is deliberately
    /// thread-safe because the capture callback must not hop to the main actor.
    public nonisolated func setSystemAudioGain(_ gain: Double) {
        audioInjectionState.setGain(Float(max(0, gain)))
    }

    /// Updates the SDK mixer controls for microphone and remote playback.
    /// The SDK clamps these node volumes to 0...1; system audio can still use
    /// greater-than-unity gain before injection when the UI allows it.
    public func setAudioLevels(microphone: Double, output: Double) {
        microphoneVolume = min(1, max(0, microphone))
        applyMixerState(outputVolume: output)
        logger.debug("mixer levels applied micEnabled=\(self.microphoneInputEnabled, privacy: .public) micGain=\(self.microphoneMixerVolumeForLog, privacy: .public) outputGain=\(self.outputMixerVolumeForLog, privacy: .public)")
    }

    public func setMicrophoneInputEnabled(_ enabled: Bool) {
        microphoneInputEnabled = enabled
        guard systemAudioMixingEnabled else { return }
        applyMixerState(outputVolume: Double(AudioManager.shared.mixer.outputVolume))
        logger.info("microphone mixer input \(enabled ? "enabled" : "disabled", privacy: .public) gain=\(self.microphoneMixerVolumeForLog, privacy: .public)")
    }

    public func setSystemAudioMixingEnabled(_ enabled: Bool) {
        systemAudioMixingEnabled = enabled
        if enabled {
            applyMixerState()
        }
        logger.info("system audio mixing \(enabled ? "enabled" : "disabled", privacy: .public) micEnabled=\(self.microphoneInputEnabled, privacy: .public)")
    }

    private func applyMixerState(outputVolume: Double? = nil) {
        let mixer = AudioManager.shared.mixer
        if systemAudioMixingEnabled {
            mixer.micVolume = Float(microphoneInputEnabled ? microphoneVolume : 0)
        }
        if let outputVolume {
            mixer.outputVolume = Float(min(1, max(0, outputVolume)))
        }
    }

    public func diagnostics() -> Diagnostics {
        let localPublication = room.localParticipant.trackPublications.values
            .compactMap { $0 as? LocalTrackPublication }
            .first { $0.track?.name == Track.microphoneName || $0.name == Track.microphoneName }
        let remotePublications = room.remoteParticipants.values.flatMap { $0.audioTracks }
        let subscribedCount = remotePublications.filter { $0.track is RemoteAudioTrack }.count
        let captureMetrics = customProcessor.metrics()
        let localStats = localTracks[Track.microphoneName]?.statistics
        let remoteTracks = remotePublications.compactMap { $0.track as? RemoteAudioTrack }
        let connectionStats = localStats.flatMap(makeConnectionStatistics)
        return Diagnostics(
            connectionState: String(describing: room.connectionState),
            microphonePublished: localPublication != nil,
            microphoneMuted: localPublication?.isMuted ?? true,
            audioEngineRunning: AudioManager.shared.isEngineRunning,
            microphoneMixerVolume: Double(AudioManager.shared.mixer.micVolume),
            outputMixerVolume: Double(AudioManager.shared.mixer.outputVolume),
            remoteParticipantCount: room.remoteParticipants.count,
            remoteAudioTrackCount: remotePublications.count,
            subscribedRemoteAudioTrackCount: subscribedCount,
            capturedFrames: captureMetrics.processedFrames,
            capturedBlocks: captureMetrics.processedBlocks,
            nonSilentCapturedBlocks: captureMetrics.nonSilentBlocks,
            lastCapturePeak: captureMetrics.lastPeak,
            lastCaptureRMS: captureMetrics.lastRMS,
            connectionStatistics: connectionStats,
            outboundAudio: localStats.flatMap { makeOutboundAudioStream(from: $0) },
            inboundAudio: remoteTracks.compactMap { $0.statistics }.flatMap(makeInboundAudioStreams)
        )
    }

    private func bitrate(bytes: UInt64?, previousBytes: UInt64?, timestamp: Double, previousTimestamp: Double?) -> Double? {
        guard let bytes, let previousBytes, let previousTimestamp,
              timestamp > previousTimestamp, bytes >= previousBytes else { return nil }
        return Double(bytes - previousBytes) * 8 / (timestamp - previousTimestamp)
    }

    private func makeConnectionStatistics(_ stats: TrackStatistics) -> Diagnostics.Connection? {
        let pair = stats.iceCandidatePair.first(where: { $0.state == .succeeded && ($0.nominated ?? false) })
            ?? stats.iceCandidatePair.first(where: { $0.state == .succeeded })
        let transport = stats.transportStats
        guard pair != nil || transport != nil else { return nil }
        return Diagnostics.Connection(
            roundTripTimeMilliseconds: pair?.currentRoundTripTime.map { $0 * 1000 },
            availableOutgoingBitrate: pair?.availableOutgoingBitrate,
            availableIncomingBitrate: pair?.availableIncomingBitrate,
            packetsSent: transport?.packetsSent ?? pair?.packetsSent,
            packetsReceived: transport?.packetsReceived ?? pair?.packetsReceived,
            bytesSent: transport?.bytesSent ?? pair?.bytesSent,
            bytesReceived: transport?.bytesReceived ?? pair?.bytesReceived
        )
    }

    private func makeOutboundAudioStream(from stats: TrackStatistics) -> Diagnostics.AudioStream? {
        guard let stream = stats.outboundRtpStream.first(where: { $0.kind == "audio" }) else { return nil }
        let codec = stats.codec.first(where: { $0.id == stream.codecId })
        return Diagnostics.AudioStream(
            id: stream.id,
            codec: codec?.mimeType,
            clockRate: codec?.clockRate,
            channels: codec?.channels,
            packets: stream.packetsSent,
            packetsLost: nil,
            bytes: stream.bytesSent,
            measuredBitrate: bitrate(bytes: stream.bytesSent, previousBytes: stream.previous?.bytesSent, timestamp: stream.timestamp, previousTimestamp: stream.previous?.timestamp),
            targetBitrate: stream.targetBitrate,
            jitterMilliseconds: nil,
            jitterBufferDelayMilliseconds: nil,
            concealedSamples: nil,
            silentConcealedSamples: nil,
            concealmentEvents: nil,
            audioLevel: nil,
            retransmittedPackets: stream.retransmittedPacketsSent,
            retransmittedBytes: stream.retransmittedBytesSent
        )
    }

    private func makeInboundAudioStreams(from stats: TrackStatistics) -> [Diagnostics.AudioStream] {
        stats.inboundRtpStream.filter { $0.kind == "audio" }.map { stream in
            let codec = stats.codec.first(where: { $0.id == stream.codecId })
            return Diagnostics.AudioStream(
                id: stream.id,
                codec: codec?.mimeType,
                clockRate: codec?.clockRate,
                channels: codec?.channels,
                packets: stream.packetsReceived,
                packetsLost: stream.packetsLost,
                bytes: stream.bytesReceived,
                measuredBitrate: bitrate(bytes: stream.bytesReceived, previousBytes: stream.previous?.bytesReceived, timestamp: stream.timestamp, previousTimestamp: stream.previous?.timestamp),
                targetBitrate: nil,
                jitterMilliseconds: stream.jitter.map { $0 * 1000 },
                jitterBufferDelayMilliseconds: stream.jitterBufferDelay.map { $0 * 1000 },
                concealedSamples: stream.concealedSamples,
                silentConcealedSamples: stream.silentConcealedSamples,
                concealmentEvents: stream.concealmentEvents,
                audioLevel: stream.audioLevel,
                retransmittedPackets: stream.retransmittedPacketsReceived,
                retransmittedBytes: stream.retransmittedBytesReceived
            )
        }
    }

    public func sendChat(_ text: String) async throws {
        let payload = try JSONEncoder().encode(["text": text])
        try await room.localParticipant.publish(
            data: payload,
            options: DataPublishOptions(topic: "chat", reliable: true)
        )
    }

    public func sendAnnouncement(_ announcement: String) async throws {
        struct Payload: Encodable {
            let type: Int
            let announcement: String
        }
        let payload = try JSONEncoder().encode(Payload(type: 1, announcement: announcement))
        try await room.localParticipant.publish(
            data: payload,
            options: DataPublishOptions(topic: "announcements", reliable: true)
        )
    }

    private var microphoneMixerVolumeForLog: Double { Double(AudioManager.shared.mixer.micVolume) }
    private var outputMixerVolumeForLog: Double { Double(AudioManager.shared.mixer.outputVolume) }

    /// Applies all publication-time audio options through one path. LiveKit
    /// requires a publication replacement for these settings, so keeping them
    /// together prevents bitrate, DTX, and RED changes from using competing
    /// unpublish/republish implementations.
    public func setAudioPublicationConfiguration(maxBitrate: Int?, dtx: Bool, red: Bool) async throws {
        let clamped = maxBitrate.map { min(128_000, max(12_000, $0)) }
        guard clamped != audioMaxBitrate || dtx != audioDTX || red != audioRED else { return }
        audioMaxBitrate = clamped
        audioDTX = dtx
        audioRED = red
        guard localTracks[Track.microphoneName] != nil else { return }
        try await republishMicrophone()
    }

    public func setAudioMaxBitrate(_ bitrate: Int?) async throws {
        try await setAudioPublicationConfiguration(maxBitrate: bitrate, dtx: audioDTX, red: audioRED)
    }

    public func setAudioTransportOptions(dtx: Bool, red: Bool) async throws {
        try await setAudioPublicationConfiguration(maxBitrate: audioMaxBitrate, dtx: dtx, red: red)
    }

    private func republishMicrophone() async throws {
        guard let track = localTracks[Track.microphoneName],
              let publication = room.localParticipant.trackPublications.values
                .compactMap({ $0 as? LocalTrackPublication })
                .first(where: { $0.track === track }) else { return }
        audioInjectionGate.pauseAndWait()
        defer { audioInjectionGate.resume() }
        try await room.localParticipant.unpublish(publication: publication)
        localTracks.removeValue(forKey: Track.microphoneName)
        let replacement = await LocalAudioTrack.createTrack(name: Track.microphoneName, options: lastProcessing, reportStatistics: true)
        _ = try await room.localParticipant.publish(
            audioTrack: replacement,
            options: AudioPublishOptions(name: Track.microphoneName,
                                         encoding: audioMaxBitrate.map { AudioEncoding(maxBitrate: $0) },
                                         dtx: audioDTX,
                                         red: audioRED,
                                         streamName: "Microphone")
        )
        localTracks[Track.microphoneName] = replacement
        applyMixerState()
    }

    /// Injects app audio into LiveKit's active microphone path. This method is
    /// nonisolated so ScreenCaptureKit can call it directly from its real-time
    /// callback queue; it does no UI or room-state work.
    public nonisolated func captureSystemAudio(samples: [Int16]) {
        audioInjectionGate.withPermit {
            guard !samples.isEmpty else { return }
            guard let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1),
                  let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
                  let channel = buffer.floatChannelData?[0] else { return }
            buffer.frameLength = AVAudioFrameCount(samples.count)
            let scale = audioInjectionState.gain / Float(Int16.max)
            for index in samples.indices {
                channel[index] = Float(samples[index]) * scale
            }
            AudioManager.shared.mixer.capture(appAudio: buffer)
        }
    }

    public func remoteParticipantSnapshots() -> [RemoteParticipantSnapshot] {
        room.remoteParticipants.values.map { participant in
            let audioTracks = participant.audioTracks.compactMap { $0.track as? RemoteAudioTrack }
            let volume = audioTracks.first?.volume ?? 1
            return RemoteParticipantSnapshot(
                id: String(describing: participant.identity),
                name: participant.name?.isEmpty == false ? participant.name! : String(describing: participant.identity),
                isSpeaking: participant.isSpeaking,
                volume: volume
            )
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    public func setRemoteParticipantVolume(identity: String, volume: Double) {
        guard let participant = room.remoteParticipants.values.first(where: { String(describing: $0.identity) == identity }) else { return }
        for publication in participant.audioTracks {
            (publication.track as? RemoteAudioTrack)?.volume = min(10, max(0, volume))
        }
    }

    public func unpublishAllLocalAudio() async {
        await room.localParticipant.unpublishAll()
        localTracks.removeAll()
    }

    public func disconnect() async {
        logger.info("room disconnect requested")
        localTracks.removeAll()
        await room.disconnect()
        try? AudioManager.shared.stopLocalRecording()
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
        logger.info("room disconnected engineRunning=\(AudioManager.shared.isEngineRunning, privacy: .public)")
    }

    public func recoverMicrophone() async throws {
        logger.warning("microphone recovery requested engineRunning=\(AudioManager.shared.isEngineRunning, privacy: .public)")
        guard localTracks[Track.microphoneName] != nil else { return }
        audioInjectionGate.pauseAndWait()
        defer { audioInjectionGate.resume() }
        try prepareAudioSession(for: lastProcessing)
        if !AudioManager.shared.isEngineRunning {
            try AudioManager.shared.startLocalRecording(audioProcessingOptions: AudioProcessingOptions(
                echoCancellation: lastProcessing.echoCancellation,
                autoGainControl: lastProcessing.autoGainControl,
                noiseSuppression: lastProcessing.noiseSuppression,
                highpassFilter: lastProcessing.highpassFilter,
                echoCancellationMode: lastProcessing.echoCancellationMode,
                autoGainControlMode: lastProcessing.autoGainControlMode,
                noiseSuppressionMode: lastProcessing.noiseSuppressionMode,
                highpassFilterMode: lastProcessing.highpassFilterMode
            ))
        }
        applyMixerState()
        logger.info("microphone recovery complete engineRunning=\(AudioManager.shared.isEngineRunning, privacy: .public) micGain=\(self.microphoneMixerVolumeForLog, privacy: .public)")
    }

    public func restartMicrophone() async throws {
        logger.warning("microphone restart requested")
        guard localTracks[Track.microphoneName] != nil else { return }
        audioInjectionGate.pauseAndWait()
        defer { audioInjectionGate.resume() }
        try? AudioManager.shared.stopLocalRecording()
        try prepareAudioSession(for: lastProcessing)
        try AudioManager.shared.startLocalRecording(audioProcessingOptions: runtimeProcessingOptions(from: lastProcessing))
        applyMixerState()
        logger.info("microphone restart complete engineRunning=\(AudioManager.shared.isEngineRunning, privacy: .public) micGain=\(self.microphoneMixerVolumeForLog, privacy: .public)")
    }
}

public enum LiveKitTransportError: LocalizedError {
    case audioEngineNotRunning

    public var errorDescription: String? {
        switch self {
        case .audioEngineNotRunning:
            return "LiveKit connected, but its microphone audio engine did not stay running"
        }
    }
}
