import AVFoundation
import Foundation
import LiveKitTransport
import SwiftUI

@MainActor
final class LiveKitOnlySession: ObservableObject {
    @Published var host = UserDefaults.standard.string(forKey: "ttcustom.livekitURL") ?? "https://derricks-macbook.tail435bed.ts.net"
    @Published var username = UserDefaults.standard.string(forKey: "ttcustom.username") ?? "derrick"
    @Published var password = ""
    @Published var nickname = UserDefaults.standard.string(forKey: "ttcustom.nickname") ?? "derricks-iphone"
    @Published var status = "Not connected"
    @Published var connected = false
    @Published var microphoneEnabled = false
    @Published var roomName = "main"
    @Published var participantCount = 0
    @Published var inputRoute = "Not active"
    @Published var outputRoute = "Not active"

    let transport = LiveKitRoomTransport()
    private let auth = TTCustomLiveKitAuthClient()
    private var participantIdentity: String {
        let key = "ttcustom.livekitParticipantIdentity"
        if let saved = UserDefaults.standard.string(forKey: key) { return saved }
        let value = "ios-\(UUID().uuidString.lowercased())"
        UserDefaults.standard.set(value, forKey: key)
        return value
    }

    func connect() {
        guard URL(string: host) != nil, host.hasPrefix("http") else {
            status = "Enter the HTTPS server URL"
            return
        }
        guard !username.isEmpty, !password.isEmpty else {
            status = "Enter your username and password"
            return
        }
        status = "Connecting…"
        let host = host
        let username = username
        let password = password
        let nickname = nickname
        let roomName = roomName
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let response = try await auth.requestToken(
                    host: host,
                    username: username,
                    password: password,
                    room: roomName,
                    participantName: nickname,
                    participantIdentity: participantIdentity
                )
                try await transport.connect(url: response.serverURL, token: response.participantToken)
                try await transport.setMicrophone(enabled: true)
                self.connected = true
                self.microphoneEnabled = true
                self.status = "Connected"
                self.refreshAudioRoute()
                self.refreshParticipants()
            } catch {
                self.connected = false
                self.microphoneEnabled = false
                self.status = error.localizedDescription
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
            status = "Not connected"
            refreshAudioRoute()
        }
    }

    func toggleMicrophone() {
        let enabled = !microphoneEnabled
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await transport.setMicrophone(enabled: enabled)
                microphoneEnabled = enabled
            } catch {
                status = error.localizedDescription
            }
        }
    }

    func refreshParticipants() {
        participantCount = transport.room.remoteParticipants.count + 1
    }

    func refreshAudioRoute() {
        let audioSession = AVAudioSession.sharedInstance()
        inputRoute = audioSession.currentRoute.inputs.first?.portName ?? "Not active"
        outputRoute = audioSession.currentRoute.outputs.first?.portName ?? "Not active"
    }
}
