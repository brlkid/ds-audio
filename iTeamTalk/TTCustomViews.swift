import AVKit
import AVFoundation
import SwiftUI
import UIKit

struct TTCustomRootView: View {
    @StateObject private var session = TTCustomSession()

    var body: some View {
        NavigationStack {
            if session.connected {
                TTCustomAudioView(session: session)
            } else {
                TTCustomServerView(session: session)
            }
        }
    }
}

struct TTCustomServerView: View {
    @ObservedObject var session: TTCustomSession

    var body: some View {
        Form {
            Section("Server") {
                TextField("Host or LiveKit URL", text: $session.host)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                if session.host.hasPrefix("http://") || session.host.hasPrefix("https://") {
                    Text("LiveKit mode: use the server URL, for example https://your-host.example")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    HStack {
                        TextField("TCP port", text: $session.tcpPort).keyboardType(.numberPad)
                        TextField("UDP port", text: $session.udpPort).keyboardType(.numberPad)
                    }
                }
            }
            Section("Account") {
                TextField("Username", text: $session.username)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField("Password", text: $session.password)
                TextField("Nickname", text: $session.nickname)
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

struct TTCustomAudioView: View {
    @ObservedObject var session: TTCustomSession
    @State private var showingSettings = false

    var body: some View {
        TabView {
            TTCustomMainAudioTab(session: session)
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    TTCustomSessionControlsBar(session: session)
                }
                .tabItem { Label("Channel", systemImage: "person.2.fill") }
            TTCustomAudioControlsTab(session: session)
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    TTCustomSessionControlsBar(session: session)
                }
                .tabItem { Label("Audio", systemImage: "slider.vertical.3") }
            TTCustomNetworkTab(session: session)
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    TTCustomSessionControlsBar(session: session)
                }
                .tabItem { Label("Network", systemImage: "network") }
        }
        .navigationTitle("TT Custom")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showingSettings = true
                } label: {
                    Image(systemName: "gearshape")
                }
                .accessibilityLabel("Settings")
                .accessibilityHint("Open channel and server settings")
            }
        }
        .sheet(isPresented: $showingSettings) {
            TTCustomSettingsPane(session: session)
        }
        .onAppear { session.refreshRoutes() }
    }
}

private struct TTCustomSessionControlsBar: View {
    @ObservedObject var session: TTCustomSession

    var body: some View {
        HStack(spacing: 12) {
            TTCustomAudioSourceButton(
                title: session.transmitting ? "Speaking" : "Muted",
                systemImage: session.transmitting ? "mic.fill" : "mic.slash.fill",
                isActive: session.transmitting
            ) {
                session.setTransmit(!session.transmitting)
            }
            .accessibilityLabel(session.transmitting ? "Microphone speaking" : "Microphone muted")
            .accessibilityHint("Double tap to \(session.transmitting ? "mute" : "unmute") the microphone")

            TTCustomAudioSourceButton(
                title: session.sharingSystemAudio
                    ? (session.systemAudioMuted ? "Audio muted" : "Audio on")
                    : "Share audio",
                systemImage: session.systemAudioMuted ? "speaker.slash.fill" : "waveform",
                isActive: session.sharingSystemAudio && !session.systemAudioMuted
            ) {
                if session.sharingSystemAudio {
                    session.setSystemAudioMuted(!session.systemAudioMuted)
                } else {
                    session.startSystemAudioSharing()
                }
            }
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
        .overlay(alignment: .top) {
            Divider()
        }
    }
}

private struct TTCustomSettingsPane: View {
    @ObservedObject var session: TTCustomSession
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Channel audio") {
                    TTCustomChannelAudioControls(session: session)
                }

                Section("Connection") {
                    LabeledContent("Server", value: "\(session.host):\(session.tcpPort)")
                    LabeledContent("Username", value: session.username)
                    Toggle("System call controls", isOn: Binding(
                        get: { session.systemCallControlsEnabled },
                        set: { session.setSystemCallControlsEnabled($0) }
                    ))
                    Text(session.status)
                        .foregroundStyle(.secondary)
                    Button("Disconnect", role: .destructive) {
                        session.disconnect()
                        dismiss()
                    }
                }

                Section {
                    NavigationLink {
                        TTCustomHelpView()
                    } label: {
                        Label("Help and diagnostics guide", systemImage: "questionmark.circle")
                    }
                }
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

private struct TTCustomSettingsSlider: View {
    let title: String
    @Binding var value: Double
    var range: ClosedRange<Double> = 0...2
    var step: Double = 0.05
    var suffix = "%"
    var displayValue: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text(displayText)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Slider(value: $value, in: range, step: step)
                .accessibilityLabel(title)
                .accessibilityValue(displayText)
        }
    }

    private var displayText: String {
        let number = displayValue ?? value * 100
        return suffix == "%" ? "\(Int(number))%" : "\(Int(number))\(suffix)"
    }
}

