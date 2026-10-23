@preconcurrency import TeamTalkKit
import TeamTalkC
import AVFoundation
import Foundation
import SwiftUI

final class TTCustomMessageMailbox: @unchecked Sendable {
    private let lock = NSLock()
    private var messages: [TTMessage] = []
    private var drainScheduled = false

    func enqueue(_ message: TTMessage) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        messages.append(message)
        guard !drainScheduled else { return false }
        drainScheduled = true
        return true
    }

    func drain() -> [TTMessage] {
        lock.lock()
        defer { lock.unlock() }
        let result = messages
        messages.removeAll(keepingCapacity: true)
        drainScheduled = false
        return result
    }
}

@MainActor
final class TTCustomSession: NSObject, ObservableObject, TeamTalkMessageObserver {
    @Published var host = UserDefaults.standard.string(forKey: "ttcustom.host") ?? "relay"
    @Published var tcpPort = UserDefaults.standard.string(forKey: "ttcustom.tcp") ?? "10333"
    @Published var udpPort = UserDefaults.standard.string(forKey: "ttcustom.udp") ?? "10333"
    @Published var username = UserDefaults.standard.string(forKey: "ttcustom.username") ?? "derrick"
    @Published var password = TTCustomKeychain.load(
        host: UserDefaults.standard.string(forKey: "ttcustom.host") ?? "relay",
        username: UserDefaults.standard.string(forKey: "ttcustom.username") ?? "derrick"
    )
    @Published var nickname = UserDefaults.standard.string(forKey: "ttcustom.nickname") ?? "derricks-iphone"
    @Published var status = "Not connected"
    @Published var connected = false
    @Published var transmitting = false
    // CallKit must be activated before the TeamTalk audio unit is opened.
    // Keep it opt-in until that handoff is explicitly requested; enabling it
    // by default can cause iOS to renegotiate an already-running route.
    @Published var systemCallControlsEnabled = UserDefaults.standard.object(forKey: "ttcustom.systemCallControls") as? Bool ?? false
    @Published var sharingSystemAudio = false
    @Published var systemAudioMuted = false
    @Published var isRecordingChannel = false
    @Published var channelRecordingURL: URL?
    @Published var channelRecordingStatus = ""
    @Published var micGain: Double = UserDefaults.standard.object(forKey: "ttcustom.micGain") as? Double ?? 1.0
    @Published var systemAudioGain: Double = UserDefaults.standard.object(forKey: "ttcustom.systemAudioGain") as? Double ?? 1.0
    @Published var masterTransmitGain: Double = UserDefaults.standard.object(forKey: "ttcustom.masterTransmitGain") as? Double ?? 1.0
    @Published var outputVolume: Double = UserDefaults.standard.object(forKey: "ttcustom.outputVolume") as? Double ?? 100
    @Published var echoCancellation: Bool = UserDefaults.standard.object(forKey: "ttcustom.echoCancellation") as? Bool ?? true
    @Published var webrtcEchoCancellation: Bool = UserDefaults.standard.object(forKey: "ttcustom.webrtcEchoCancellation") as? Bool ?? true
    @Published var automaticGainControl = UserDefaults.standard.object(forKey: "ttcustom.automaticGainControl") as? Bool ?? true
    @Published var noiseGateEnabled = UserDefaults.standard.bool(forKey: "ttcustom.noiseGate")
    @Published var compressorEnabled = UserDefaults.standard.bool(forKey: "ttcustom.compressor")
    @Published var limiterEnabled = UserDefaults.standard.object(forKey: "ttcustom.limiter") as? Bool ?? true
    @Published var audioHealth = TTCustomAudioHealth()
    @Published var networkHealth = TTCustomNetworkHealth()
    @Published var inputBufferMilliseconds: Double = UserDefaults.standard.object(forKey: "ttcustom.inputBufferMS") as? Double ?? 20
    @Published var voicePlayoutBufferMilliseconds: Double = UserDefaults.standard.object(forKey: "ttcustom.receiveBufferMS") as? Double ?? 80
    @Published var fixedJitterDelayMilliseconds: Double = UserDefaults.standard.object(forKey: "ttcustom.fixedJitterMS") as? Double ?? 80
    @Published var adaptiveJitterEnabled: Bool = UserDefaults.standard.object(forKey: "ttcustom.adaptiveJitter") as? Bool ?? true
    @Published var maximumAdaptiveJitterDelayMilliseconds: Double = UserDefaults.standard.object(forKey: "ttcustom.maxAdaptiveJitterMS") as? Double ?? 160
    @Published var channelAudio = TTCustomChannelAudioSettings()
    @Published var channelAudioStatus = ""
    @Published var availableInputs: [TTCustomInput] = []
    @Published var availableOutputs: [TTCustomOutput] = []
    @Published var remoteUsers: [TTCustomRemoteUser] = []
    @Published var mutedRemoteUserIDs = Set<Int32>()
    @Published var serverChannels: [Channel] = []
    @Published var channelActionStatus = ""
    @Published var selectedInputID: String? = UserDefaults.standard.string(forKey: "ttcustom.inputID")
    @Published var selectedOutputID = UserDefaults.standard.string(forKey: "ttcustom.outputID") ?? "speaker"
    @Published var actualOutputID: String?
    @Published var latencyPreset: TTCustomLatencyPreset = TTCustomLatencyPreset(rawValue: UserDefaults.standard.string(forKey: "ttcustom.latencyPreset") ?? "balanced") ?? .balanced

