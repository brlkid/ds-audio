import AVKit
import LiveKitTransport
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
            ChannelTab(session: session)
                .safeAreaInset(edge: .bottom, spacing: 0) { LiveKitSessionControlsBar(session: session) }
                .tabItem { Label("Channel", systemImage: "person.2.fill") }.tag(0)
            AudioTab(session: session)
                .safeAreaInset(edge: .bottom, spacing: 0) { LiveKitSessionControlsBar(session: session) }
                .tabItem { Label("Audio", systemImage: "waveform") }.tag(1)
            ChatTab(session: session)
                .safeAreaInset(edge: .bottom, spacing: 0) { LiveKitSessionControlsBar(session: session) }
                .tabItem { Label("Chat", systemImage: "message.fill") }.tag(2)
            ConfigTab(session: session)
                .safeAreaInset(edge: .bottom, spacing: 0) { LiveKitSessionControlsBar(session: session) }
                .tabItem { Label("Config", systemImage: "gearshape") }.tag(3)
            LiveKitStatsTab(session: session)
                .safeAreaInset(edge: .bottom, spacing: 0) { LiveKitSessionControlsBar(session: session) }
                .tabItem { Label("Stats", systemImage: "gauge.with.dots.needle.67percent") }.tag(4)
        }
        .onAppear { session.refreshAudioRoute(); session.refreshParticipants() }
        .navigationTitle("D's Audio")
    }
}

private struct LiveKitStatsTab: View {
    @ObservedObject var session: LiveKitOnlySession

    var body: some View {
        Form {
            Section("Connection") {
                LabeledContent("Status", value: session.status)
                LabeledContent("Room", value: session.roomName)
                if let diagnostics = session.diagnostics {
                    LabeledContent("Transport", value: diagnostics.connectionState)
                    LabeledContent("Remote participants", value: "\(diagnostics.remoteParticipantCount)")
                    LabeledContent("Remote audio tracks", value: "\(diagnostics.remoteAudioTrackCount)")
                    LabeledContent("Subscribed audio tracks", value: "\(diagnostics.subscribedRemoteAudioTrackCount)")
                }
            }

            Section("Transmit") {
                if let diagnostics = session.diagnostics {
                    LabeledContent("Microphone publication", value: diagnostics.microphonePublished ? "Published" : "Not published")
                    LabeledContent("Publication state", value: diagnostics.microphoneMuted ? "Muted" : "Unmuted")
                    LabeledContent("Captured frames", value: "\(diagnostics.capturedFrames)")
                    LabeledContent("Captured blocks", value: "\(diagnostics.capturedBlocks)")
                    LabeledContent("Non-silent blocks", value: "\(diagnostics.nonSilentCapturedBlocks)")
                    LabeledContent("Last capture peak", value: String(format: "%.5f", diagnostics.lastCapturePeak))
                    LabeledContent("Last capture RMS", value: String(format: "%.5f", diagnostics.lastCaptureRMS))
                    LabeledContent("Mixer microphone gain", value: String(format: "%.0f%%", diagnostics.microphoneMixerVolume * 100))
                    LabeledContent("Audio engine", value: diagnostics.audioEngineRunning ? "Running" : "Stopped")
                }
            }

            if let diagnostics = session.diagnostics {
                if let connection = diagnostics.connectionStatistics {
                    Section("WebRTC connection") {
                        if let value = connection.roundTripTimeMilliseconds {
                            LabeledContent("Round-trip time", value: String(format: "%.0f ms", value))
                        }
                        if let value = connection.availableOutgoingBitrate {
                            LabeledContent("Available outgoing", value: formatRate(value))
                        }
                        if let value = connection.availableIncomingBitrate {
                            LabeledContent("Available incoming", value: formatRate(value))
                        }
                        if let value = connection.packetsSent {
                            LabeledContent("Transport packets sent", value: "\(value)")
                        }
                        if let value = connection.packetsReceived {
                            LabeledContent("Transport packets received", value: "\(value)")
                        }
                        if let value = connection.bytesSent {
                            LabeledContent("Transport bytes sent", value: formatBytes(value))
                        }
                        if let value = connection.bytesReceived {
                            LabeledContent("Transport bytes received", value: formatBytes(value))
                        }
                    }
                }
                if let outbound = diagnostics.outboundAudio {
                    Section("Outbound audio") { AudioStreamStatsView(stream: outbound, direction: "Sent") }
                }
                if !diagnostics.inboundAudio.isEmpty {
                    Section("Inbound audio") {
                        ForEach(diagnostics.inboundAudio) { stream in
                            AudioStreamStatsView(stream: stream, direction: "Received")
                            if stream.id != diagnostics.inboundAudio.last?.id { Divider() }
                        }
                    }
                }
            }

            Section("Playback") {
                if let diagnostics = session.diagnostics {
                    LabeledContent("Mixer output gain", value: String(format: "%.0f%%", diagnostics.outputMixerVolume * 100))
                }
                LabeledContent("Input route", value: session.inputRoute)
                LabeledContent("Output route", value: session.outputRoute)
                LabeledContent("Sample rate", value: String(format: "%.0f Hz", AVAudioSession.sharedInstance().sampleRate))
                LabeledContent("I/O buffer", value: String(format: "%.1f ms", AVAudioSession.sharedInstance().ioBufferDuration * 1000))
            }

            if let diagnostics = session.diagnostics {
                if diagnostics.microphonePublished && diagnostics.microphoneMixerVolume == 0 {
                    Section("Attention") {
                        Text("The microphone track is published but its mixer gain is zero. The app is sending silence until the mixer state is restored.")
                            .foregroundStyle(.orange)
                    }
                }
                if diagnostics.remoteAudioTrackCount > 0 && diagnostics.subscribedRemoteAudioTrackCount == 0 {
                    Section("Attention") {
                        Text("Remote audio is published in the room, but this device has not attached a remote audio track yet.")
                            .foregroundStyle(.orange)
                    }
                }
            }

            Section {
                Button("Refresh now") {
                    session.refreshAudioRoute()
                    session.refreshParticipants()
                    session.refreshDiagnostics()
                }
                ShareLink(item: session.diagnosticsText()) {
                    Label("Share diagnostics", systemImage: "square.and.arrow.up")
                }
            }
        }
        .onAppear {
            session.refreshAudioRoute()
            session.refreshParticipants()
            session.refreshDiagnostics()
        }
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
            Section { Button("Disconnect", role: .destructive) { session.disconnect() } }
        }
        .refreshable { session.refreshParticipants() }
    }
}