struct TTCustomAudioControlsTab: View {
    @ObservedObject var session: TTCustomSession

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                GroupBox {
                    VStack(alignment: .leading, spacing: 14) {
                        Label("Transmit mix", systemImage: "waveform.and.mic")
                            .font(.headline)
                        TTCustomGainSlider(title: "Microphone", value: Binding(
                            get: { session.micGain }, set: { session.setMicGain($0) }
                        ))
                        if session.sharingSystemAudio {
                            TTCustomGainSlider(title: "System audio", value: Binding(
                                get: { session.systemAudioGain }, set: { session.setSystemAudioGain($0) }
                            ))
                        }
                        TTCustomGainSlider(title: "Output volume", value: Binding(
                            get: { session.outputVolume / 100 }, set: { session.setOutputVolume($0 * 100) }
                        ))
                        TTCustomGainSlider(title: "Master transmit", value: Binding(
                            get: { session.masterTransmitGain }, set: { session.setMasterTransmitGain($0) }
                        ))
                        Button {
                            session.flushAndRestartAudio()
                        } label: {
                            Label("Flush buffers and restart audio", systemImage: "arrow.clockwise.circle")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                    }
                }

                GroupBox {
                    VStack(alignment: .leading, spacing: 10) {
                        Label("Channel recording", systemImage: session.isRecordingChannel ? "record.circle.fill" : "record.circle")
                            .font(.headline)
                        Button {
                            session.toggleChannelRecording()
                        } label: {
                            Label(
                                session.isRecordingChannel ? "Stop recording" : "Start recording",
                                systemImage: session.isRecordingChannel ? "stop.circle.fill" : "record.circle.fill"
                            )
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(session.isRecordingChannel ? .red : .accentColor)
                        .accessibilityHint(session.isRecordingChannel ? "Save the current channel recording" : "Record the current TeamTalk channel")

                        if !session.channelRecordingStatus.isEmpty {
                            Text(session.channelRecordingStatus)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        if let recordingURL = session.channelRecordingURL, !session.isRecordingChannel {
                            ShareLink(item: recordingURL) {
                                Label("Share recording", systemImage: "square.and.arrow.up")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                }

                TTCustomDevicesControls(session: session)

                GroupBox {
                    VStack(alignment: .leading, spacing: 10) {
                        Label("Processing", systemImage: "waveform.badge.mic")
                            .font(.headline)
                        Toggle("Apple Voice Processing I/O", isOn: Binding(
                            get: { session.echoCancellation },
                            set: { session.setEchoCancellation($0) }
                        ))
                        Toggle("WebRTC echo cancellation", isOn: Binding(
                            get: { session.webrtcEchoCancellation },
                            set: { session.setWebRTCEchoCancellation($0) }
                        ))
                        Toggle("Automatic microphone gain", isOn: Binding(
                            get: { session.automaticGainControl },
                            set: { session.setAutomaticGainControl($0) }
                        ))
                        Toggle("Noise gate", isOn: Binding(
                            get: { session.noiseGateEnabled },
                            set: { session.setNoiseGateEnabled($0) }
                        ))
                        Toggle("Compressor", isOn: Binding(
                            get: { session.compressorEnabled },
                            set: { session.setCompressorEnabled($0) }
                        ))
                        Toggle("Peak limiter", isOn: Binding(
                            get: { session.limiterEnabled },
                            set: { session.setLimiterEnabled($0) }
                        ))
                    }
                }
                GroupBox {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Audio health", systemImage: "waveform.path.ecg")
                            .font(.headline)
                        TTCustomStatRow(title: "Input", value: session.audioHealth.inputRoute)
                        TTCustomStatRow(title: "Output", value: session.audioHealth.outputRoute)
                        TTCustomStatRow(title: "Sample rate", value: session.audioHealth.sampleRate > 0 ? "\(Int(session.audioHealth.sampleRate)) Hz" : "—")
                        TTCustomStatRow(title: "Actual I/O buffer", value: session.audioHealth.bufferDuration > 0 ? String(format: "%.1f ms", session.audioHealth.bufferDuration * 1000) : "—")
                        if session.audioHealth.mixerStats.active {
                            TTCustomStatRow(title: "Mic queued", value: "\(session.audioHealth.mixerStats.micFrames) frames")
                            TTCustomStatRow(title: "System queued", value: "\(session.audioHealth.mixerStats.systemFrames) frames")
                            TTCustomStatRow(title: "Dropped", value: "mic \(session.audioHealth.mixerStats.droppedMicFrames), system \(session.audioHealth.mixerStats.droppedSystemFrames)")
                            TTCustomStatRow(title: "Underruns", value: "mic \(session.audioHealth.mixerStats.micUnderruns), system \(session.audioHealth.mixerStats.systemUnderruns)")
                            TTCustomStatRow(title: "Late mixer blocks", value: "\(session.audioHealth.mixerStats.lateBlocks) (max \(String(format: "%.1f", session.audioHealth.mixerStats.maxLatenessMilliseconds)) ms)")
                            TTCustomStatRow(title: "Peak / RMS", value: String(format: "%.0f%% / %.0f%%", session.audioHealth.mixerStats.peak * 100, session.audioHealth.mixerStats.rms * 100))
                        } else {
                            TTCustomStatRow(title: "Custom mixer", value: "Inactive — system sharing is off")
                        }
                    }
                }
                GroupBox {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("How it works", systemImage: "info.circle")
                            .font(.headline)
                        Text("The microphone remains available while system sharing is active. Set either source to 0% to mute it, or use the buttons on Main to toggle the source completely.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                if session.audioHealth.maximumInputChannelCount > 0 || !session.audioHealth.microphoneSources.isEmpty {
                    GroupBox {
                        VStack(alignment: .leading, spacing: 8) {
                            Label("Microphone capabilities", systemImage: "mic.badge.waveform")
                                .font(.headline)
                            if session.audioHealth.maximumInputChannelCount > 0 {
                                TTCustomStatRow(
                                    title: "Input channels",
                                    value: "\(session.audioHealth.inputChannelCount) current / \(session.audioHealth.maximumInputChannelCount) maximum"
                                )
                            }
                            if !session.audioHealth.activeInputDataSourceName.isEmpty {
                                TTCustomStatRow(title: "Active source", value: session.audioHealth.activeInputDataSourceName)
                            }
                            ForEach(session.audioHealth.microphoneSources) { source in
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(source.name)
                                        .font(.subheadline.weight(.medium))
                                    Text([
                                        source.supportsStereo ? "Stereo supported" : "Stereo not reported",
                                        source.supportedPolarPatterns.isEmpty ? nil : "Polar patterns: \(source.supportedPolarPatterns.joined(separator: ", "))",
                                        source.selectedPolarPattern.map { "Selected: \($0)" }
                                    ].compactMap { $0 }.joined(separator: " • "))
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                                }
                                .accessibilityElement(children: .combine)
                                .padding(.vertical, 2)
                            }
                        }
                    }
                }
            }
            .padding()
        }
        .background(Color(uiColor: .systemGroupedBackground))
    }
}

private struct TTCustomGainSlider: View {
    let title: String
    @Binding var value: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(title)
                Spacer()
                Text("\(Int(value * 100))%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Slider(value: $value, in: 0...2, step: 0.05)
                .accessibilityLabel(title)
                .accessibilityValue("\(Int(value * 100)) percent")
        }
    }
}

private struct TTCustomStatRow: View {
    let title: String
    let value: String

    var body: some View {
        HStack {
            Text(title)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.caption.monospacedDigit())
        }
    }
}

@preconcurrency import TeamTalkKit
import AVFoundation
import AVKit
import ScreenCaptureKit
import MediaPlayer
import Foundation
import SwiftUI
import UIKit


