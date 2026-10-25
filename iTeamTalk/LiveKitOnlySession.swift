import AVFoundation
import Foundation
import LiveKitTransport
import SwiftUI

@MainActor
final class LiveKitOnlySession: ObservableObject {
    struct Participant: Identifiable, Equatable {
        let id: String
        let name: String
        var isSpeaking: Bool
        var volume: Double
    }

    struct AudioSource: Identifiable, Equatable {
        let id: String
        let title: String
        let detail: String
        var isEnabled: Bool
        let isAvailable: Bool
    }

    @Published var host = UserDefaults.standard.string(forKey: "ttcustom.livekitURL") ?? "https://derricks-macbook.tail435bed.ts.net"
    @Published var username = UserDefaults.standard.string(forKey: "ttcustom.username") ?? "derrick"
    @Published var password = ""
    @Published var nickname = UserDefaults.standard.string(forKey: "ttcustom.nickname") ?? "derricks-iphone"
    @Published var roomName = UserDefaults.standard.string(forKey: "ttcustom.room") ?? "main"
    @Published var status = "Not connected"
    @Published var connected = false
    @Published var microphoneEnabled = false
    @Published var participantCount = 0
    @Published var participants: [Participant] = []
    @Published var inputRoute = "Not active"
    @Published var outputRoute = "Not active"
    @Published var microphoneLevel = UserDefaults.standard.double(forKey: "ttcustom.micLevel") == 0 ? 1 : UserDefaults.standard.double(forKey: "ttcustom.micLevel")
    @Published var systemLevel = UserDefaults.standard.double(forKey: "ttcustom.systemLevel") == 0 ? 1 : UserDefaults.standard.double(forKey: "ttcustom.systemLevel")
    @Published var monitorLevel = UserDefaults.standard.double(forKey: "ttcustom.monitorLevel") == 0 ? 1 : UserDefaults.standard.double(forKey: "ttcustom.monitorLevel")
    @Published var echoCancellation = true
    @Published var noiseSuppression = true
    @Published var automaticGainControl = true
    @Published var audioStatus = "Microphone track is not published"
    @Published var sharingSystemAudio = false
    @Published var systemAudioMuted = false
    @Published var callControlsEnabled = UserDefaults.standard.bool(forKey: "ttcustom.callControls")

    let transport = LiveKitRoomTransport()
    private let auth = TTCustomLiveKitAuthClient()
    private let callCoordinator = DSAudioCallCoordinator()

    init() {
        password = TTCustomKeychain.load(host: host, username: username)
        callCoordinator.onMuteChanged = { [weak self] muted in
            Task { @MainActor in
                guard let self else { return }
                do { try await self.setMicrophone(enabled: !muted) }
                catch { self.status = error.localizedDescription }
            }
        }
        callCoordinator.onEnded = { [weak self] in
            Task { @MainActor in self?.disconnect() }
        }
    }

    private var participantIdentity: String {
        let key = "ttcustom.livekitParticipantIdentity"
        if let saved = UserDefaults.standard.string(forKey: key) { return saved }
        let value = "ios-\(UUID().uuidString.lowercased())"
        UserDefaults.standard.set(value, forKey: key)
        return value
    }

    var sources: [AudioSource] {
        [
            AudioSource(id: "microphone", title: "Microphone", detail: inputRoute, isEnabled: microphoneEnabled, isAvailable: true),
            AudioSource(id: "system", title: "System audio", detail: sharingSystemAudio ? "Screen/audio capture" : "Not sharing", isEnabled: sharingSystemAudio && !systemAudioMuted, isAvailable: systemAudioAvailable),
        ]
    }

    var systemAudioAvailable: Bool {
        if #available(iOS 27.0, *) { return true }
        return false
    }