private struct LiveKitSessionControlsBar: View {
    @ObservedObject var session: LiveKitOnlySession

    var body: some View {
        HStack(spacing: 12) {
            LiveKitAudioSourceButton(
                title: session.microphoneEnabled ? "Speaking" : "Muted",
                systemImage: session.microphoneEnabled ? "mic.fill" : "mic.slash.fill",
                isActive: session.microphoneEnabled,
                action: session.toggleMicrophone
            )
            .accessibilityLabel(session.microphoneEnabled ? "Microphone speaking" : "Microphone muted")
            .accessibilityHint("Double tap to \(session.microphoneEnabled ? "mute" : "unmute") the microphone")

            LiveKitAudioSourceButton(
                title: session.sharingSystemAudio
                    ? (session.systemAudioMuted ? "Audio muted" : "Audio on")
                    : "Share audio",
                systemImage: session.systemAudioMuted ? "speaker.slash.fill" : "waveform",
                isActive: session.sharingSystemAudio && !session.systemAudioMuted,
                action: session.toggleSystemAudioSource
            )
            .accessibilityLabel(
                session.sharingSystemAudio
                    ? (session.systemAudioMuted ? "System audio muted" : "System audio enabled")
                    : "Share system audio"
            )
            .accessibilityHint(
                session.sharingSystemAudio
                    ? "Double tap to \(session.systemAudioMuted ? "unmute" : "mute") system audio"
                    : "Double tap to choose an app or display for system audio"
            )
        }
        .padding(.horizontal)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }
}

private struct LiveKitAudioSourceButton: View {
    let title: String
    let systemImage: String
    let isActive: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .tint(isActive ? .green : .secondary)
    }
}