private enum TTCustomChannelViewSection: String, CaseIterable, Identifiable {
    case channels = "Channels"
    case people = "People"

    var id: Self { self }
}

struct TTCustomMainAudioTab: View {
    @ObservedObject var session: TTCustomSession
    @State private var selectedUser: TTCustomRemoteUser?
    @State private var selectedSection: TTCustomChannelViewSection = .channels

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                TTCustomConnectionStabilityCard(session: session)

                Picker("Channel view", selection: $selectedSection) {
                    ForEach(TTCustomChannelViewSection.allCases) { section in
                        Text(section.rawValue).tag(section)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityLabel("Channel view")

                if selectedSection == .channels {
                    TTCustomChannelBrowser(session: session)
                } else {
                    GroupBox {
                        VStack(alignment: .leading, spacing: 12) {

                        Label("People and user actions", systemImage: "person.2.fill")
                            .font(.headline)
                        if session.remoteUsers.isEmpty {
                            Text("Nobody else is connected yet.")
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(session.remoteUsers) { user in
                                VStack(alignment: .leading, spacing: 5) {
                                    HStack {
                                        Text(user.name)
                                            .font(.body.weight(.medium))
                                        Spacer()
                                        VStack(alignment: .trailing, spacing: 2) {
                                            Text("\(Int(user.volume))%")
                                            if user.voicePacketsReceived + user.voicePacketsLost > 0 {
                                                Text(String(format: "%.1f%% loss", user.voicePacketLossPercent))
                                                    .foregroundStyle(user.voicePacketLossPercent > 3 ? .red : .secondary)
                                            }
                                        }
                                            .font(.caption.monospacedDigit())
                                            .foregroundStyle(.secondary)
                                TTCustomUserActionsMenu(user: user, session: session) {
                                    selectedUser = user
                                }
                                    }
                                    Slider(value: Binding(
                                        get: { session.remoteUsers.first(where: { $0.id == user.id })?.volume ?? user.volume },
                                        set: { session.setUserVolume($0, for: user.id) }
                                    ), in: 0...200, step: 5)
                                    .accessibilityLabel("Volume for \(user.name)")
                                }
                                if user.id != session.remoteUsers.last?.id { Divider() }
                            }
                        }
                        }
                    }
                }
            }
            .padding()
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .sheet(item: $selectedUser) { user in
            TTCustomUserDetailSheet(userID: user.id, session: session)
        }
    }
}

private struct TTCustomUserActionsMenu: View {
    let user: TTCustomRemoteUser
    @ObservedObject var session: TTCustomSession
    let onDetails: () -> Void

    private var destinations: [Channel] {
        session.serverChannels
            .filter { $0.nChannelID != session.client.myChannelID }
            .sorted { TeamTalkString.channel(.name, from: $0) < TeamTalkString.channel(.name, from: $1) }
    }

    var body: some View {
        Menu {
            Button {
                onDetails()
            } label: {
                Label("View details and stats", systemImage: "person.text.rectangle")
            }

            Button {
                session.toggleRemoteUserMute(user.id)
            } label: {
                Label(
                    session.mutedRemoteUserIDs.contains(user.id) ? "Unmute voice" : "Mute voice",
                    systemImage: session.mutedRemoteUserIDs.contains(user.id) ? "speaker.wave.2" : "speaker.slash"
                )
            }

            if session.canManageUsers && !destinations.isEmpty {
                Menu("Move to channel", systemImage: "arrow.right.circle") {
                    ForEach(destinations, id: \.nChannelID) { channel in
                        Button(TeamTalkString.channel(.name, from: channel)) {
                            session.moveUserFromBrowser(user.id, to: channel)
                        }
                    }
                }
            }

            if session.canKickUsers {
                Button(role: .destructive) {
                    session.kickRemoteUser(user.id)
                } label: {
                    Label("Kick from server", systemImage: "person.crop.circle.badge.xmark")
                }
            }

            if session.canBanUsers {
                Button(role: .destructive) {
                    session.banRemoteUser(user.id)
                } label: {
                    Label("Ban user", systemImage: "nosign")
                }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.title3)
        }
        .accessibilityLabel("Actions for \(user.name)")
        .accessibilityHint("Adjust volume, mute, move, kick, or ban this user")
    }
}

private struct TTCustomUserDetailSheet: View {
    let userID: Int32
    @ObservedObject var session: TTCustomSession
    @Environment(\.dismiss) private var dismiss
    @State private var volume: Double
    @State private var muted: Bool
    @State private var stereo: TTCustomStereoMode = .both
    @State private var playbackBuffer: Double
    @State private var fixedJitter: Double
    @State private var maximumJitter: Double
    @State private var adaptiveJitter: Bool
    @State private var message = ""

    init(userID: Int32, session: TTCustomSession) {
        self.userID = userID
        self.session = session
        let user = session.client.withUser(id: userID) { $0 }
        _volume = State(initialValue: ttCustomReferencePercent(Int(user.nVolumeVoice)))
        _muted = State(initialValue: (user.uUserState & USERSTATE_MUTE_VOICE.rawValue) != 0)
        _playbackBuffer = State(initialValue: Double(user.nBufferMSecVoice))
        _fixedJitter = State(initialValue: session.fixedJitterDelayMilliseconds)
        _maximumJitter = State(initialValue: session.maximumAdaptiveJitterDelayMilliseconds)
        _adaptiveJitter = State(initialValue: session.adaptiveJitterEnabled)
        if user.stereoPlaybackVoice.0 != 0 && user.stereoPlaybackVoice.1 == 0 {
            _stereo = State(initialValue: .left)
        } else if user.stereoPlaybackVoice.0 == 0 && user.stereoPlaybackVoice.1 != 0 {
            _stereo = State(initialValue: .right)
        }
    }

    private var user: User { session.client.withUser(id: userID) { $0 } }
    private var stats: TeamTalkUserNetworkStatistics { session.client.userNetworkStatistics(userID: userID) }
    private var canManageOperator: Bool { session.canManageOperators }

