import AVFoundation
import Foundation
import LiveKitTransport
import OSLog
import SwiftUI
import UIKit

@MainActor
final class LiveKitOnlySession: ObservableObject {
    enum AudioLevel {
        case microphone
        case system
        case monitor
    }

    enum SystemAudioState: Equatable {
        case off
        case starting
        case on
    }

    enum MicrophoneChangeSource {
        case startup
        case user
        case callKit
        case configuration
        case recovery

        var announces: Bool {
            switch self {
            case .user, .callKit: return true
            case .startup, .configuration, .recovery: return false
            }
        }
    }

    private let logger = Logger(subsystem: "com.derrick.dsaudio", category: "livekit-session")
    struct Participant: Identifiable, Equatable {
        let id: String
        let name: String
        var isSpeaking: Bool
        var volume: Double
    }

    struct ChatMessage: Identifiable, Equatable {
        let id = UUID()
        let sender: String
        let text: String
        let local: Bool
    }

    struct AnnouncementVoice: Identifiable {
        let id: String
        let name: String
        let language: String
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
    @Published var messages: [ChatMessage] = []
    @Published var sendMicrophoneAnnouncements = UserDefaults.standard.object(forKey: "ttcustom.sendMicAnnouncements") as? Bool ?? true
    @Published var sendSystemAudioAnnouncements = UserDefaults.standard.object(forKey: "ttcustom.sendSystemAnnouncements") as? Bool ?? true
    @Published var announcementVoiceIdentifier = UserDefaults.standard.string(forKey: "ttcustom.announcementVoice") ?? ""
    @Published private(set) var announcementVoices: [AnnouncementVoice] = []
    @Published var dtxEnabled = UserDefaults.standard.object(forKey: "ttcustom.dtxEnabled") as? Bool ?? true
    @Published var redEnabled = UserDefaults.standard.object(forKey: "ttcustom.redEnabled") as? Bool ?? true
    @Published var inputRoute = "Not active"
    @Published var outputRoute = "Not active"
    @Published var inputOptions: [(id: String, name: String)] = []
    @Published var selectedInputID = UserDefaults.standard.string(forKey: "ttcustom.livekitInputID") ?? ""
    @Published var ioBufferMilliseconds = UserDefaults.standard.double(forKey: "ttcustom.livekitIOBuffer") == 0 ? 20 : UserDefaults.standard.double(forKey: "ttcustom.livekitIOBuffer")
    @Published var microphoneLevel = UserDefaults.standard.double(forKey: "ttcustom.micLevel") == 0 ? 1 : UserDefaults.standard.double(forKey: "ttcustom.micLevel")
    @Published var systemLevel = UserDefaults.standard.double(forKey: "ttcustom.systemLevel") == 0 ? 1 : UserDefaults.standard.double(forKey: "ttcustom.systemLevel")
    @Published var monitorLevel = UserDefaults.standard.double(forKey: "ttcustom.monitorLevel") == 0 ? 1 : UserDefaults.standard.double(forKey: "ttcustom.monitorLevel")
    @Published var appleEchoCancellation = UserDefaults.standard.object(forKey: "ttcustom.appleEchoCancellation") as? Bool ?? true
    @Published var appleNoiseSuppression = UserDefaults.standard.object(forKey: "ttcustom.appleNoiseSuppression") as? Bool ?? true
    @Published var appleAutomaticGainControl = UserDefaults.standard.object(forKey: "ttcustom.appleAutomaticGainControl") as? Bool ?? true
    @Published var webRTCEchoCancellation = UserDefaults.standard.object(forKey: "ttcustom.webRTCEchoCancellation") as? Bool ?? false
    @Published var webRTCNoiseSuppression = UserDefaults.standard.object(forKey: "ttcustom.webRTCNoiseSuppression") as? Bool ?? false
    @Published var webRTCAutomaticGainControl = UserDefaults.standard.object(forKey: "ttcustom.webRTCAutomaticGainControl") as? Bool ?? false
    @Published var highpassFilter = UserDefaults.standard.object(forKey: "ttcustom.highpassFilter") as? Bool ?? false
    @Published var typingNoiseDetection = UserDefaults.standard.object(forKey: "ttcustom.typingNoiseDetection") as? Bool ?? false
    @Published var limiterEnabled = UserDefaults.standard.object(forKey: "ttcustom.limiterEnabled") as? Bool ?? true
    @Published var audioBitrateKbps: Int = {
        let saved = UserDefaults.standard.integer(forKey: "ttcustom.audioBitrateKbps")
        return [0, 24, 32, 48, 64, 96, 128].contains(saved) ? saved : 128
    }()
    @Published var audioStatus = "Microphone track is not published"
    @Published private(set) var systemAudioState: SystemAudioState = .off
    var sharingSystemAudio: Bool { systemAudioState == .on }
    var systemAudioStarting: Bool { systemAudioState == .starting }
    @Published var systemAudioMuted = UserDefaults.standard.bool(forKey: "ttcustom.systemAudioMuted")
    @Published var callControlsEnabled = UserDefaults.standard.bool(forKey: "ttcustom.callControls")
    @Published private(set) var nativeCallAudioActive = false
    @Published var proximitySensorEnabled = UserDefaults.standard.bool(forKey: "ttcustom.proximitySensor")
    @Published var defaultOutput = UserDefaults.standard.string(forKey: "ttcustom.defaultOutput") ?? "speaker"
    @Published private(set) var diagnostics: LiveKitRoomTransport.Diagnostics?