    func connect() {
        guard URL(string: host) != nil, host.hasPrefix("http") else { status = "Enter the HTTPS server URL"; return }
        guard !username.isEmpty, !password.isEmpty else { status = "Enter your username and password"; return }
        UserDefaults.standard.set(host, forKey: "ttcustom.livekitURL")
        UserDefaults.standard.set(username, forKey: "ttcustom.username")
        UserDefaults.standard.set(nickname, forKey: "ttcustom.nickname")
        UserDefaults.standard.set(roomName, forKey: "ttcustom.room")
        TTCustomKeychain.save(password, host: host, username: username)
        status = "Connecting…"
        let host = host, username = username, password = password, nickname = nickname, roomName = roomName
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let response = try await auth.requestToken(host: host, username: username, password: password, room: roomName, participantName: nickname, participantIdentity: participantIdentity)
                try await transport.connect(url: response.serverURL, token: response.participantToken)
                connected = true
                status = "Connected"
                refreshAudioRoute()
                refreshParticipants()
                try await setMicrophone(enabled: true)
                if callControlsEnabled { callCoordinator.begin(roomName: roomName) }
            } catch {
                connected = false
                microphoneEnabled = false
                status = error.localizedDescription
            }
        }
    }

    func disconnect() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            await transport.disconnect()
            connected = false
            microphoneEnabled = false
            participantCount = 0
            participants = []
            audioStatus = "Microphone track is not published"
            sharingSystemAudio = false
            status = "Not connected"
            refreshAudioRoute()
        }
    }

    func setMicrophone(enabled: Bool) async throws {
        try await transport.publishMicrophone(enabled: enabled)
        microphoneEnabled = enabled
        audioStatus = enabled ? "Microphone track live" : "Microphone muted"
    }

    func toggleMicrophone() {
        let enabled = !microphoneEnabled
        Task { @MainActor [weak self] in
            guard let self else { return }
            do { try await setMicrophone(enabled: enabled) }
            catch { status = error.localizedDescription }
        }
    }

    func setCallControlsEnabled(_ enabled: Bool) {
        callControlsEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "ttcustom.callControls")
        if enabled, connected { callCoordinator.begin(roomName: roomName) }
        if !enabled { callCoordinator.endFromApp() }
    }

    func applyProcessing() {
        do {
            try transport.setMicrophoneProcessing(
                echoCancellation: echoCancellation,
                noiseSuppression: noiseSuppression,
                automaticGainControl: automaticGainControl
            )
        } catch {
            status = error.localizedDescription
        }
    }

    func toggleSystemAudio() {
        if sharingSystemAudio {
            stopSystemAudioSharing()
        } else {
            startSystemAudioSharing()
        }
    }

    func setSystemAudioMuted(_ muted: Bool) {
        systemAudioMuted = muted
    }

    @available(iOS 27.0, *)
    private func startSystemAudioSharingOnSupportedOS() {
        let capture = TTCustomSystemAudioCapture()
        capture.onAudio = { [weak self] samples in
            guard let self else { return }
            self.transport.captureSystemAudio(samples: samples, gain: self.systemAudioMuted ? 0 : self.systemLevel)
        }
        capture.onFailure = { [weak self] message in
            Task { @MainActor in
                self?.sharingSystemAudio = false
                self?.status = message
            }
        }
        capture.presentPicker()
        systemAudioCapture = capture
        sharingSystemAudio = true
        audioStatus = "Microphone and system audio are mixed into one LiveKit stream"
    }

    private var systemAudioCapture: AnyObject?

    private func startSystemAudioSharing() {
        guard systemAudioAvailable else {
            status = "System audio capture requires iOS 27 or later"
            return
        }
        if #available(iOS 27.0, *) { startSystemAudioSharingOnSupportedOS() }
    }

    private func stopSystemAudioSharing() {
        if #available(iOS 27.0, *), let capture = systemAudioCapture as? TTCustomSystemAudioCapture {
            capture.stop()
        }
        systemAudioCapture = nil
        sharingSystemAudio = false
        audioStatus = microphoneEnabled ? "Microphone track live" : "Microphone track is not published"
    }

    func setLevel(_ value: Double, key: String) {
        switch key {
        case "microphone": microphoneLevel = value; UserDefaults.standard.set(value, forKey: "ttcustom.micLevel")
        case "system": systemLevel = value; UserDefaults.standard.set(value, forKey: "ttcustom.systemLevel")
        default: monitorLevel = value; UserDefaults.standard.set(value, forKey: "ttcustom.monitorLevel")
        }
    }

    func refreshParticipants() {
        participants = transport.remoteParticipantSnapshots().map {
            Participant(id: $0.id, name: $0.name, isSpeaking: $0.isSpeaking, volume: $0.volume)
        }
        participantCount = participants.count + 1
    }

    func setParticipantVolume(_ participant: Participant, value: Double) {
        guard let index = participants.firstIndex(where: { $0.id == participant.id }) else { return }
        participants[index].volume = value
        transport.setRemoteParticipantVolume(identity: participant.id, volume: value)
        UserDefaults.standard.set(value, forKey: "ttcustom.volume.\(participant.id)")
    }

    func refreshAudioRoute() {
        let audioSession = AVAudioSession.sharedInstance()
        inputRoute = audioSession.currentRoute.inputs.first?.portName ?? "Not active"
        outputRoute = audioSession.currentRoute.outputs.first?.portName ?? "Not active"
    }
}