private struct AudioTab: View {
    @ObservedObject var session: LiveKitOnlySession

    var body: some View {
        Form {
            Section("Devices") {
                if !session.inputOptions.isEmpty {
                    Picker("Input", selection: Binding(get: { session.selectedInputID }, set: { session.selectInput($0) })) {
                        ForEach(session.inputOptions, id: \.id) { input in
                            Text(input.name).tag(input.id)
                        }
                    }
                } else {
                    LabeledContent("Input", value: session.inputRoute)
                }
                LabeledContent("Active input", value: session.inputRoute)
                AVRoutePicker().frame(maxWidth: .infinity, alignment: .leading)
                Text(session.nativeCallAudioActive
                     ? "Output is controlled by the native call controls while the call is active."
                     : "Use Output for iPhone Speaker or Receiver. Use the system route picker for AirPods, Bluetooth, and AirPlay.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("Sources") {
                SourceControlRow(
                    title: "Microphone",
                    detail: session.inputRoute,
                    state: session.microphoneEnabled ? "On" : "Muted",
                    action: { session.toggleMicrophone() }
                )
                SourceControlRow(
                    title: "System audio",
                    detail: session.sharingSystemAudio ? "Screen/audio capture" : "Not sharing",
                    state: session.sharingSystemAudio ? (session.systemAudioMuted ? "Muted" : "On") : "Off",
                    action: session.toggleSystemAudioSource
                )
            }
            Section("Mixer") {
                AudioLevelRow(title: "Microphone", value: Binding(get: { session.microphoneLevel }, set: { session.setLevel($0, level: .microphone) }), maximum: 1)
                AudioLevelRow(title: "System audio", value: Binding(get: { session.systemLevel }, set: { session.setLevel($0, level: .system) }), maximum: 2)
                AudioLevelRow(title: "What you hear", value: Binding(get: { session.monitorLevel }, set: { session.setLevel($0, level: .monitor) }), maximum: 1)
                Text("Microphone and captured system audio are mixed locally into one outgoing LiveKit stream. The controls are persisted on this device.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("Apple audio processing") {
                Toggle("Echo cancellation", isOn: Binding(
                    get: { session.appleEchoCancellation },
                    set: { session.setAppleEchoCancellation($0) }
                ))
                Toggle("Noise suppression", isOn: Binding(
                    get: { session.appleNoiseSuppression },
                    set: { session.setAppleNoiseSuppression($0) }
                ))
                Toggle("Automatic gain control", isOn: Binding(
                    get: { session.appleAutomaticGainControl },
                    set: { session.setAppleAutomaticGainControl($0) }
                ))
                Text("Uses Apple’s platform voice-processing path. Echo cancellation and noise suppression can be coupled by iOS.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("WebRTC audio processing") {
                Toggle("Echo cancellation", isOn: Binding(
                    get: { session.webRTCEchoCancellation },
                    set: { session.setWebRTCEchoCancellation($0) }
                ))
                Toggle("Noise suppression", isOn: Binding(
                    get: { session.webRTCNoiseSuppression },
                    set: { session.setWebRTCNoiseSuppression($0) }
                ))
                Toggle("Automatic gain control", isOn: Binding(
                    get: { session.webRTCAutomaticGainControl },
                    set: { session.setWebRTCAutomaticGainControl($0) }
                ))
                Toggle("High-pass filter", isOn: Binding(
                    get: { session.highpassFilter },
                    set: { session.setHighpassFilter($0) }
                ))
                Toggle("Typing-noise detection", isOn: Binding(
                    get: { session.typingNoiseDetection },
                    set: { session.setTypingNoiseDetection($0) }
                ))
                Text("Uses LiveKit/WebRTC software processing on the device. Each effect is independent from the Apple section.")
                    .font(.footnote).foregroundStyle(.secondary)
                Text(session.audioStatus).font(.footnote).foregroundStyle(.secondary)
            }
            Section("Audio transport") {
                Toggle("DTX / silence suppression", isOn: Binding(
                    get: { session.dtxEnabled },
                    set: { session.setDTXEnabled($0) }
                ))
                Toggle("RED / packet recovery", isOn: Binding(
                    get: { session.redEnabled },
                    set: { session.setREDEnabled($0) }
                ))
                Text("These are encoder transport options. DTX can reduce silence traffic; RED adds redundant audio data to help recover from packet loss.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("Output safety") {
                Toggle("Master limiter", isOn: Binding(
                    get: { session.limiterEnabled },
                    set: { session.setLimiterEnabled($0) }
                ))
                Text("Prevents the mixed microphone and system-audio signal from exceeding full scale before Opus encoding.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("Quality") {
                Picker("Opus maximum bitrate", selection: Binding(
                    get: { session.audioBitrateKbps },
                    set: { session.setAudioBitrate($0) }
                )) {
                    ForEach([0, 24, 32, 48, 64, 96, 128], id: \.self) { bitrate in
                        Text(bitrate == 0 ? "Automatic" : "\(bitrate) kbps").tag(bitrate)
                    }
                }
                Text(session.audioBitrateKbps == 0
                     ? "Uses the SDK/browser default bitrate. Opus may send less depending on speech, silence, and network conditions."
                     : "Uses a \(session.audioBitrateKbps) kbps maximum bitrate. Opus may send less depending on speech, silence, and network conditions.")
                    .font(.footnote).foregroundStyle(.secondary)
                Text("Changing this republishes the audio track briefly. It does not disable or enable voice processing.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("Timing") {
                AudioLevelRow(title: "I/O buffer", value: Binding(get: { session.ioBufferMilliseconds }, set: { session.setIOBuffer($0) }), maximum: 40, suffix: " ms")
                Button("Restart audio with current settings") { session.restartAudio() }
            }
        }
        .onAppear { session.refreshAudioRoute() }
    }
}

private struct ChatTab: View {
    @ObservedObject var session: LiveKitOnlySession
    @State private var text = ""

    var body: some View {
        VStack(spacing: 0) {
            if session.messages.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "message").font(.largeTitle).foregroundStyle(.secondary)
                    Text("No messages yet").font(.headline)
                    Text("Messages from people in this room will appear here.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(session.messages) { message in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(message.sender).font(.caption).foregroundStyle(.secondary)
                        Text(message.text)
                    }
                }
            }
            HStack(spacing: 8) {
                TextField("Message the room", text: $text)
                    .textFieldStyle(.roundedBorder)
                Button("Send") {
                    session.sendChat(text)
                    text = ""
                }
                .buttonStyle(.borderedProminent)
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding()
        }
    }
}

private struct AudioStreamStatsView: View {
    let stream: LiveKitRoomTransport.Diagnostics.AudioStream
    let direction: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let value = stream.codec { LabeledContent("Codec", value: value) }
            if let value = stream.clockRate { LabeledContent("Clock rate", value: "\(value) Hz") }
            if let value = stream.channels { LabeledContent("Channels", value: "\(value)") }
            if let value = stream.packets { LabeledContent("Packets \(direction.lowercased())", value: "\(value)") }
            if let value = stream.packetsLost { LabeledContent("Packets lost", value: "\(value)") }
            if let value = stream.bytes { LabeledContent("Bytes \(direction.lowercased())", value: formatBytes(value)) }
            if let value = stream.measuredBitrate { LabeledContent("Measured bitrate", value: formatRate(value)) }
            if let value = stream.targetBitrate { LabeledContent("Target bitrate", value: formatRate(value)) }
            if let value = stream.jitterMilliseconds { LabeledContent("Jitter", value: String(format: "%.2f ms", value)) }
            if let value = stream.jitterBufferDelayMilliseconds { LabeledContent("Jitter buffer delay", value: String(format: "%.2f ms", value)) }
            if let value = stream.concealedSamples { LabeledContent("Concealed samples", value: "\(value)") }
            if let value = stream.silentConcealedSamples { LabeledContent("Silent concealed samples", value: "\(value)") }
            if let value = stream.concealmentEvents { LabeledContent("Concealment events", value: "\(value)") }
            if let value = stream.audioLevel { LabeledContent("Audio level", value: String(format: "%.5f", value)) }
            if let value = stream.retransmittedPackets { LabeledContent("Retransmitted packets", value: "\(value)") }
            if let value = stream.retransmittedBytes { LabeledContent("Retransmitted bytes", value: formatBytes(value)) }
        }
    }
}

private func formatRate(_ bitsPerSecond: Double) -> String {
    if bitsPerSecond >= 1_000_000 { return String(format: "%.2f Mbps", bitsPerSecond / 1_000_000) }
    return String(format: "%.0f kbps", bitsPerSecond / 1_000)
}

private func formatBytes(_ bytes: UInt64) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .binary)
}