    let transport = LiveKitRoomTransport()
    private let auth = TTCustomLiveKitAuthClient()
    private let callCoordinator = DSAudioCallCoordinator()
    private let announcementSynthesizer = AVSpeechSynthesizer()
    private var lifecycleObservers: [NSObjectProtocol] = []
    private var systemAudioCapture: AnyObject?
    private var refreshTask: Task<Void, Never>?
    private var connectionTask: Task<Void, Never>?
    private var microphoneOperation: Task<Void, Never>?
    private var processingOperation: Task<Void, Never>?
    private var publicationOperation: Task<Void, Never>?
    private var inputSelectionOperation: Task<Void, Never>?
    private var desiredMicrophoneState: Bool?
    private var systemAudioGeneration = 0
    private var sessionGeneration = 0
    private var publicationGeneration = 0
    private var inputSelectionGeneration = 0

    init() {
        announcementVoices = Self.loadAnnouncementVoices()
        password = TTCustomKeychain.load(host: host, username: username)
        UIDevice.current.isProximityMonitoringEnabled = proximitySensorEnabled
        transport.setDefaultOutputSpeaker(defaultOutput == "speaker")
        try? transport.setIOBufferMilliseconds(ioBufferMilliseconds)
        applyMixerLevels()
        transport.setLimiterEnabled(limiterEnabled)
        transport.onChatMessage = { [weak self] sender, text in
            Task { @MainActor in
                self?.messages.append(ChatMessage(sender: sender, text: text, local: false))
            }
        }
        transport.onAnnouncement = { [weak self] announcement in
            Task { @MainActor in
                self?.speakAnnouncement(announcement)
            }
        }
        callCoordinator.onMuteChanged = { [weak self] muted in
            Task { @MainActor in
                guard let self else { return }
                self.setMicrophone(!muted, source: .callKit)
            }
        }
        callCoordinator.onEnded = { [weak self] in
            Task { @MainActor in
                self?.setNativeCallAudioActive(false)
                self?.disconnect()
            }
        }
        installAudioLifecycleObservers()
    }

    deinit {
        lifecycleObservers.forEach(NotificationCenter.default.removeObserver)
        refreshTask?.cancel()
        connectionTask?.cancel()
        microphoneOperation?.cancel()
        processingOperation?.cancel()
        publicationOperation?.cancel()
        inputSelectionOperation?.cancel()
    }

