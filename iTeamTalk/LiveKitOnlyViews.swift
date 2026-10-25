import AVKit
import SwiftUI

struct LiveKitOnlyRootView: View {
    @StateObject private var session = LiveKitOnlySession()

    var body: some View {
        NavigationStack {
            if session.connected { LiveKitOnlyChannelView(session: session) }
            else { LiveKitOnlyServerView(session: session) }
        }
    }
}

private struct LiveKitOnlyServerView: View {
    @ObservedObject var session: LiveKitOnlySession

    var body: some View {
        Form {
            Section("Server") {
                TextField("HTTPS server URL", text: $session.host).textInputAutocapitalization(.never).autocorrectionDisabled()
                TextField("Room", text: $session.roomName).textInputAutocapitalization(.never).autocorrectionDisabled()
            }
            Section("Account") {
                TextField("Username", text: $session.username).textInputAutocapitalization(.never).autocorrectionDisabled()
                SecureField("Password", text: $session.password)
                TextField("Display name", text: $session.nickname)
            }
            Section { Button("Connect") { session.connect() }.frame(maxWidth: .infinity) }
            if session.status != "Not connected" { Section("Status") { Text(session.status).foregroundStyle(.secondary) } }
        }
        .navigationTitle("D's Audio")
    }
}

private struct LiveKitOnlyChannelView: View {
    @ObservedObject var session: LiveKitOnlySession
    @State private var selectedTab = 0

    var body: some View {
        TabView(selection: $selectedTab) {
            ChannelTab(session: session).tabItem { Label("Channel", systemImage: "person.2.fill") }.tag(0)
            AudioTab(session: session).tabItem { Label("Audio", systemImage: "waveform") }.tag(1)
            ConfigTab(session: session).tabItem { Label("Config", systemImage: "gearshape") }.tag(2)
        }
        .onAppear { session.refreshAudioRoute(); session.refreshParticipants() }
        .navigationTitle("D's Audio")
    }
}

private struct ChannelTab: View {
    @ObservedObject var session: LiveKitOnlySession

    var body: some View {
        List {
            Section("Room") {
                LabeledContent("Status", value: session.status)
                LabeledContent("Room", value: session.roomName)
                LabeledContent("People", value: "\(session.participantCount)")
            }
            Section("People") {
                Label("You · \(session.nickname)", systemImage: session.microphoneEnabled ? "mic.fill" : "mic.slash.fill")
                ForEach(session.participants) { participant in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Label(participant.name, systemImage: participant.isSpeaking ? "speaker.wave.2.fill" : "person.fill")
                            Spacer()
                            Text("\(Int(participant.volume * 100))%")
                                .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                        }
                        Slider(value: Binding(
                            get: { participant.volume },
                            set: { session.setParticipantVolume(participant, value: $0) }
                        ), in: 0...2, step: 0.05)
                        .accessibilityLabel("Volume for \(participant.name)")
                    }
                }
                if session.participants.isEmpty { Text("No other participants").foregroundStyle(.secondary) }
            }
            Section("Your controls") {
                Button(session.microphoneEnabled ? "Mute microphone" : "Unmute microphone") { session.toggleMicrophone() }
                    .accessibilityHint(session.microphoneEnabled ? "Stops publishing the microphone track" : "Publishes the microphone track")
            }
            Section { Button("Disconnect", role: .destructive) { session.disconnect() } }
        }
        .refreshable { session.refreshParticipants() }
    }
}

private struct AudioTab: View {
    @ObservedObject var session: LiveKitOnlySession

    var body: some View {
        Form {
            Section("Devices") {
                LabeledContent("Input", value: session.inputRoute)
                LabeledContent("Output", value: session.outputRoute)
                AVRoutePicker().frame(maxWidth: .infinity, alignment: .leading)
            }
            Section("Sources") {
                ForEach(session.sources) { source in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(source.title)
                            Text(source.detail).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if source.id == "system" && source.isAvailable {
                            Button(session.sharingSystemAudio ? (session.systemAudioMuted ? "Unmute" : "Mute") : "Share") {
                                if session.sharingSystemAudio { session.setSystemAudioMuted(!session.systemAudioMuted) }
                                else { session.toggleSystemAudio() }
                            }
                            .buttonStyle(.bordered)
                        } else if source.isAvailable {
                            Image(systemName: source.isEnabled ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(source.isEnabled ? .green : .secondary)
                                .accessibilityLabel(source.isEnabled ? "Enabled" : "Muted")
                        } else {
                            Text("Unavailable").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Section("Mixer") {
                AudioLevelRow(title: "Microphone", value: Binding(get: { session.microphoneLevel }, set: { session.setLevel($0, key: "microphone") }))
                AudioLevelRow(title: "System audio", value: Binding(get: { session.systemLevel }, set: { session.setLevel($0, key: "system") }))
                AudioLevelRow(title: "What you hear", value: Binding(get: { session.monitorLevel }, set: { session.setLevel($0, key: "monitor") }))
                Text("Microphone and captured system audio are mixed locally into one outgoing LiveKit stream. The controls are persisted on this device.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("Voice processing") {
                Toggle("Echo cancellation", isOn: $session.echoCancellation)
                Toggle("Noise suppression", isOn: $session.noiseSuppression)
                Toggle("Automatic gain control", isOn: $session.automaticGainControl)
                Text(session.audioStatus).font(.footnote).foregroundStyle(.secondary)
            }
        }
        .onAppear { session.refreshAudioRoute() }
        .onChange(of: session.echoCancellation) { _ in session.applyProcessing() }
        .onChange(of: session.noiseSuppression) { _ in session.applyProcessing() }
        .onChange(of: session.automaticGainControl) { _ in session.applyProcessing() }
    }
}

private struct ConfigTab: View {
    @ObservedObject var session: LiveKitOnlySession

    var body: some View {
        Form {
            Section("Connection") {
                TextField("Server URL", text: $session.host).textInputAutocapitalization(.never).autocorrectionDisabled()
                TextField("Room", text: $session.roomName).textInputAutocapitalization(.never).autocorrectionDisabled()
                LabeledContent("Server status", value: session.status)
            }
            Section("Account") {
                TextField("Username", text: $session.username).textInputAutocapitalization(.never).autocorrectionDisabled()
                SecureField("Password", text: $session.password)
                TextField("Display name", text: $session.nickname)
            }
            Section("System integration") {
                Toggle("System call controls", isOn: Binding(
                    get: { session.callControlsEnabled },
                    set: { session.setCallControlsEnabled($0) }
                ))
                Text("When enabled, D’s Audio appears as an active iOS call so lock-screen and headset mute controls can control the LiveKit microphone.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("About this build") {
                Text("D’s Audio publishes the microphone as a named LiveKit audio track. A future capture source can be published as a separate System audio track, allowing listeners to mute or adjust each source independently.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
    }
}

private struct AudioLevelRow: View {
    let title: String
    @Binding var value: Double

    var body: some View {
        VStack(alignment: .leading) {
            HStack { Text(title); Spacer(); Text("\(Int(value * 100))%" ).monospacedDigit().foregroundStyle(.secondary) }
            Slider(value: $value, in: 0...2, step: 0.05)
        }
    }
}

private struct AVRoutePicker: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView { AVRoutePickerView() }
    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}