private struct SourceControlRow: View {
    let title: String
    let detail: String
    let state: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text(state).font(.subheadline).foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title), \(detail), \(state)")
        .accessibilityHint("Double tap to change")
    }
}

private struct ConfigTab: View {
    @ObservedObject var session: LiveKitOnlySession

    var body: some View {
        Form {
            Section("System integration") {
                Toggle("System call controls", isOn: Binding(
                    get: { session.callControlsEnabled },
                    set: { session.setCallControlsEnabled($0) }
                ))
                Text("When enabled, D’s Audio appears as an active iOS call so lock-screen and headset mute controls can control the LiveKit microphone.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section {
                NavigationLink {
                    AnnouncementSettingsView(session: session)
                } label: {
                    HStack {
                        Label("Announcements", systemImage: "megaphone")
                        Spacer()
                        Text("Configure").foregroundStyle(.secondary)
                    }
                }
            }
            Section("Device behavior") {
                Picker("Default output", selection: Binding(
                    get: { session.defaultOutput },
                    set: { session.setDefaultOutput($0) }
                )) {
                    Text("iPhone speaker").tag("speaker")
                    Text("System-selected route").tag("system")
                }
                Toggle("Proximity sensor", isOn: Binding(
                    get: { session.proximitySensorEnabled },
                    set: { session.setProximitySensorEnabled($0) }
                ))
                Text("When enabled, iOS can use the proximity sensor for phone-style audio behavior. It does not override AirPods or another explicitly selected route.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("About this build") {
                Text("D’s Audio publishes the microphone as a named LiveKit audio track. A future capture source can be published as a separate System audio track, allowing listeners to mute or adjust each source independently.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
    }
}

private struct AnnouncementSettingsView: View {
    @ObservedObject var session: LiveKitOnlySession

    var body: some View {
        Form {
            Section("Send from this phone") {
                Toggle("Microphone state", isOn: Binding(
                    get: { session.sendMicrophoneAnnouncements },
                    set: { session.setSendMicrophoneAnnouncements($0) }
                ))
                Toggle("Screen/audio sharing", isOn: Binding(
                    get: { session.sendSystemAudioAnnouncements },
                    set: { session.setSendSystemAudioAnnouncements($0) }
                ))
            }
            Section("Announcement voice") {
                Picker("Voice", selection: Binding(
                    get: { session.announcementVoiceIdentifier },
                    set: { session.setAnnouncementVoice($0) }
                )) {
                    Text("Device default").tag("")
                    ForEach(session.announcementVoices) { voice in
                        Text("\(voice.name) · \(voice.language)").tag(voice.id)
                    }
                }
                Button("Test voice") {
                    session.testAnnouncementVoice()
                }
            }
            Section {
                Text("Announcements use a reliable room message with type 1 and a short announcement string. The selected system voice reads incoming announcements. Device default uses the preferred voice already configured on this iPhone.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Announcements")
    }
}

private struct AudioLevelRow: View {
    let title: String
    @Binding var value: Double
    let maximum: Double
    var suffix: String = "%"

    var body: some View {
        VStack(alignment: .leading) {
            HStack { Text(title); Spacer(); Text(suffix == "%" ? "\(Int(value * 100))%" : "\(Int(value))\(suffix)").monospacedDigit().foregroundStyle(.secondary) }
            Slider(value: $value, in: 0...maximum, step: 0.05)
        }
    }
}

private struct AVRoutePicker: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView { AVRoutePickerView() }
    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}