    var body: some View {
        NavigationStack {
            Form {
                Section("Identity") {
                    LabeledContent("Nickname", value: TeamTalkString.user(.nickname, from: user))
                    LabeledContent("Username", value: TeamTalkString.user(.username, from: user))
                    LabeledContent("User ID", value: "\(user.nUserID)")
                    LabeledContent("Version", value: String(format: "%u", user.uVersion))
                    LabeledContent("Channel", value: "\(user.nChannelID)")
                    if !TeamTalkString.user(.statusMessage, from: user).isEmpty {
                        LabeledContent("Status", value: TeamTalkString.user(.statusMessage, from: user))
                    }
                }

                Section("Voice statistics") {
                    LabeledContent("Packets received", value: "\(stats.voicePacketsReceived)")
                    LabeledContent("Packets lost", value: "\(stats.voicePacketsLost)")
                    let total = stats.voicePacketsReceived + stats.voicePacketsLost
                    LabeledContent("Packet loss", value: total > 0 ? String(format: "%.1f%%", Double(stats.voicePacketsLost) / Double(total) * 100) : "Not measured")
                    LabeledContent("Receive buffer", value: "\(user.nBufferMSecVoice) ms")
                    LabeledContent("Active adaptive jitter", value: "\(user.nActiveAdaptiveDelayMSec) ms")
                }

                Section("Playback") {
                    HStack {
                        Text("Voice volume")
                        Spacer()
                        Text("\(Int(volume.rounded()))%")
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: $volume, in: 0...200, step: 5)
                        .onChange(of: volume) { value in session.setUserVolume(value, for: userID) }
                    Toggle("Mute voice", isOn: $muted)
                        .onChange(of: muted) { value in
                            session.client.setUserMute(userID: userID, stream: STREAMTYPE_VOICE, muted: value)
                        }
                    Picker("Stereo routing", selection: $stereo) {
                        ForEach(TTCustomStereoMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .onChange(of: stereo) { value in session.setRemoteUserStereo(value, for: userID) }
                }

                Section("Per-user buffering") {
                    TTCustomSettingsSlider(title: "Playback buffer", value: Binding(
                        get: { playbackBuffer / 400 }, set: { playbackBuffer = $0 * 400 }
                    ), range: 0...1, step: 0.0125, suffix: " ms", displayValue: playbackBuffer)
                    TTCustomSettingsSlider(title: "Fixed jitter", value: Binding(
                        get: { fixedJitter / 400 }, set: { fixedJitter = $0 * 400 }
                    ), range: 0...1, step: 0.0125, suffix: " ms", displayValue: fixedJitter)
                    TTCustomSettingsSlider(title: "Maximum adaptive jitter", value: Binding(
                        get: { maximumJitter / 500 }, set: { maximumJitter = $0 * 500 }
                    ), range: 0...1, step: 0.01, suffix: " ms", displayValue: maximumJitter)
                    Toggle("Adaptive jitter", isOn: $adaptiveJitter)
                    Button("Apply buffering") {
                        session.setRemoteUserBuffer(playbackBuffer, for: userID)
                        session.setRemoteUserJitter(fixed: fixedJitter, adaptive: adaptiveJitter, maximum: maximumJitter, for: userID)
                    }
                }

                Section("Actions") {
                    if canManageOperator {
                        Toggle("Channel operator", isOn: Binding(
                            get: { session.client.isChannelOperator(userID: userID, channelID: session.client.myChannelID) },
                            set: { session.setRemoteUserOperator($0, userID: userID) }
                        ))
                    }
                    TextField("Message", text: $message, axis: .vertical)
                    Button("Send private message") {
                        session.sendPrivateMessage(message, to: userID)
                        message = ""
                    }
                    .disabled(message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .navigationTitle(TeamTalkString.user(.nickname, from: user).isEmpty ? "User details" : TeamTalkString.user(.nickname, from: user))
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

private struct TTCustomChannelBrowser: View {
    @ObservedObject var session: TTCustomSession
    @State private var passwordChannel: Channel?
    @State private var channelPassword = ""
    @State private var showingCreateChannel = false

    private var currentChannelID: Int32 { session.client.myChannelID }

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label("Channels", systemImage: "rectangle.3.group")
                        .font(.headline)
                    Spacer()
                    Button { session.refreshServerChannels() } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .accessibilityLabel("Refresh channels")
                    Button { showingCreateChannel = true } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("Create channel")
                }

                if session.serverChannels.isEmpty {
                    Text("No channel list is available yet.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(session.serverChannels.sorted { channelPath($0) < channelPath($1) }, id: \.nChannelID) { channel in
                        channelRow(channel)
                    }
                }

                if !session.channelActionStatus.isEmpty {
                    Text(session.channelActionStatus)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .alert("Join channel", isPresented: Binding(
            get: { passwordChannel != nil },
            set: { if !$0 { passwordChannel = nil } }
        )) {
            SecureField("Password", text: $channelPassword)
            Button("Join") {
                if let channel = passwordChannel {
                    session.joinChannelFromBrowser(channel, password: channelPassword)
                }
                passwordChannel = nil
                channelPassword = ""
            }
            Button("Cancel", role: .cancel) {
                passwordChannel = nil
                channelPassword = ""
            }
        } message: {
            Text("This channel requires a password.")
        }
        .sheet(isPresented: $showingCreateChannel) {
            TTCustomCreateChannelSheet(session: session)
        }
    }

    @ViewBuilder
    private func channelRow(_ channel: Channel) -> some View {
        let name = TeamTalkString.channel(.name, from: channel)
        let isCurrent = channel.nChannelID == currentChannelID
        let hasPassword = channel.bPassword != 0
        HStack(spacing: 8) {
            Image(systemName: isCurrent ? "checkmark.circle.fill" : "bubble.left.and.bubble.right")
                .foregroundStyle(isCurrent ? .green : .secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(name.isEmpty ? "Unnamed channel" : name)
                    .font(.body.weight(isCurrent ? .semibold : .regular))
                Text("\(session.client.channelUsers(id: channel.nChannelID).count) users\(hasPassword ? " • Password protected" : "")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if !isCurrent {
                Button("Join") {
                    if hasPassword { passwordChannel = channel }
                    else { session.joinChannelFromBrowser(channel) }
                }
                .buttonStyle(.bordered)
                .accessibilityHidden(true)
            } else {
                Text("Current")
                    .font(.caption)
                    .foregroundStyle(.green)
            }
        }
        .padding(.leading, CGFloat(channelDepth(channel) * 18))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(name.isEmpty ? "Unnamed channel" : name), \(session.client.channelUsers(id: channel.nChannelID).count) users\(hasPassword ? ", password protected" : "")\(isCurrent ? ", current channel" : "")"
        )
        .accessibilityHint(isCurrent ? "Current channel" : "Double tap to join this channel")
        .accessibilityAction(named: "Join channel") {
            guard !isCurrent else { return }
            if hasPassword { passwordChannel = channel }
            else { session.joinChannelFromBrowser(channel) }
        }
        .contextMenu {
            if session.canManageUsers {
                ForEach(session.remoteUsers) { user in
                    Menu("Move \(user.name)") {
                        ForEach(session.serverChannels.filter { $0.nChannelID != currentChannelID }, id: \.nChannelID) { destination in
                            Button(TeamTalkString.channel(.name, from: destination)) {
                                session.moveUserFromBrowser(user.id, to: destination)
                            }
                        }
                    }
                }
            }
        }
    }

    private func channelDepth(_ channel: Channel) -> Int {
        var depth = 0
        var parentID = channel.nParentID
        var visited = Set<Int32>()
        while parentID != 0 && !visited.contains(parentID) {
            visited.insert(parentID)
            depth += 1
            guard let parent = session.serverChannels.first(where: { $0.nChannelID == parentID }) else { break }
            parentID = parent.nParentID
        }
        return depth
    }

    private func channelPath(_ channel: Channel) -> String {
        String(repeating: " ", count: channelDepth(channel) * 2) + TeamTalkString.channel(.name, from: channel)
    }
}

private struct TTCustomCreateChannelSheet: View {
    @ObservedObject var session: TTCustomSession
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var password = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Channel") {
                    TextField("Name", text: $name)
                    SecureField("Password (optional)", text: $password)
                }
                Section {
                    Button("Create") {
                        session.createChannel(name: name, password: password, parentID: session.client.myChannelID)
                        dismiss()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .navigationTitle("Create channel")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}

private struct TTCustomAudioSourceButton: View {
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

struct TTCustomDevicesTab: View {
    @ObservedObject var session: TTCustomSession

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                GroupBox {
                    VStack(alignment: .leading, spacing: 12) {
                        Label("Devices", systemImage: "hifispeaker.2.fill")
                            .font(.headline)
                        HStack(alignment: .top, spacing: 12) {
                            VStack(alignment: .leading, spacing: 6) {
                                Label("Microphone", systemImage: "mic")
                                    .font(.subheadline.weight(.medium))
                                    .accessibilityHidden(true)
                                Picker("Microphone", selection: Binding(
                                    get: {
                                        guard let input = session.availableInputs.first(where: { $0.id == session.selectedInputID }) else { return "" }
                                        let source = input.dataSources.first(where: { $0.id == session.selectedInputDataSourceID })
                                        return session.inputSelectionID(for: input, source: source)
                                    },
                                    set: { session.selectInputSelection($0) }
                                )) {
                                    ForEach(session.availableInputs) { input in
                                        if input.dataSources.isEmpty {
                                            Text(input.name).tag(session.inputSelectionID(for: input, source: nil))
                                        } else {
                                            ForEach(input.dataSources) { source in
                                                Text("\(input.name) — \(source.name)")
                                                    .tag(session.inputSelectionID(for: input, source: source))
                                            }
                                        }
                                    }
                                }
                                .pickerStyle(.menu)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)

                            VStack(alignment: .leading, spacing: 6) {
                                Label("Speaker", systemImage: "speaker.wave.2")
                                    .font(.subheadline.weight(.medium))
                                    .accessibilityHidden(true)
                                Picker("Speaker", selection: Binding(
                                    get: { session.selectedOutputID },
                                    set: { session.selectOutput($0) }
                                )) {
                                    ForEach(session.availableOutputs) { output in
                                        Text(output.name).tag(output.id)
                                    }
                                }
                                .pickerStyle(.menu)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        Text("Active output: \(session.actualOutputID ?? "Unknown")")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        AVRoutePicker()
                            .frame(height: 44)
                    }
                }

            }
            .padding()
        }
        .background(Color(uiColor: .systemGroupedBackground))
    }
}

private struct TTCustomDevicesControls: View {
    @ObservedObject var session: TTCustomSession

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Label("Devices", systemImage: "hifispeaker.2.fill")
                    .font(.headline)
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("Microphone", systemImage: "mic")
                            .font(.subheadline.weight(.medium))
                            .accessibilityHidden(true)
                        Picker("Microphone", selection: Binding(
                            get: {
                                guard let input = session.availableInputs.first(where: { $0.id == session.selectedInputID }) else { return "" }
                                let source = input.dataSources.first(where: { $0.id == session.selectedInputDataSourceID })
                                return session.inputSelectionID(for: input, source: source)
                            },
                            set: { session.selectInputSelection($0) }
                        )) {
                            ForEach(session.availableInputs) { input in
                                if input.dataSources.isEmpty {
                                    Text(input.name).tag(session.inputSelectionID(for: input, source: nil))
                                } else {
                                    ForEach(input.dataSources) { source in
                                        Text("\(input.name) — \(source.name)")
                                            .tag(session.inputSelectionID(for: input, source: source))
                                    }
                                }
                            }
                        }
                        .pickerStyle(.menu)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    VStack(alignment: .leading, spacing: 6) {
                        Label("Speaker", systemImage: "speaker.wave.2")
                            .font(.subheadline.weight(.medium))
                            .accessibilityHidden(true)
                        Picker("Speaker", selection: Binding(
                            get: { session.selectedOutputID },
                            set: { session.selectOutput($0) }
                        )) {
                            ForEach(session.availableOutputs) { output in
                                Text(output.name).tag(output.id)
                            }
                        }
                        .pickerStyle(.menu)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                Text("Active output: \(session.actualOutputID ?? "Unknown")")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                AVRoutePicker()
                    .frame(height: 44)
            }
        }
    }
}

struct TTCustomNetworkTab: View {
    @ObservedObject var session: TTCustomSession

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                GroupBox {
                    VStack(alignment: .leading, spacing: 12) {
                        Label("Latency", systemImage: "gauge.with.dots.needle.67percent")
                            .font(.headline)
                        Picker("Latency preset", selection: Binding(
                            get: { session.latencyPreset },
                            set: { session.applyLatencyPreset($0) }
                        )) {
                            ForEach(TTCustomLatencyPreset.allCases) { preset in
                                Text(preset.title).tag(preset)
                            }
                        }
                        .pickerStyle(.segmented)
                        HStack(alignment: .bottom, spacing: 20) {
                            TTCustomVerticalLatencySlider(
                                title: "I/O buffer",
                                value: Binding(
                                    get: { session.inputBufferMilliseconds },
                                    set: { session.setInputBuffer($0) }
                                ), range: 5...100, step: 5
                            )
                            TTCustomVerticalLatencySlider(
                                title: "Voice playout buffer",
                                value: Binding(
                                    get: { session.voicePlayoutBufferMilliseconds },
                                    set: { session.setVoicePlayoutBuffer($0) }
                                ), range: 0...300, step: 5
                            )
                            TTCustomVerticalLatencySlider(
                                title: "Fixed jitter delay",
                                value: Binding(
                                    get: { session.fixedJitterDelayMilliseconds },
                                    set: { session.setFixedJitterDelay($0) }
                                ), range: 0...300, step: 5
                            )
                            TTCustomVerticalLatencySlider(
                                title: "Max adaptive jitter",
                                value: Binding(
                                    get: { session.maximumAdaptiveJitterDelayMilliseconds },
                                    set: { session.setMaximumAdaptiveJitterDelay($0) }
                                ), range: 0...400, step: 5
                            )
                        }
                        .frame(maxWidth: .infinity)
                        Toggle("Adaptive jitter buffering", isOn: Binding(
                            get: { session.adaptiveJitterEnabled },
                            set: { session.setAdaptiveJitterEnabled($0) }
                        ))
                        Button {
                            session.restartRemoteAudioStreams()
                        } label: {
                            Label("Apply playback settings", systemImage: "arrow.clockwise.circle")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        Text("Lower values reduce delay; higher values tolerate jitter.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                GroupBox {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Connection", systemImage: "network")
                            .font(.headline)
                        TTCustomStatRow(title: "Status", value: session.status)
                        TTCustomStatRow(title: "Server", value: session.host)
                        TTCustomStatRow(title: "Input underruns", value: "\(session.audioHealth.mixerStats.micUnderruns)")
                        TTCustomStatRow(title: "System underruns", value: "\(session.audioHealth.mixerStats.systemUnderruns)")
                        TTCustomStatRow(title: "Mic dropped", value: "\(session.audioHealth.mixerStats.droppedMicFrames) frames")
                        TTCustomStatRow(title: "System dropped", value: "\(session.audioHealth.mixerStats.droppedSystemFrames) frames")
                        TTCustomStatRow(title: "Mic recoveries", value: "\(session.audioHealth.mixerStats.micRecoveryEvents)")
                        TTCustomStatRow(title: "System recoveries", value: "\(session.audioHealth.mixerStats.systemRecoveryEvents)")
                        TTCustomStatRow(title: "Input queue", value: String(format: "%.0f%%", session.audioHealth.mixerStats.micFillPercent))
                        TTCustomStatRow(title: "System queue", value: String(format: "%.0f%%", session.audioHealth.mixerStats.systemFillPercent))
                        TTCustomStatRow(title: "Late mixer blocks", value: "\(session.audioHealth.mixerStats.lateBlocks)")
                        TTCustomStatRow(title: "UDP ping", value: session.networkHealth.statisticsAvailable && session.networkHealth.udpPingMilliseconds >= 0 ? "\(session.networkHealth.udpPingMilliseconds) ms" : "Not measured")
                        TTCustomStatRow(title: "TCP ping", value: session.networkHealth.statisticsAvailable && session.networkHealth.tcpPingMilliseconds >= 0 ? "\(session.networkHealth.tcpPingMilliseconds) ms" : "Not measured")
                        TTCustomStatRow(title: "Voice UDP traffic", value: session.networkHealth.voiceTrafficObserved ? "Observed" : "Not observed")
                        TTCustomStatRow(title: "Voice bytes sent", value: "\(session.networkHealth.voiceBytesSent)")
                        TTCustomStatRow(title: "Voice bytes received", value: "\(session.networkHealth.voiceBytesReceived)")
                        TTCustomStatRow(title: "UDP silence", value: session.networkHealth.statisticsAvailable ? "\(session.networkHealth.udpServerSilenceSeconds) s since any server UDP traffic" : "Not measured")
                        TTCustomStatRow(title: "Input startup delay", value: session.networkHealth.statisticsAvailable && session.networkHealth.soundInputDelayMilliseconds > 0 ? "\(session.networkHealth.soundInputDelayMilliseconds) ms" : "Not measured")
                        TTCustomStatRow(title: "Reconnects", value: "\(session.networkHealth.reconnectCount)")
                    }
                }

                NavigationLink {
                    TTCustomHelpView()
                } label: {
                    Label("Help and diagnostics guide", systemImage: "questionmark.circle")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.bordered)

                HStack {
                    Button("Reconnect") { session.reconnect() }
                        .frame(maxWidth: .infinity)
                    ShareLink(item: session.diagnosticsText()) {
                        Label("Share diagnostics", systemImage: "square.and.arrow.up")
                            .frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.bordered)

                Button("Disconnect", role: .destructive) { session.disconnect() }
                    .frame(maxWidth: .infinity)
            }
            .padding()
        }
        .background(Color(uiColor: .systemGroupedBackground))
    }
}

private struct TTCustomChannelAudioControls: View {
    @ObservedObject var session: TTCustomSession
    @State private var isExpanded = false

    private let bitrates = [16.0, 24, 32, 48, 64, 96, 128]
    private let sampleRates = [8000.0, 12000, 16000, 24000, 48000]
    private let frameSizes = [5.0, 10, 20, 40, 60]

    var body: some View {
        GroupBox {
            DisclosureGroup(isExpanded: $isExpanded) {
                VStack(alignment: .leading, spacing: 12) {
                    if session.channelAudio.codec == OPUS_CODEC {
                        TTCustomDiscreteSlider(title: "Bitrate", value: binding(\TTCustomChannelAudioSettings.opusBitrate), choices: bitrates, suffix: " kbps")
                        TTCustomDiscreteSlider(title: "Sample rate", value: binding(\TTCustomChannelAudioSettings.opusSampleRate), choices: sampleRates, suffix: " Hz")
                        TTCustomDiscreteSlider(title: "Frame size", value: binding(\TTCustomChannelAudioSettings.opusFrameSize), choices: frameSizes, suffix: " ms")
                        TTCustomDiscreteSlider(title: "Transmit interval", value: binding(\TTCustomChannelAudioSettings.opusTransmitInterval), choices: frameSizes, suffix: " ms")
                        Picker("Channels", selection: Binding(
                            get: { session.channelAudio.opusChannels },
                            set: { session.channelAudio.opusChannels = $0 }
                        )) {
                            Text("Mono").tag(1)
                            Text("Stereo").tag(2)
                        }
                        .pickerStyle(.segmented)
                        Toggle("Variable bitrate", isOn: binding(\TTCustomChannelAudioSettings.opusVBR))
                        Toggle("Constrained variable bitrate", isOn: binding(\TTCustomChannelAudioSettings.opusConstrainedVBR))
                        Toggle("Forward error correction", isOn: binding(\TTCustomChannelAudioSettings.opusFEC))
                        Toggle("Discontinuous transmission", isOn: binding(\TTCustomChannelAudioSettings.opusDTX))
                        if session.channelAudio.isChannelOperator {
                            Button("Apply channel audio settings") {
                                session.updateChannelAudio()
                            }
                            .buttonStyle(.borderedProminent)
                            if !session.channelAudioStatus.isEmpty {
                                Text(session.channelAudioStatus)
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        } else {
                            Text("Only a channel operator can change these settings.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        Text("This client currently edits Opus channel settings only.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                .disabled(!session.channelAudio.isChannelOperator)
            } label: {
                HStack {
                    Label("Channel audio", systemImage: "waveform")
                        .font(.headline)
                    Spacer()
                    Text("\(Int(session.channelAudio.opusBitrate)) kbps")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func binding(_ keyPath: WritableKeyPath<TTCustomChannelAudioSettings, Double>) -> Binding<Double> {
        Binding(
            get: { session.channelAudio[keyPath: keyPath] },
            set: { session.channelAudio[keyPath: keyPath] = $0 }
        )
    }

    private func binding(_ keyPath: WritableKeyPath<TTCustomChannelAudioSettings, Bool>) -> Binding<Bool> {
        Binding(
            get: { session.channelAudio[keyPath: keyPath] },
            set: { session.channelAudio[keyPath: keyPath] = $0 }
        )
    }
}

private struct TTCustomDiscreteSlider: View {
    let title: String
    @Binding var value: Double
    let choices: [Double]
    let suffix: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text("\(Int(value))\(suffix)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Slider(value: indexBinding, in: 0...Double(max(0, choices.count - 1)), step: 1)
        }
    }

    private var indexBinding: Binding<Double> {
        Binding(
            get: {
                Double(choices.enumerated().min(by: { abs($0.element - value) < abs($1.element - value) })?.offset ?? 0)
            },
            set: { newIndex in
                let index = min(max(Int(newIndex.rounded()), 0), max(0, choices.count - 1))
                if choices.indices.contains(index) { value = choices[index] }
            }
        )
    }
}

struct TTCustomVerticalLatencySlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double

    var body: some View {
        VStack(spacing: 8) {
            Text(title)
                .font(.subheadline.weight(.medium))
                .multilineTextAlignment(.center)
            Text("\(Int(value)) ms")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            Slider(value: $value, in: range, step: step)
                .frame(width: 44, height: 190)
                .rotationEffect(.degrees(-90))
                .frame(width: 44, height: 190)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title)
        .accessibilityValue("\(Int(value)) milliseconds")
    }
}

struct AVRoutePicker: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let picker = AVRoutePickerView()
        picker.prioritizesVideoDevices = false
        return picker
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}

private struct TTCustomConnectionStabilityCard: View {
    @ObservedObject var session: TTCustomSession

    private var state: (title: String, detail: String, color: Color, symbol: String) {
        switch session.connectionLifecycle.phase {
        case .joined:
            if session.networkHealth.statisticsAvailable && session.networkHealth.udpServerSilenceSeconds >= 5 && !session.networkHealth.voiceTrafficObserved {
                return ("Poor", "The server has not sent UDP traffic recently.", .red, "exclamationmark.triangle.fill")
            }
            if session.networkHealth.statisticsAvailable && session.networkHealth.udpPingMilliseconds > 250 {
                return ("Degraded", "UDP response time is high.", .orange, "exclamationmark.circle.fill")
            }
            let ping = session.networkHealth.udpPingMilliseconds >= 0
                ? "UDP response time is \(session.networkHealth.udpPingMilliseconds) milliseconds."
                : "Connected and joined to the channel."
            return ("Stable", ping, .green, "checkmark.circle.fill")
        case .connecting, .connected, .loggingIn, .joiningRoot:
            return ("Connecting", "The connection is still being established.", .orange, "arrow.triangle.2.circlepath")
        case .failed:
            return ("Poor", "The connection reported an error or was lost.", .red, "exclamationmark.triangle.fill")
        case .disconnected:
            return ("Offline", "The app is not connected to a server.", .secondary, "wifi.slash")
        }
    }

    var body: some View {
        GroupBox {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: state.symbol)
                    .foregroundStyle(state.color)
                    .font(.title3)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Connection stability")
                        .font(.headline)
                    Text(state.title)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(state.color)
                    Text(state.detail)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Connection stability: \(state.title)")
        .accessibilityValue(state.detail)
        .accessibilityHint("Open the Network tab for detailed connection statistics.")
    }
}

struct TTCustomHelpView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                TTCustomHelpIntro()

                TTCustomHelpSection(title: "Audio levels", symbol: "waveform") {
                    TTCustomHelpTopic(title: "Decibels (dB)", text: "A decibel is a logarithmic way to describe signal level. In digital audio, 0 dBFS is the loudest signal the app can represent. Normal peaks are below zero: around -18 dBFS is conservative, -6 dBFS is a healthy speech peak, and levels near 0 dBFS are close to clipping. The percentage on a volume slider is gain applied by the app; it is not the same measurement as dBFS.")
                    TTCustomHelpTopic(title: "Peak", text: "Peak is the loudest instantaneous part of the signal. It helps identify sudden loud sounds and clipping risk. If peaks repeatedly reach 0 dBFS, lower the source or master transmit level.")
                    TTCustomHelpTopic(title: "RMS", text: "RMS estimates the average energy of the signal and is closer to perceived loudness than peak. Speech can have peaks near -6 dBFS while its average level is much lower. High RMS with little difference between average and peak level can indicate heavy compression.")
                    TTCustomHelpTopic(title: "Clipping", text: "Clipping occurs when a signal exceeds the maximum digital level and its waveform is cut off. It sounds like crackling, fuzz, or harsh distortion. Lower the source level or master transmit level; increasing volume after clipping cannot restore the lost detail.")
                }

                TTCustomHelpSection(title: "Connection quality", symbol: "network") {
                    TTCustomHelpTopic(title: "Round-trip latency", text: "Round-trip latency is the approximate time for data to travel to the server and back. Under 100 milliseconds usually feels comfortable, 100–200 milliseconds is noticeable but usable, and above 400 milliseconds makes natural conversation difficult. Actual voice delay also includes capture, codec, server, receive-buffer, and playback time.")
                    TTCustomHelpTopic(title: "Jitter", text: "Jitter is variation in packet arrival time. A connection can have a reasonable average latency but still sound uneven if individual packets arrive late. Under 10 milliseconds is very stable; 30–60 milliseconds may require more buffering.")
                    TTCustomHelpTopic(title: "Packet loss", text: "Packet loss means some network packets never arrive. Under 1 percent is usually acceptable for voice. Above 3 percent, dropouts and broken-up speech become increasingly likely. A late voice packet can be almost as disruptive as a missing packet.")
                    TTCustomHelpTopic(title: "Reconnect count", text: "Reconnect count records how often the app has had to reconnect during the current session. Increasing counts may indicate weak coverage, network switching, VPN instability, server availability problems, or app suspension.")
                }

                TTCustomHelpSection(title: "Buffers and timing", symbol: "gauge.with.dots.needle.67percent") {
                    TTCustomHelpTopic(title: "Receive buffer", text: "The receive buffer stores incoming audio before playback. A smaller buffer reduces delay but has less protection against jitter. A larger buffer smooths an unstable connection but adds delay.")
                    TTCustomHelpTopic(title: "I/O buffer", text: "The I/O buffer is the amount of audio processed by the phone at a time. Smaller values reduce local delay. Larger values reduce timing pressure and can prevent crackles, but may increase delay.")
                    TTCustomHelpTopic(title: "Underruns", text: "An underrun happens when the audio system needs samples but the app has not supplied them in time. It may cause clicks, popping, brief silence, or choppy playback. Possible causes include a buffer that is too small, CPU pressure, or an audio route change.")
                    TTCustomHelpTopic(title: "Overruns", text: "An overrun happens when audio arrives faster than the app can consume it. It can cause dropped audio, bursts, or growing delay. It may indicate that a capture source, mixer, or route is not being serviced consistently.")
                    TTCustomHelpTopic(title: "Late mixer blocks", text: "This counts mixer blocks that missed their intended scheduling deadline. A few isolated late blocks may not matter. A steadily increasing count suggests that the app is struggling to process or deliver audio on time.")
                }

                TTCustomHelpSection(title: "Devices and audio formats", symbol: "hifispeaker.2") {
                    TTCustomHelpTopic(title: "Sample rate", text: "Sample rate is the number of audio samples captured or played each second. 16 kHz is common for voice, while 44.1 and 48 kHz are common for music and modern media. A higher sample rate does not automatically mean better voice quality; the microphone, codec, network, and processing chain all matter.")
                    TTCustomHelpTopic(title: "Channels", text: "Mono uses one audio channel and is usually appropriate for speech. Stereo uses left and right channels and can be useful for system audio or music, but it uses more bandwidth and may not improve conversation.")
                    TTCustomHelpTopic(title: "Current route", text: "The current route is the physical path actually used by iOS, such as the iPhone microphone, AirPods microphone, built-in speaker, or Bluetooth output. The selected device and active route can temporarily differ during interruptions or route changes.")
                    TTCustomHelpTopic(title: "Voice Processing I/O", text: "Voice Processing I/O is Apple's two-way voice mode. It can provide echo cancellation, noise reduction, and automatic gain behavior. It may also alter music or system audio, so the app shows when it is active.")
                }

                TTCustomHelpSection(title: "Troubleshooting", symbol: "wrench.and.screwdriver") {
                    TTCustomHelpTopic(title: "People sound delayed", text: "Check round-trip latency first, then receive buffer size. If the network is stable, reduce the receive buffer. If latency varies, a slightly larger buffer may sound better even though it adds delay.")
                    TTCustomHelpTopic(title: "Audio breaks up", text: "Check packet loss, jitter, underruns, and I/O buffer size. If packet loss is high, the network is the likely cause. If packet loss is low but underruns rise, increase the I/O buffer or close competing apps.")
                    TTCustomHelpTopic(title: "Audio sounds distorted", text: "Check peak level and the clipping indicator. Lower the individual source level or master transmit level. Also check whether a compressor, limiter, or automatic gain control is changing the signal more than expected.")
                    TTCustomHelpTopic(title: "Voice changes volume", text: "Check automatic gain control, echo cancellation, compression, and the Bluetooth microphone. These systems may adjust gain in response to speech, noise, or feedback. A source that clips before processing cannot be repaired by later controls.")
                    TTCustomHelpTopic(title: "The wrong speaker is active", text: "Compare the selected output with the actual route. Check for an active phone call or interruption, then use the native route picker. TT Custom does not intentionally switch routes merely because the app opens.")
                }

                Text("The diagnostics shown by TT Custom describe the current session. They are clues, not a single score: a stable connection can still have a poor audio route, and a perfect route can still be affected by network loss.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding()
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle("Help and diagnostics")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct TTCustomHelpIntro: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Understanding TT Custom", systemImage: "questionmark.circle.fill")
                .font(.title3.weight(.semibold))
            Text("Most problems fall into three categories: connection quality, audio timing, or audio level. You do not need to understand every number to use the app, but this guide explains what each one means and what to try when something sounds wrong.")
                .foregroundStyle(.secondary)
            Text("If you only remember three things: high latency makes conversations feel delayed, packet loss and jitter cause dropouts, and clipping means the audio is too loud and is being distorted.")
                .font(.callout.weight(.medium))
        }
        .accessibilityElement(children: .combine)
    }
}

private struct TTCustomHelpSection<Content: View>: View {
    let title: String
    let symbol: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: symbol)
                .font(.headline)
            content()
        }
    }
}

private struct TTCustomHelpTopic: View {
    let title: String
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.body.weight(.semibold))
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