    let client = TeamTalkClient.shared
    var pollTimer: DispatchSourceTimer?
    var connectionTimeoutWorkItem: DispatchWorkItem?
    var connectionRetryWorkItem: DispatchWorkItem?
    var rootJoinWorkItem: DispatchWorkItem?
    var connectionAttempt = 0
    var connectionGeneration: UInt64 = 0
    let retryPolicy = TTCustomRetryPolicy()
    var connectionLifecycle = TTCustomConnectionLifecycle()
    var joinedUserIDs = Set<Int32>()
    var loginCommandID: Int32?
    var joinCommandID: Int32?
    var pendingJoinChannelName: String?
    var pendingJoinIsRoot = false
    var channelCreationCommandID: Int32?
    var subscriptionCommandIDs = Set<Int32>()
    var channelAudioCommandID: Int32?
    var loggedIn = false
    var didRequestRootJoin = false
    var audioConfigured = false
    var speakerRouteWorkItem: DispatchWorkItem?
    var speakerRouteAttempts = 0
    var audioMixer: TTCustomAudioMixer?
    var appleAudioPipeline: TTCustomAppleAudioPipeline?
    var systemAudioCapture: AnyObject?
    var audioStatsTimer: Timer?
    var routeReconfigureWorkItem: DispatchWorkItem?
    var lastDiagnosticsPing = Date.distantPast
    var networkStatsRefreshInFlight = false
    // A previously selected output is an explicit user preference even when
    // the app has just relaunched. Without restoring this flag, the picker
    // could show Speaker while the session still defaulted to the receiver.
    // Speaker is the safe default for a voice client. A persisted picker
    // choice remains authoritative, but a first launch must not fall back to
    // the iPhone receiver/earpiece.
    var hasExplicitOutputSelection = true
    var audioPhase: TTCustomAudioPhase = .idle
    var callCoordinator: TTCustomCallCoordinator!
    nonisolated let messageMailbox = TTCustomMessageMailbox()

