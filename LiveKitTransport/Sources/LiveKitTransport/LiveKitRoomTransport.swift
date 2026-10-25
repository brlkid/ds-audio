import Foundation
import AVFoundation
import LiveKit

/// Small, UI-agnostic LiveKit transport used by TT Custom during the backend
/// migration. It intentionally owns only room/media lifecycle; authentication
/// stays in the app because the app already owns the saved server credentials.
@MainActor
public final class LiveKitRoomTransport: NSObject {
    public let room: Room
    private var localTracks: [String: LocalAudioTrack] = [:]

    public override init() {
        room = Room()
        super.init()
    }

    public var isConnected: Bool {
        room.connectionState == .connected
    }

    public func connect(url: String, token: String) async throws {
        let options = ConnectOptions(
            autoSubscribe: true,
            enableMicrophone: false
        )
        try await room.connect(url: url, token: token, connectOptions: options)
    }

    public func publishMicrophone(enabled: Bool, processing: AudioCaptureOptions = AudioCaptureOptions()) async throws {
        if let track = localTracks[Track.microphoneName] {
            enabled ? try await track.unmute() : try await track.mute()
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
                dtx: true,
                red: true,
                streamName: "Microphone"
            )
        )
        localTracks[Track.microphoneName] = track
    }

    public func setTrackMuted(name: String, muted: Bool) async throws {
        guard let track = localTracks[name] else { return }
        muted ? try await track.mute() : try await track.unmute()
    }

    public func setMicrophoneProcessing(echoCancellation: Bool,
                                        noiseSuppression: Bool,
                                        automaticGainControl: Bool) throws {
        guard let track = localTracks[Track.microphoneName] else { return }
        _ = try track.setAudioProcessingOptions(AudioProcessingOptions(
            echoCancellation: echoCancellation,
            autoGainControl: automaticGainControl,
            noiseSuppression: noiseSuppression
        ))
    }

    /// Injects already-mixed app audio into LiveKit's active microphone path.
    /// This intentionally produces one outgoing program stream rather than a
    /// second publication, so existing receivers remain compatible.
    public func captureSystemAudio(samples: [Int16], gain: Double) {
        guard !samples.isEmpty else { return }
        guard let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData?[0] else { return }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        let scale = Float(max(0, gain)) / Float(Int16.max)
        for index in samples.indices {
            channel[index] = Float(samples[index]) * scale
        }
        AudioManager.shared.mixer.capture(appAudio: buffer)
    }

    public func unpublishAllLocalAudio() async {
        await room.localParticipant.unpublishAll()
        localTracks.removeAll()
    }

    public func disconnect() async {
        localTracks.removeAll()
        await room.disconnect()
    }
}