    private func installAudioLifecycleObservers() {
        let center = NotificationCenter.default
        lifecycleObservers.append(center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.handleAudioLifecycleEvent(.background) }
        })
        lifecycleObservers.append(center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.handleAudioLifecycleEvent(.foreground) }
        })
        lifecycleObservers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] notification in
            Task { @MainActor in self?.handleInterruption(notification) }
        })
        lifecycleObservers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] notification in
            Task { @MainActor in self?.handleRouteChange(notification) }
        })
        lifecycleObservers.append(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.recoverAudio(restart: true) }
        })
    }

    private enum AudioLifecycleEvent { case background, foreground }

    private func handleAudioLifecycleEvent(_ event: AudioLifecycleEvent) {
        guard connected else { return }
        logger.info("lifecycle event=\(String(describing: event), privacy: .public) connected=\(self.connected, privacy: .public) mic=\(self.microphoneEnabled, privacy: .public) sharing=\(self.sharingSystemAudio, privacy: .public)")
        // Do not reconfigure AVAudioSession while backgrounding. The old
        // client deliberately left the live audio graph alone here; changing
        // category/active state can stop ScreenCaptureKit even when the mic
        // remains alive under the audio background mode.
        if case .foreground = event { recoverAudio(restart: true) }
    }

    private func handleRouteChange(_ notification: Notification) {
        refreshAudioRoute()
        logger.info("route changed input=\(self.inputRoute, privacy: .public) output=\(self.outputRoute, privacy: .public) sharing=\(self.sharingSystemAudio, privacy: .public)")
        // LiveKit/AVAudioEngine follows ordinary route changes itself. Only
        // attempt a microphone recovery for a genuinely lost route, and never
        // tear down a live ScreenCaptureKit share in response to a transient
        // AirPods or VoiceOver route notification.
        guard connected, !sharingSystemAudio,
              let reasonValue = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue),
              reason == .oldDeviceUnavailable || reason == .noSuitableRouteForCategory else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            do { try await transport.recoverMicrophone() }
            catch { status = "Microphone route recovery failed: \(error.localizedDescription)" }
        }
    }

    private func handleInterruption(_ notification: Notification) {
        guard connected,
              let rawType = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: rawType),
              type == .ended else { return }
        logger.warning("audio interruption ended; recovering")
        recoverAudio(restart: true)
    }

    private func recoverAudio(restart: Bool) {
        guard connected else { return }
        guard restart else { return }
        logger.warning("audio recovery requested mic=\(self.microphoneEnabled, privacy: .public) sharing=\(self.sharingSystemAudio, privacy: .public)")
        recoverAudioIfNeeded()
    }

    private func recoverAudioIfNeeded() {
        guard microphoneEnabled else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            do { try await self.transport.restartMicrophone() }
            catch { self.status = "Microphone recovery failed: \(error.localizedDescription)" }
        }
    }

    func restartAudio() {
        guard connected else {
            status = "Connect before restarting audio"
            return
        }
        do {
            try transport.setIOBufferMilliseconds(ioBufferMilliseconds)
            try transport.reconcileAudioSession()
        } catch {
            status = "Could not prepare audio restart: \(error.localizedDescription)"
            return
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                if self.microphoneEnabled { try await self.transport.restartMicrophone() }
                self.refreshAudioRoute()
                self.status = "Audio restarted"
            } catch {
                self.status = "Audio restart failed: \(error.localizedDescription)"
            }
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
        guard connectionTask == nil else { return }
        guard URL(string: host) != nil, host.hasPrefix("http") else { status = "Enter the HTTPS server URL"; return }
        guard !username.isEmpty, !password.isEmpty else { status = "Enter your username and password"; return }
        UserDefaults.standard.set(host, forKey: "ttcustom.livekitURL")
        UserDefaults.standard.set(username, forKey: "ttcustom.username")
        UserDefaults.standard.set(nickname, forKey: "ttcustom.nickname")
        UserDefaults.standard.set(roomName, forKey: "ttcustom.room")
        TTCustomKeychain.save(password, host: host, username: username)
        status = "Connecting…"
        logger.info("connect requested host=\(self.host, privacy: .private(mask: .hash)) room=\(self.roomName, privacy: .public) username=\(self.username, privacy: .private(mask: .hash))")
        let host = host, username = username, password = password, nickname = nickname, roomName = roomName
        sessionGeneration += 1
        let generation = sessionGeneration
        connectionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.connectionTask = nil }
            do {
                if transport.isConnected {
                    await transport.disconnect()
                }
                let response = try await auth.requestToken(host: host, username: username, password: password, room: roomName, participantName: nickname, participantIdentity: participantIdentity)
                try Task.checkCancellation()
                guard self.sessionGeneration == generation else { return }
                try await transport.connect(url: response.serverURL, token: response.participantToken)
                try Task.checkCancellation()
                guard self.sessionGeneration == generation else {
                    await transport.disconnect()
                    return
                }
                connected = true
                status = "Connected"
                logger.info("connected and authenticated")
                startRefreshLoop()
                refreshAudioRoute()
                refreshParticipants()
                refreshDiagnostics()
                // CallKit is a control surface, not a prerequisite for
                // publishing. The microphone must be live even if iOS delays
                // or omits didActivate for this call transaction.
                try await applyMicrophoneState(true)
                if callControlsEnabled { beginCallControls(roomName: roomName) }
            } catch {
                guard self.sessionGeneration == generation else { return }
                connected = false
                microphoneEnabled = false
                diagnostics = nil
                status = error.localizedDescription
                logger.error("connect failed error=\(error.localizedDescription, privacy: .public)")
            }
        }
    }

    func disconnect() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            sessionGeneration += 1
            connectionTask?.cancel()
            connectionTask = nil
            refreshTask?.cancel()
            refreshTask = nil
            stopSystemAudioSharing()
            logger.info("disconnect requested")
            setNativeCallAudioActive(false)
            callCoordinator.endFromApp()
            await transport.disconnect()
            connected = false
            microphoneEnabled = false
            participantCount = 0
            participants = []
            messages = []
            audioStatus = "Microphone track is not published"
            systemAudioState = .off
            status = "Not connected"
            diagnostics = nil
            refreshAudioRoute()
        }
    }

    private func applyMicrophoneState(_ enabled: Bool) async throws {
        logger.info("microphone state requested enabled=\(enabled, privacy: .public)")
        try await transport.publishMicrophone(
            enabled: enabled,
            appleEchoCancellation: appleEchoCancellation,
            appleNoiseSuppression: appleNoiseSuppression,
            appleAutomaticGainControl: appleAutomaticGainControl,
            webRTCEchoCancellation: webRTCEchoCancellation,
            webRTCNoiseSuppression: webRTCNoiseSuppression,
            webRTCAutomaticGainControl: webRTCAutomaticGainControl,
            highpassFilter: highpassFilter,
            typingNoiseDetection: typingNoiseDetection
        )
        applyMixerLevels()
        microphoneEnabled = enabled
        audioStatus = enabled ? "Microphone track live" : "Microphone muted"
        refreshDiagnostics()
        logger.info("microphone state applied enabled=\(enabled, privacy: .public) status=\(self.audioStatus, privacy: .public)")
    }

    private func beginCallControls(roomName: String) {
        guard connected, callControlsEnabled else { return }
        callCoordinator.begin(roomName: roomName) { [weak self] in
            Task { @MainActor in
                guard let self, self.connected else { return }
                self.setNativeCallAudioActive(true)
                await self.recoverAfterCallKitActivation()
            }
        }
    }

    private func setNativeCallAudioActive(_ active: Bool) {
        nativeCallAudioActive = active
        transport.setCallKitAudioRouteOwnership(active)
    }

    private func sendAnnouncement(_ text: String) {
        guard connected else { return }
        Task { @MainActor [weak self] in
            do { try await self?.transport.sendAnnouncement(text) }
            catch {
                self?.logger.debug("announcement send failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    func setSendMicrophoneAnnouncements(_ enabled: Bool) {
        sendMicrophoneAnnouncements = enabled
        UserDefaults.standard.set(enabled, forKey: "ttcustom.sendMicAnnouncements")
    }

    func setSendSystemAudioAnnouncements(_ enabled: Bool) {
        sendSystemAudioAnnouncements = enabled
        UserDefaults.standard.set(enabled, forKey: "ttcustom.sendSystemAnnouncements")
    }

    private static func loadAnnouncementVoices() -> [AnnouncementVoice] {
        AVSpeechSynthesisVoice.speechVoices()
            .sorted {
                if $0.language == $1.language { return $0.name < $1.name }
                return $0.language < $1.language
            }
            .map { AnnouncementVoice(id: $0.identifier, name: $0.name, language: $0.language) }
    }

    func setAnnouncementVoice(_ identifier: String) {
        announcementVoiceIdentifier = identifier
        UserDefaults.standard.set(identifier, forKey: "ttcustom.announcementVoice")
    }

    func testAnnouncementVoice() {
        speakAnnouncement("This is the D’s Audio announcement voice.")
    }

    private func speakAnnouncement(_ text: String) {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = selectedAnnouncementVoice()
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        announcementSynthesizer.stopSpeaking(at: .immediate)
        announcementSynthesizer.speak(utterance)
    }

    private func selectedAnnouncementVoice() -> AVSpeechSynthesisVoice? {
        if !announcementVoiceIdentifier.isEmpty,
           let selected = AVSpeechSynthesisVoice(identifier: announcementVoiceIdentifier) {
            return selected
        }
        let preferredLanguage = Locale.preferredLanguages.first ?? "en-US"
        return AVSpeechSynthesisVoice(language: preferredLanguage)
            ?? AVSpeechSynthesisVoice(language: "en-US")
            ?? AVSpeechSynthesisVoice.speechVoices().first
    }

    func sendChat(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, connected else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await transport.sendChat(trimmed)
                messages.append(ChatMessage(sender: nickname, text: trimmed, local: true))
            } catch {
                status = "Could not send chat: \(error.localizedDescription)"
            }
        }
    }

    func toggleMicrophone() {
        setMicrophone(!microphoneEnabled, source: .user)
    }

    /// The only entry point for user-visible microphone state changes.
    /// Announcements are emitted here; the LiveKit operation never emits them.
    func setMicrophone(_ enabled: Bool, source: MicrophoneChangeSource) {
        guard connected else { return }
        if desiredMicrophoneState == enabled { return }
        if desiredMicrophoneState == nil, microphoneOperation == nil, microphoneEnabled == enabled { return }
        microphoneOperation?.cancel()
        desiredMicrophoneState = enabled

        if source.announces && sendMicrophoneAnnouncements {
            sendAnnouncement(enabled ? "\(nickname) has unmuted" : "\(nickname) has muted")
        }

        microphoneOperation = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.desiredMicrophoneState == enabled {
                    self.desiredMicrophoneState = nil
                }
            }
            do {
                try await self.applyMicrophoneState(enabled)
            } catch is CancellationError {
                return
            } catch {
                self.status = error.localizedDescription
            }
        }
    }

    func setCallControlsEnabled(_ enabled: Bool) {
        callControlsEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "ttcustom.callControls")
        if enabled, connected {
            beginCallControls(roomName: roomName)
        }
        if !enabled {
            setNativeCallAudioActive(false)
            callCoordinator.endFromApp()
            guard connected else { return }
        }
    }

    private func recoverAfterCallKitActivation() async {
        guard connected else { return }
        logger.info("CallKit activated; restoring LiveKit audio engine")
        do {
            // CallKit has just activated the system audio session. Reapply the
            // transport's route/session policy, then restart the capture graph
            // while retaining the existing LiveKit publication.
            try transport.reconcileAudioSession()
            try await transport.restartMicrophone()
            applyMixerLevels()
            refreshAudioRoute()
            refreshDiagnostics()
            logger.info("CallKit audio recovery complete engineRunning=\(self.transport.isAudioEngineRunning, privacy: .public)")
        } catch {
            status = "Call audio recovery failed: \(error.localizedDescription)"
            logger.error("CallKit audio recovery failed error=\(error.localizedDescription, privacy: .public)")
        }
    }

    func setProximitySensorEnabled(_ enabled: Bool) {
        proximitySensorEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "ttcustom.proximitySensor")
        UIDevice.current.isProximityMonitoringEnabled = enabled
    }

    func setDefaultOutput(_ value: String) {
        defaultOutput = value
        UserDefaults.standard.set(value, forKey: "ttcustom.defaultOutput")
        transport.setDefaultOutputSpeaker(value == "speaker")
        if connected {
            do { try transport.reconcileAudioSession() }
            catch { status = "Could not set default output: \(error.localizedDescription)" }
        }
        refreshAudioRoute()
    }

    private func applyProcessingNow() {
        do {
            try transport.setMicrophoneProcessing(
                appleEchoCancellation: appleEchoCancellation,
                appleNoiseSuppression: appleNoiseSuppression,
                appleAutomaticGainControl: appleAutomaticGainControl,
                webRTCEchoCancellation: webRTCEchoCancellation,
                webRTCNoiseSuppression: webRTCNoiseSuppression,
                webRTCAutomaticGainControl: webRTCAutomaticGainControl,
                highpassFilter: highpassFilter,
                typingNoiseDetection: typingNoiseDetection
            )
            transport.setLimiterEnabled(limiterEnabled)
        } catch {
            status = error.localizedDescription
        }
    }

    private func scheduleProcessingApply() {
        processingOperation?.cancel()
        processingOperation = Task { @MainActor [weak self] in
            // Coalesce a burst of switch changes into one graph update.
            try? await Task.sleep(for: .milliseconds(50))
            guard !Task.isCancelled, let self else { return }
            self.applyProcessingNow()
        }
    }

    func setLimiterEnabled(_ enabled: Bool) {
        limiterEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "ttcustom.limiterEnabled")
        transport.setLimiterEnabled(enabled)
    }

    func setHighpassFilter(_ enabled: Bool) {
        highpassFilter = enabled
        UserDefaults.standard.set(enabled, forKey: "ttcustom.highpassFilter")
        scheduleProcessingApply()
    }

    func setTypingNoiseDetection(_ enabled: Bool) {
        typingNoiseDetection = enabled
        UserDefaults.standard.set(enabled, forKey: "ttcustom.typingNoiseDetection")
        scheduleProcessingApply()
    }

    func setAppleEchoCancellation(_ enabled: Bool) {
        appleEchoCancellation = enabled
        if enabled { webRTCEchoCancellation = false }
        UserDefaults.standard.set(enabled, forKey: "ttcustom.appleEchoCancellation")
        UserDefaults.standard.set(webRTCEchoCancellation, forKey: "ttcustom.webRTCEchoCancellation")
        scheduleProcessingApply()
    }

    func setAppleNoiseSuppression(_ enabled: Bool) {
        appleNoiseSuppression = enabled
        if enabled { webRTCNoiseSuppression = false }
        UserDefaults.standard.set(enabled, forKey: "ttcustom.appleNoiseSuppression")
        UserDefaults.standard.set(webRTCNoiseSuppression, forKey: "ttcustom.webRTCNoiseSuppression")
        scheduleProcessingApply()
    }

    func setAppleAutomaticGainControl(_ enabled: Bool) {
        appleAutomaticGainControl = enabled
        if enabled { webRTCAutomaticGainControl = false }
        UserDefaults.standard.set(enabled, forKey: "ttcustom.appleAutomaticGainControl")
        UserDefaults.standard.set(webRTCAutomaticGainControl, forKey: "ttcustom.webRTCAutomaticGainControl")
        scheduleProcessingApply()
    }

    func setWebRTCEchoCancellation(_ enabled: Bool) {
        webRTCEchoCancellation = enabled
        if enabled { appleEchoCancellation = false }
        UserDefaults.standard.set(enabled, forKey: "ttcustom.webRTCEchoCancellation")
        UserDefaults.standard.set(appleEchoCancellation, forKey: "ttcustom.appleEchoCancellation")
        scheduleProcessingApply()
    }

    func setWebRTCNoiseSuppression(_ enabled: Bool) {
        webRTCNoiseSuppression = enabled
        if enabled { appleNoiseSuppression = false }
        UserDefaults.standard.set(enabled, forKey: "ttcustom.webRTCNoiseSuppression")
        UserDefaults.standard.set(appleNoiseSuppression, forKey: "ttcustom.appleNoiseSuppression")
        scheduleProcessingApply()
    }

    func setWebRTCAutomaticGainControl(_ enabled: Bool) {
        webRTCAutomaticGainControl = enabled
        if enabled { appleAutomaticGainControl = false }
        UserDefaults.standard.set(enabled, forKey: "ttcustom.webRTCAutomaticGainControl")
        UserDefaults.standard.set(appleAutomaticGainControl, forKey: "ttcustom.appleAutomaticGainControl")
        scheduleProcessingApply()
    }

    func applyAudioQuality() {
        UserDefaults.standard.set(audioBitrateKbps, forKey: "ttcustom.audioBitrateKbps")
        applyAudioPublicationConfiguration()
    }

    func setAudioBitrate(_ value: Int) {
        audioBitrateKbps = value
        applyAudioQuality()
    }

    func setDTXEnabled(_ enabled: Bool) {
        dtxEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "ttcustom.dtxEnabled")
        applyAudioPublicationConfiguration()
    }

    func setREDEnabled(_ enabled: Bool) {
        redEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "ttcustom.redEnabled")
        applyAudioPublicationConfiguration()
    }

    private func applyAudioPublicationConfiguration() {
        guard connected else { return }
        publicationGeneration += 1
        let generation = publicationGeneration
        let previous = publicationOperation
        publicationOperation = Task { @MainActor [weak self] in
            guard let self else { return }
            if let previous { await previous.value }
            guard self.publicationGeneration == generation, !Task.isCancelled else { return }
            defer {
                if self.publicationGeneration == generation { self.publicationOperation = nil }
            }
            do {
                audioStatus = "Applying audio publication settings…"
                let bitrate = audioBitrateKbps == 0 ? nil : audioBitrateKbps * 1000
                try await transport.setAudioPublicationConfiguration(
                    maxBitrate: bitrate,
                    dtx: dtxEnabled,
                    red: redEnabled
                )
                audioStatus = microphoneEnabled ? "Microphone track live" : "Microphone muted"
            } catch {
                status = "Could not apply audio transport: \(error.localizedDescription)"
            }
        }
    }

    func toggleSystemAudio() {
        if systemAudioState == .on || systemAudioState == .starting {
            stopSystemAudioSharing()
        } else if #available(iOS 27.0, *) {
            startSystemAudioSharing()
        } else {
            status = "System audio sharing requires iOS 27 or later"
        }
    }

    func toggleSystemAudioSource() {
        if sharingSystemAudio {
            setSystemAudioMuted(!systemAudioMuted)
        } else {
            toggleSystemAudio()
        }
    }

    func setSystemAudioMuted(_ muted: Bool) {
        systemAudioMuted = muted
        UserDefaults.standard.set(muted, forKey: "ttcustom.systemAudioMuted")
        applyMixerLevels()
    }

    @available(iOS 27.0, *)
    func startSystemAudioSharing() {
        guard connected else {
            status = "Connect before sharing system audio"
            return
        }
        guard systemAudioState == .off else { return }

        systemAudioGeneration += 1
        let generation = systemAudioGeneration
        systemAudioState = .starting

        let capture = TTCustomSystemAudioCapture()
        let transport = self.transport
        capture.onStarted = { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                guard self.systemAudioGeneration == generation,
                      self.systemAudioState == .starting else { return }
                self.systemAudioState = .on
                self.transport.setSystemAudioMixingEnabled(true)
                self.audioStatus = "Microphone and system audio are mixed into one LiveKit stream"
                if self.sendSystemAudioAnnouncements {
                    self.sendAnnouncement("\(self.nickname) started screen sharing")
                }
            }
        }
        capture.onAudio = { [weak transport] samples in
            transport?.captureSystemAudio(samples: samples)
        }
        capture.onFailure = { [weak self] message in
            Task { @MainActor in
                guard let self else { return }
                guard self.systemAudioGeneration == generation else { return }
                self.systemAudioState = .off
                self.systemAudioCapture = nil
                self.transport.setSystemAudioMixingEnabled(false)
                self.status = message
                self.audioStatus = self.microphoneEnabled ? "Microphone track live" : "Microphone track is not published"
            }
        }
        systemAudioCapture = capture
        audioStatus = "Choose an app or display to share system audio"
        capture.presentPicker(capturesMicrophone: false)
    }

    private func stopSystemAudioSharing() {
        let wasSharing = systemAudioState == .on || sharingSystemAudio
        systemAudioGeneration += 1
        systemAudioState = .off
        if #available(iOS 27.0, *) {
            (systemAudioCapture as? TTCustomSystemAudioCapture)?.stop()
        }
        systemAudioCapture = nil
        transport.setSystemAudioMixingEnabled(false)
        audioStatus = microphoneEnabled ? "Microphone track live" : "Microphone track is not published"
        if wasSharing, sendSystemAudioAnnouncements {
            sendAnnouncement("\(nickname) stopped screen sharing")
        }
    }

    func setLevel(_ value: Double, level: AudioLevel) {
        switch level {
        case .microphone:
            microphoneLevel = min(1, max(0, value))
            UserDefaults.standard.set(microphoneLevel, forKey: "ttcustom.micLevel")
        case .system:
            systemLevel = value
            UserDefaults.standard.set(value, forKey: "ttcustom.systemLevel")
        case .monitor:
            monitorLevel = min(1, max(0, value))
            UserDefaults.standard.set(monitorLevel, forKey: "ttcustom.monitorLevel")
        }
        applyMixerLevels()
    }

    private func applyMixerLevels() {
        transport.setAudioLevels(microphone: microphoneLevel, output: monitorLevel)
        transport.setSystemAudioGain(systemAudioMuted ? 0 : systemLevel)
    }

    func setIOBuffer(_ value: Double) {
        ioBufferMilliseconds = min(40, max(5, value.rounded()))
        UserDefaults.standard.set(ioBufferMilliseconds, forKey: "ttcustom.livekitIOBuffer")
    }

    func selectInput(_ id: String) {
        selectedInputID = id
        UserDefaults.standard.set(id, forKey: "ttcustom.livekitInputID")
        inputSelectionGeneration += 1
        let generation = inputSelectionGeneration
        let previous = inputSelectionOperation
        inputSelectionOperation = Task { @MainActor [weak self] in
            guard let self else { return }
            if let previous { await previous.value }
            guard self.inputSelectionGeneration == generation, !Task.isCancelled else { return }
            defer {
                if self.inputSelectionGeneration == generation { self.inputSelectionOperation = nil }
            }
            do {
                let audioSession = AVAudioSession.sharedInstance()
                guard let input = audioSession.availableInputs?.first(where: { $0.uid == id }) else { return }
                try audioSession.setActive(true)
                try audioSession.setPreferredInput(input)
                try self.transport.reconcileAudioSession()
                // Reapply after reconciliation because the audio engine may
                // negotiate the route while the session is being reopened.
                try audioSession.setPreferredInput(input)
                if self.connected && self.microphoneEnabled {
                    try await self.transport.restartMicrophone()
                    try audioSession.setPreferredInput(input)
                }
                self.refreshAudioRoute()
                self.logger.info("input selection requested=\(id, privacy: .public) actual=\(audioSession.currentRoute.inputs.first?.uid ?? "none", privacy: .public)")
            } catch {
                self.status = "Could not select microphone: \(error.localizedDescription)"
            }
        }
    }

    func refreshParticipants() {
        participants = transport.remoteParticipantSnapshots().map {
            Participant(id: $0.id, name: $0.name, isSpeaking: $0.isSpeaking, volume: $0.volume)
        }
        participantCount = participants.count + 1
    }

    func refreshDiagnostics() {
        diagnostics = transport.diagnostics()
        if let diagnostics {
            logger.debug("diagnostics engine=\(diagnostics.audioEngineRunning, privacy: .public) published=\(diagnostics.microphonePublished, privacy: .public) muted=\(diagnostics.microphoneMuted, privacy: .public) micGain=\(diagnostics.microphoneMixerVolume, privacy: .public) outputGain=\(diagnostics.outputMixerVolume, privacy: .public) remoteTracks=\(diagnostics.remoteAudioTrackCount, privacy: .public) subscribed=\(diagnostics.subscribedRemoteAudioTrackCount, privacy: .public)")
        }
    }

    func diagnosticsText() -> String {
        var lines = [
            "D's Audio diagnostics",
            "=====================",
            "Status: \(status)",
            "Server: \(host)",
            "Room: \(roomName)",
            "Input: \(inputRoute)",
            "Output: \(outputRoute)",
            String(format: "Sample rate: %.0f Hz", AVAudioSession.sharedInstance().sampleRate),
            String(format: "I/O buffer: %.1f ms", AVAudioSession.sharedInstance().ioBufferDuration * 1000)
        ]
        if let diagnostics {
            lines += [
                "Transport: \(diagnostics.connectionState)",
                "Microphone publication: \(diagnostics.microphonePublished ? "published" : "not published")",
                "Microphone track: \(diagnostics.microphoneMuted ? "muted" : "unmuted")",
                String(format: "Mixer microphone gain: %.0f%%", diagnostics.microphoneMixerVolume * 100),
                String(format: "Mixer output gain: %.0f%%", diagnostics.outputMixerVolume * 100),
                "Audio engine: \(diagnostics.audioEngineRunning ? "running" : "stopped")",
                "Remote participants: \(diagnostics.remoteParticipantCount)",
                "Remote audio tracks: \(diagnostics.remoteAudioTrackCount)",
                "Subscribed remote audio tracks: \(diagnostics.subscribedRemoteAudioTrackCount)",
                "Captured frames: \(diagnostics.capturedFrames)",
                "Captured blocks: \(diagnostics.capturedBlocks)",
                "Non-silent captured blocks: \(diagnostics.nonSilentCapturedBlocks)",
                String(format: "Last capture peak: %.5f", diagnostics.lastCapturePeak),
                String(format: "Last capture RMS: %.5f", diagnostics.lastCaptureRMS)
            ]
            if let connection = diagnostics.connectionStatistics {
                lines.append("")
                lines.append("WebRTC connection")
                if let value = connection.roundTripTimeMilliseconds {
                    lines.append(String(format: "Round-trip time: %.0f ms", value))
                }
                if let value = connection.availableOutgoingBitrate {
                    lines.append(String(format: "Available outgoing bitrate: %.0f kbps", value / 1000))
                }
                if let value = connection.availableIncomingBitrate {
                    lines.append(String(format: "Available incoming bitrate: %.0f kbps", value / 1000))
                }
                if let value = connection.packetsSent { lines.append("Transport packets sent: \(value)") }
                if let value = connection.packetsReceived { lines.append("Transport packets received: \(value)") }
                if let value = connection.bytesSent { lines.append("Transport bytes sent: \(value)") }
                if let value = connection.bytesReceived { lines.append("Transport bytes received: \(value)") }
            }
            if let stream = diagnostics.outboundAudio {
                lines.append("")
                lines.append("Outbound audio")
                appendAudioStreamDiagnostics(stream, to: &lines)
            }
            for stream in diagnostics.inboundAudio {
                lines.append("")
                lines.append("Inbound audio")
                appendAudioStreamDiagnostics(stream, to: &lines)
            }
        }
        return lines.joined(separator: "\n")
    }

    private func appendAudioStreamDiagnostics(_ stream: LiveKitRoomTransport.Diagnostics.AudioStream, to lines: inout [String]) {
        if let value = stream.codec { lines.append("Codec: \(value)") }
        if let value = stream.clockRate { lines.append("Clock rate: \(value) Hz") }
        if let value = stream.channels { lines.append("Channels: \(value)") }
        if let value = stream.packets { lines.append("Packets: \(value)") }
        if let value = stream.packetsLost { lines.append("Packets lost: \(value)") }
        if let value = stream.bytes { lines.append("Bytes: \(value)") }
        if let value = stream.measuredBitrate { lines.append(String(format: "Measured bitrate: %.0f kbps", value / 1000)) }
        if let value = stream.targetBitrate { lines.append(String(format: "Target bitrate: %.0f kbps", value / 1000)) }
        if let value = stream.jitterMilliseconds { lines.append(String(format: "Jitter: %.2f ms", value)) }
        if let value = stream.jitterBufferDelayMilliseconds { lines.append(String(format: "Jitter buffer delay: %.2f ms", value)) }
        if let value = stream.concealedSamples { lines.append("Concealed samples: \(value)") }
        if let value = stream.silentConcealedSamples { lines.append("Silent concealed samples: \(value)") }
        if let value = stream.concealmentEvents { lines.append("Concealment events: \(value)") }
        if let value = stream.audioLevel { lines.append(String(format: "Audio level: %.5f", value)) }
        if let value = stream.retransmittedPackets { lines.append("Retransmitted packets: \(value)") }
        if let value = stream.retransmittedBytes { lines.append("Retransmitted bytes: \(value)") }
    }

    private func startRefreshLoop() {
        refreshTask?.cancel()
        refreshTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self, self.connected else { return }
                self.refreshParticipants()
                self.refreshDiagnostics()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    func setParticipantVolume(_ participant: Participant, value: Double) {
        guard let index = participants.firstIndex(where: { $0.id == participant.id }) else { return }
        participants[index].volume = value
        transport.setRemoteParticipantVolume(identity: participant.id, volume: value)
        UserDefaults.standard.set(value, forKey: "ttcustom.volume.\(participant.id)")
    }

    func refreshAudioRoute() {
        let audioSession = AVAudioSession.sharedInstance()
        inputOptions = (audioSession.availableInputs ?? []).map { ($0.uid, $0.portName) }
        let actualInputID = audioSession.currentRoute.inputs.first?.uid
        if selectedInputID.isEmpty || !inputOptions.contains(where: { $0.id == selectedInputID }) {
            selectedInputID = actualInputID ?? inputOptions.first?.id ?? ""
        }
        inputRoute = audioSession.currentRoute.inputs.first?.portName ?? "Not active"
        outputRoute = audioSession.currentRoute.outputs.first?.portName ?? "Not active"
    }
}