    override init() {
        super.init()
        callCoordinator = TTCustomCallCoordinator(session: self)
        client.addObserver(self)
        refreshRoutes()
        // Route discovery is intentionally passive at launch. Activating or
        // reconfiguring AVAudioSession here can move VoiceOver or AirPods.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(routeChanged),
            name: AVAudioSession.routeChangeNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(audioSessionInterrupted(_:)),
            name: AVAudioSession.interruptionNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(audioServicesReset),
            name: AVAudioSession.mediaServicesWereResetNotification,
            object: nil
        )
        audioStatsTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshAudioStats()
            }
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        pollTimer?.setEventHandler {}
        pollTimer?.cancel()
        audioStatsTimer?.invalidate()
        routeReconfigureWorkItem?.cancel()
        speakerRouteWorkItem?.cancel()
        connectionTimeoutWorkItem?.cancel()
        connectionRetryWorkItem?.cancel()
        rootJoinWorkItem?.cancel()
        client.removeObserver(self)
        callCoordinator = nil
    }

    func setUserVolume(_ value: Double, for userID: Int32) {
        guard let index = remoteUsers.firstIndex(where: { $0.id == userID }) else { return }
        let volume = min(200, max(0, value))
        let user = remoteUsers[index]
        remoteUsers[index].volume = volume
        UserDefaults.standard.set(volume, forKey: userVolumeKey(for: user.accountName))
        client.setUserVolume(userID: userID, stream: STREAMTYPE_VOICE, volume: Int32(ttCustomReferenceVolume(volume)))
    }

    func toggleChannelRecording() {
        if isRecordingChannel {
            stopChannelRecording()
        } else {
            startChannelRecording()
        }
    }

    private func startChannelRecording() {
        let channelID = client.myChannelID
        guard channelID > 0 else {
            channelRecordingStatus = "Join a channel before recording"
            return
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let filename = "TT-Custom-\(formatter.string(from: Date())).wav"
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(filename)

        guard client.startChannelRecording(channelID: channelID, fileURL: url) else {
            channelRecordingStatus = "Could not start recording"
            return
        }

        channelRecordingURL = url
        isRecordingChannel = true
        channelRecordingStatus = "Recording channel audio"
    }

    func stopChannelRecording() {
        let channelID = client.myChannelID
        guard channelID > 0 else {
            isRecordingChannel = false
            return
        }

        guard client.stopChannelRecording(channelID: channelID) else {
            channelRecordingStatus = "Could not stop recording"
            return
        }

        isRecordingChannel = false
        channelRecordingStatus = channelRecordingURL.map { "Saved \($0.lastPathComponent)" } ?? "Recording saved"
    }

    func addRemoteUser(_ user: User) {
        guard user.nUserID != client.myUserID else { return }
        let accountName = TeamTalkString.user(.username, from: user)
        let nickname = TeamTalkString.user(.nickname, from: user)
        let name = nickname.isEmpty ? accountName : nickname
        let storedVolume = UserDefaults.standard.object(forKey: userVolumeKey(for: accountName)) as? Double
        let volume = min(200, max(0, storedVolume ?? ttCustomReferencePercent(Int(user.nVolumeVoice))))
        if let index = remoteUsers.firstIndex(where: { $0.id == user.nUserID }) {
            let received = remoteUsers[index].voicePacketsReceived
            let lost = remoteUsers[index].voicePacketsLost
            remoteUsers[index] = TTCustomRemoteUser(
                id: user.nUserID,
                name: name,
                accountName: accountName,
                volume: volume,
                voicePacketsReceived: received,
                voicePacketsLost: lost
            )
        } else {
            remoteUsers.append(TTCustomRemoteUser(id: user.nUserID, name: name, accountName: accountName, volume: volume))
        }
        client.setUserVolume(userID: user.nUserID, stream: STREAMTYPE_VOICE, volume: Int32(ttCustomReferenceVolume(volume)))
    }

    var canManageUsers: Bool {
        (client.myUserRights & USERRIGHT_MOVE_USERS.rawValue) != 0 ||
            client.isChannelOperator(channelID: client.myChannelID)
    }

    var canKickUsers: Bool {
        (client.myUserRights & USERRIGHT_KICK_USERS.rawValue) != 0 ||
            client.isChannelOperator(channelID: client.myChannelID)
    }

    var canBanUsers: Bool {
        (client.myUserRights & USERRIGHT_BAN_USERS.rawValue) != 0 ||
            client.isChannelOperator(channelID: client.myChannelID)
    }

    var canManageOperators: Bool {
        (client.myUserRights & USERRIGHT_OPERATOR_ENABLE.rawValue) != 0 ||
            (client.myUserType & USERTYPE_ADMIN.rawValue) != 0
    }

    func setRemoteUserBuffer(_ milliseconds: Double, for userID: Int32) {
        let value = Int32(min(400, max(0, milliseconds.rounded())))
        _ = client.setUserAudioStreamBufferSize(userID: userID, milliseconds: value)
        channelActionStatus = "Playback buffer updated"
    }

    func setRemoteUserJitter(fixed: Double, adaptive: Bool, maximum: Double, for userID: Int32) {
        _ = client.setUserJitterControl(
            userID: userID,
            fixedDelayMilliseconds: Int32(min(400, max(0, fixed.rounded()))),
            adaptive: adaptive,
            maximumAdaptiveDelayMilliseconds: Int32(min(500, max(0, maximum.rounded())))
        )
        channelActionStatus = "Jitter settings updated"
    }

    func setRemoteUserStereo(_ mode: TTCustomStereoMode, for userID: Int32) {
        let left: TTBOOL = mode != .right ? 1 : 0
        let right: TTBOOL = mode != .left ? 1 : 0
        client.setUserStereo(userID: userID, stream: STREAMTYPE_VOICE, leftSpeaker: left, rightSpeaker: right)
        channelActionStatus = "Stereo routing updated"
    }

    func setRemoteUserOperator(_ enabled: Bool, userID: Int32) {
        guard canManageOperators else {
            channelActionStatus = "You do not have permission to manage channel operators"
            return
        }
        let command = client.setChannelOperator(userID: userID, channelID: client.myChannelID, enabled: enabled)
        channelActionStatus = command > 0 ? (enabled ? "Channel operator enabled" : "Channel operator removed") : "Could not update channel operator"
    }

    func sendPrivateMessage(_ text: String, to userID: Int32) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        var message = TextMessage()
        message.nFromUserID = client.myUserID
        message.nMsgType = MSGTYPE_USER
        message.nToUserID = userID
        channelActionStatus = client.sendTextMessage(message, content: text) ? "Message sent" : "Could not send message"
    }

    func toggleRemoteUserMute(_ userID: Int32) {
        let muted = !mutedRemoteUserIDs.contains(userID)
        client.setUserMute(userID: userID, stream: STREAMTYPE_VOICE, muted: muted)
        if muted { mutedRemoteUserIDs.insert(userID) }
        else { mutedRemoteUserIDs.remove(userID) }
        channelActionStatus = muted ? "User muted" : "User unmuted"
    }

    func kickRemoteUser(_ userID: Int32) {
        guard canKickUsers else {
            channelActionStatus = "You do not have permission to kick users"
            return
        }
        let command = client.kickUser(id: userID, fromChannelID: client.myChannelID)
        channelActionStatus = command > 0 ? "Kicking user…" : "Could not kick user"
    }

    func banRemoteUser(_ userID: Int32) {
        guard canBanUsers else {
            channelActionStatus = "You do not have permission to ban users"
            return
        }
        let command = client.banUser(id: userID, fromChannelID: client.myChannelID)
        channelActionStatus = command > 0 ? "Banning user…" : "Could not ban user"
    }

    func refreshServerChannels() {
        serverChannels = client.serverChannels
    }

    func setSystemCallControlsEnabled(_ enabled: Bool) {
        systemCallControlsEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "ttcustom.systemCallControls")
        if enabled, connected, !callCoordinator.isActive {
            client.enableVoiceTransmission(false)
            client.closeSoundDuplexDevices()
            client.closeSoundDevices()
            deactivateAudioSession()
            audioConfigured = false
            let channel = client.withChannel(id: client.myChannelID) { $0 }
            let name = TeamTalkString.channel(.name, from: channel)
            callCoordinator.begin(
                channelName: name.isEmpty ? "TeamTalk channel" : name,
                onAudioActivated: { [weak self] in
                    Task { @MainActor in self?.configureAudio() }
                },
                onFailure: { [weak self] in
                    Task { @MainActor in self?.configureAudio() }
                }
            )
        } else if !enabled {
            callCoordinator.endFromApp()
            if connected {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                    guard let self, self.connected else { return }
                    self.configureAudio()
                }
            }
        }
    }

    func joinChannelFromBrowser(_ channel: Channel, password: String = "") {
        guard loggedIn else {
            channelActionStatus = "Log in before joining a channel"
            return
        }
        let command = client.joinChannel(id: channel.nChannelID, password: password)
        guard command > 0 else {
            channelActionStatus = "Could not join \(TeamTalkString.channel(.name, from: channel))"
            return
        }
        let name = TeamTalkString.channel(.name, from: channel)
        joinCommandID = command
        pendingJoinChannelName = name.isEmpty ? "channel" : name
        pendingJoinIsRoot = false
        // A manual join replaces the automatic root-join request. Keeping this
        // true prevents a channel-list refresh from issuing a second join.
        didRequestRootJoin = true
        connectionLifecycle.markJoiningRoot()
        channelActionStatus = "Joining \(name.isEmpty ? "channel" : name)…"
    }

    func moveUserFromBrowser(_ userID: Int32, to channel: Channel) {
        guard canManageUsers else {
            channelActionStatus = "You do not have permission to move users"
            return
        }
        let command = client.moveUser(id: userID, toChannelID: channel.nChannelID)
        channelActionStatus = command > 0 ? "Moving user…" : "Could not move user"
    }

    func createChannel(name: String, password: String, parentID: Int32) {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            channelActionStatus = "Enter a channel name"
            return
        }
        var channel = Channel()
        channel.nParentID = parentID
        // A zero-initialized Channel carries nMaxUsers == 0, which the server
        // interprets as a channel that cannot admit any users. Use the server
        // limit for newly created channels so creation behaves like the
        // server's normal channel flow.
        let serverMaxUsers = client.withServerProperties { $0.nMaxUsers }
        channel.nMaxUsers = max(1, serverMaxUsers)
        var opus = OpusCodec()
        opus.nSampleRate = 48_000
        opus.nChannels = 1
        opus.nApplication = OPUS_APPLICATION_VOIP
        opus.nComplexity = 10
        opus.bFEC = 1
        opus.nBitRate = 32_000
        opus.bVBR = 1
        opus.nTxIntervalMSec = 20
        opus.nFrameSizeMSec = 20
        var audioCodec = AudioCodec()
        audioCodec.nCodec = OPUS_CODEC
        audioCodec.opus = opus
        channel.audiocodec = audioCodec
        TeamTalkString.setChannel(.name, on: &channel, to: name)
        if !password.isEmpty { TeamTalkString.setChannel(.password, on: &channel, to: password) }
        let command = client.makeChannel(&channel)
        channelCreationCommandID = command > 0 ? command : nil
        channelActionStatus = command > 0 ? "Creating channel…" : "Could not create channel"
    }

    func userVolumeKey(for accountName: String) -> String {
        "ttcustom.userVolume.\(host).\(accountName)"
    }

    func applyReceiveBuffer(to userID: Int32) {
        let buffer = Int32(voicePlayoutBufferMilliseconds.rounded())
        let fixedDelay = Int32(fixedJitterDelayMilliseconds.rounded())
        let maximum = Int32(maximumAdaptiveJitterDelayMilliseconds.rounded())
        _ = client.setUserAudioStreamBufferSize(userID: userID, milliseconds: buffer)
        _ = client.setUserJitterControl(
            userID: userID,
            fixedDelayMilliseconds: fixedDelay,
            adaptive: adaptiveJitterEnabled,
            maximumAdaptiveDelayMilliseconds: maximum
        )
    }

    func setVoicePlayoutBuffer(_ value: Double) {
        voicePlayoutBufferMilliseconds = min(300, max(0, value.rounded()))
        UserDefaults.standard.set(voicePlayoutBufferMilliseconds, forKey: "ttcustom.receiveBufferMS")
        for userID in joinedUserIDs { applyReceiveBuffer(to: userID) }
    }

    func setFixedJitterDelay(_ value: Double) {
        fixedJitterDelayMilliseconds = min(300, max(0, value.rounded()))
        UserDefaults.standard.set(fixedJitterDelayMilliseconds, forKey: "ttcustom.fixedJitterMS")
        for userID in joinedUserIDs { applyReceiveBuffer(to: userID) }
    }

    func setAdaptiveJitterEnabled(_ enabled: Bool) {
        adaptiveJitterEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "ttcustom.adaptiveJitter")
        for userID in joinedUserIDs { applyReceiveBuffer(to: userID) }
    }

    func setMaximumAdaptiveJitterDelay(_ value: Double) {
        maximumAdaptiveJitterDelayMilliseconds = min(400, max(0, value.rounded()))
        UserDefaults.standard.set(maximumAdaptiveJitterDelayMilliseconds, forKey: "ttcustom.maxAdaptiveJitterMS")
        for userID in joinedUserIDs { applyReceiveBuffer(to: userID) }
    }

    func restartRemoteAudioStreams() {
        guard connected else {
            status = "Connect to a server before applying playback settings"
            return
        }
        let users = remoteUsers.map(\.id)
        for userID in users {
            _ = client.unsubscribe(userID: userID, subscriptions: SUBSCRIBE_VOICE.rawValue)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self, self.connected else { return }
            for userID in users {
                let command = self.client.subscribe(userID: userID, subscriptions: SUBSCRIBE_VOICE.rawValue)
                if command > 0 { self.subscriptionCommandIDs.insert(command) }
                self.applyReceiveBuffer(to: userID)
            }
            self.status = "Remote audio streams restarted with new playback settings"
        }
    }

    func refreshChannelAudio() {
        let channelID = client.myChannelID
        guard channelID > 0 else { return }
        let channel = client.withChannel(id: channelID) { $0 }
        var settings = TTCustomChannelAudioSettings()
        settings.codec = channel.audiocodec.nCodec
        settings.isChannelOperator = client.isChannelOperator(channelID: channelID)
            || (client.myUserType & USERTYPE_ADMIN.rawValue) != 0
        if channel.audiocodec.nCodec == OPUS_CODEC {
            let opus = TeamTalkAudioCodec.opusCodec(from: channel.audiocodec)
            settings.opusBitrate = Double(opus.nBitRate) / 1000
            settings.opusSampleRate = Double(opus.nSampleRate)
            settings.opusChannels = Int(opus.nChannels)
            settings.opusVBR = opus.bVBR != 0
            settings.opusConstrainedVBR = opus.bVBRConstraint != 0
            settings.opusFEC = opus.bFEC != 0
            settings.opusDTX = opus.bDTX != 0
            settings.opusFrameSize = Double(opus.nFrameSizeMSec)
            settings.opusTransmitInterval = Double(opus.nTxIntervalMSec)
        }
        channelAudio = settings
    }

    func updateChannelAudio() {
        let channelID = client.myChannelID
        guard channelID > 0, channelAudio.isChannelOperator else {
            status = "Channel audio can only be changed by a channel operator"
            return
        }
        var channel = client.withChannel(id: channelID) { $0 }
        guard channel.audiocodec.nCodec == OPUS_CODEC else {
            status = "Only Opus channel editing is available here"
            return
        }
        var opus = TeamTalkAudioCodec.opusCodec(from: channel.audiocodec)
        opus.nBitRate = Int32(channelAudio.opusBitrate.rounded()) * 1000
        opus.nSampleRate = Int32(channelAudio.opusSampleRate)
        opus.nChannels = Int32(channelAudio.opusChannels)
        opus.bVBR = channelAudio.opusVBR ? 1 : 0
        opus.bVBRConstraint = channelAudio.opusConstrainedVBR ? 1 : 0
        opus.bFEC = channelAudio.opusFEC ? 1 : 0
        opus.bDTX = channelAudio.opusDTX ? 1 : 0
        opus.nFrameSizeMSec = Int32(channelAudio.opusFrameSize)
        opus.nTxIntervalMSec = Int32(channelAudio.opusTransmitInterval)
        TeamTalkAudioCodec.setOpusCodec(opus, on: &channel.audiocodec)
        let command = client.update(channel: &channel)
        guard command > 0 else {
            channelAudioStatus = "Could not send channel audio settings"
            return
        }
        channelAudioCommandID = command
        channelAudioStatus = "Applying channel audio settings…"
    }

    @objc private func routeChanged(_ notification: Notification) {
        refreshRoutes()
        // Only reassert speaker after the user explicitly selected it. A
        // transient receiver report must never steal an existing AirPods
        // route.
        if hasExplicitOutputSelection && selectedOutputID == "speaker",
           AVAudioSession.sharedInstance().currentRoute.outputs.contains(where: { $0.portType == .builtInReceiver }) {
            scheduleSpeakerRouteEnforcement()
        }
        guard let rawReason = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: rawReason) else { return }
        switch reason {
        case .newDeviceAvailable, .oldDeviceUnavailable, .wakeFromSleep, .noSuitableRouteForCategory:
            scheduleHardwareRouteReconfiguration()
        default:
            break
        }
    }

    private func scheduleHardwareRouteReconfiguration() {
        // AVAudioEngine follows normal iOS route changes itself. Rebuilding
        // the graph for every AirPods/VoiceOver route notification creates a
        // restart loop and makes both the app audio and VoiceOver crackle.
        if appleAudioPipeline != nil && !sharingSystemAudio { return }
        // Do not tear down and reopen TeamTalk's audio units while the app is
        // transitioning to or already in the background. That can release the
        // audio background assertion and disconnect the client.
        guard UIApplication.shared.applicationState == .active,
              connected, audioConfigured, audioPhase == .ready else { return }
        routeReconfigureWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, self.connected, self.audioConfigured, self.audioPhase == .ready else { return }
            self.configureAudio()
        }
        routeReconfigureWorkItem = workItem
        // Let iOS finish publishing the new route before reopening the audio
        // unit. This avoids rebuilding once for each AirPods profile change.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: workItem)
    }

    @objc private func audioSessionInterrupted(_ notification: Notification) {
        guard let rawType = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: rawType) else { return }
        switch type {
        case .began:
            audioMixer?.flushBuffers()
        case .ended:
            guard connected else { return }
            if sharingSystemAudio {
                flushAndRestartAudio()
            } else {
                configureAudio()
            }
        @unknown default:
            break
        }
    }

    @objc private func audioServicesReset() {
        guard connected else { return }
        if sharingSystemAudio {
            flushAndRestartAudio()
        } else {
            configureAudio()
        }
    }

}

