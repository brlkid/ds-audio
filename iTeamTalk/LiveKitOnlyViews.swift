import AVKit
import SwiftUI

struct LiveKitOnlyRootView: View {
    @StateObject private var session = LiveKitOnlySession()

    var body: some View {
        NavigationStack {
            if session.connected {
                LiveKitOnlyChannelView(session: session)
            } else {
                LiveKitOnlyServerView(session: session)
            }
        }
    }
}

private struct LiveKitOnlyServerView: View {
    @ObservedObject var session: LiveKitOnlySession

    var body: some View {
        Form {
            Section("Server") {
                TextField("HTTPS server URL", text: $session.host)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField("Room", text: $session.roomName)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
            Section("Account") {
                TextField("Username", text: $session.username)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField("Password", text: $session.password)
                TextField("Display name", text: $session.nickname)
            }
            Section {
                Button("Connect") { session.connect() }
                    .frame(maxWidth: .infinity)
            }
            if session.status != "Not connected" {
                Section("Status") { Text(session.status).foregroundStyle(.secondary) }
            }
        }
        .navigationTitle("TT Custom")
    }
}

private struct LiveKitOnlyChannelView: View {
    @ObservedObject var session: LiveKitOnlySession
    @State private var selectedTab = 0

    var body: some View {
        TabView(selection: $selectedTab) {
            Form {
                Section("Connection") {
                    LabeledContent("Status", value: session.status)
                    LabeledContent("Room", value: session.roomName)
                    LabeledContent("People", value: "\(session.participantCount)")
                }
                Section("Microphone") {
                    Button(session.microphoneEnabled ? "Mute microphone" : "Unmute microphone") {
                        session.toggleMicrophone()
                    }
                }
                Section {
                    Button("Disconnect", role: .destructive) { session.disconnect() }
                }
            }
            .tabItem { Label("Channel", systemImage: "person.2.fill") }
            .tag(0)

            Form {
                Section("Audio route") {
                    LabeledContent("Input", value: session.inputRoute)
                    LabeledContent("Output", value: session.outputRoute)
                    AVRoutePicker()
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Section("Transport") {
                    Text("LiveKit manages the room transport and remote audio playback. Device and processing controls will be added on top of this transport.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .tabItem { Label("Audio", systemImage: "waveform") }
            .tag(1)

            Form {
                Section("LiveKit") {
                    LabeledContent("Server", value: session.host)
                    LabeledContent("Room", value: session.roomName)
                    LabeledContent("Participants", value: "\(session.participantCount)")
                }
            }
            .tabItem { Label("Network", systemImage: "network") }
            .tag(2)
        }
        .onAppear { session.refreshAudioRoute(); session.refreshParticipants() }
        .navigationTitle("TT Custom")
    }
}

private struct AVRoutePicker: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView { AVRoutePickerView() }
    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}
