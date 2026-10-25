import AVFoundation
import Foundation
@preconcurrency import TeamTalkKit

@MainActor
extension TTCustomSession {
func connect() {
        connectionGeneration &+= 1
        let generation = connectionGeneration
        connectionRetryWorkItem?.cancel()
        connectionRetryWorkItem = nil
        connectionAttempt = 0
        networkHealth.reconnectCount = 0
        lastDiagnosticsPing = .distantPast
        connectionLifecycle.reset()
        guard ttCustomIsValidPort(tcpPort), ttCustomIsValidPort(udpPort), host.isEmpty == false else {
            status = "Enter a host and valid ports"
            return
        }

        let requestedHost = host
        let requestedTCPPort = tcpPort
        let requestedUDPPort = udpPort
        let startConnection: () -> Void = { [weak self] in
            guard let self, self.connectionGeneration == generation else { return }
            self.beginConnect(host: requestedHost, tcpPort: requestedTCPPort, udpPort: requestedUDPPort, generation: generation)
        }
        // Reconnects must not inherit users, subscriptions, command IDs, or
        // an in-flight ScreenCaptureKit audio route from the previous server.
        disconnect(invalidate: false, completion: startConnection)
    }

    func beginConnect(host: String, tcpPort: String, udpPort: String, generation: UInt64? = nil) {
        if let generation, generation != connectionGeneration { return }
        guard let tcp = Int32(tcpPort), let udp = Int32(udpPort),
              ttCustomIsValidPort(tcpPort), ttCustomIsValidPort(udpPort), !host.isEmpty else {
            status = "Enter a host and valid ports"
            return
        }
        UserDefaults.standard.set(host, forKey: "ttcustom.host")
        UserDefaults.standard.set(tcpPort, forKey: "ttcustom.tcp")
        UserDefaults.standard.set(udpPort, forKey: "ttcustom.udp")
        UserDefaults.standard.set(username, forKey: "ttcustom.username")
        UserDefaults.standard.set(nickname, forKey: "ttcustom.nickname")
        TTCustomKeychain.save(password, host: host, username: username)

        guard client.isStarted else {
            status = "TeamTalk audio engine is unavailable"
            return
        }

        connectionAttempt += 1
        connectionLifecycle.beginAttempt(connectionAttempt)
        status = "Connecting…"
        guard client.connect(toHost: host, tcpPort: tcp, udpPort: udp, encrypted: false) else {
            handleConnectionFailure("Could not start the connection")
            return
        }

        status = "Connecting…"
        startPolling()
        scheduleConnectionTimeout(generation: connectionGeneration)
    }

    func disconnect(invalidate: Bool = true, completion: (() -> Void)? = nil) {
        if invalidate { connectionGeneration &+= 1 }
        if completion == nil {
            connectionRetryWorkItem?.cancel()
            connectionRetryWorkItem = nil
        }
        pollTimer?.setEventHandler {}
        pollTimer?.cancel()
        pollTimer = nil
        connectionTimeoutWorkItem?.cancel()
        connectionTimeoutWorkItem = nil
        rootJoinWorkItem?.cancel()
        rootJoinWorkItem = nil
        stopSystemAudioSharing(reconfigure: false) { [weak self] in
            guard let self else { return }
            self.callCoordinator.endFromApp()
            self.appleAudioPipeline?.stop()
            self.appleAudioPipeline = nil
            self.client.closeSoundDuplexDevices()
            self.client.closeSoundDevices()
            if self.isRecordingChannel {
                self.stopChannelRecording()
            }
            self.client.disconnect()
            self.connectionLifecycle.reset()
            self.speakerRouteWorkItem?.cancel()
            self.deactivateAudioSession()
            self.connected = false
            self.transmitting = false
            self.loggedIn = false
            self.didRequestRootJoin = false
            self.loginCommandID = nil
            self.joinCommandID = nil
            self.pendingJoinChannelName = nil
            self.pendingJoinIsRoot = false
            self.channelCreationCommandID = nil
            self.subscriptionCommandIDs.removeAll()
            self.joinedUserIDs.removeAll()
            self.remoteUsers.removeAll()
            self.mutedRemoteUserIDs.removeAll()
            self.serverChannels.removeAll()
            self.channelActionStatus = ""
            self.networkHealth = TTCustomNetworkHealth(reconnectCount: self.networkHealth.reconnectCount)
            self.audioConfigured = false
            if completion == nil {
                self.status = "Not connected"
            }
            completion?()
        }
    }

    func reconnect() {
        guard connected || connectionLifecycle.phase != .disconnected else {
            connect()
            return
        }
        connect()
    }

    func diagnosticsText() -> String {
        let network = networkHealth
        let audio = audioHealth
        let mixer = audio.mixerStats
        let udpPing = network.statisticsAvailable && network.udpPingMilliseconds >= 0 ? "\(network.udpPingMilliseconds) ms" : "Not measured"
        let tcpPing = network.statisticsAvailable && network.tcpPingMilliseconds >= 0 ? "\(network.tcpPingMilliseconds) ms" : "Not measured"
        let sampleRate = audio.sampleRate > 0 ? "\(audio.sampleRate) Hz" : "Unavailable"
        let ioBuffer = audio.bufferDuration > 0 ? "\(audio.bufferDuration * 1000) ms" : "Unavailable"
        let inputDelay = network.statisticsAvailable && network.soundInputDelayMilliseconds > 0
            ? "\(network.soundInputDelayMilliseconds) ms"
            : "Not measured"
        let mixerState = mixer.active ? "Active" : "Inactive (system sharing is off)"
        let microphoneCapabilityLines: String = {
            var lines: [String] = []
            if audio.maximumInputChannelCount > 0 {
                lines.append("Input channels: \(audio.inputChannelCount)/\(audio.maximumInputChannelCount) current/max")
            }
            if !audio.activeInputDataSourceName.isEmpty {
                lines.append("Active microphone source: \(audio.activeInputDataSourceName)")
            }
            for source in audio.microphoneSources {
                var details = [source.supportsStereo ? "stereo supported" : "stereo not reported"]
                if !source.supportedPolarPatterns.isEmpty {
                    details.append("polar patterns: \(source.supportedPolarPatterns.joined(separator: ", "))")
                }
                if let selected = source.selectedPolarPattern, !selected.isEmpty {
                    details.append("selected: \(selected)")
                }
                lines.append("\(source.name): \(details.joined(separator: "; "))")
            }
            return lines.joined(separator: "\n")
        }()
        let remoteUserLines = remoteUsers.map { user in
            let loss = user.voicePacketsReceived + user.voicePacketsLost > 0
                ? String(format: "%.1f%%", user.voicePacketLossPercent)
                : "Not measured"
            return "\(user.name): received \(user.voicePacketsReceived), lost \(user.voicePacketsLost), loss \(loss)"
        }.joined(separator: "\n")
        return """
        TT Custom diagnostics
        =====================
        Status: \(status)
        Server: \(host):\(tcpPort)/\(udpPort)
        Username: \(username)
        Connected: \(connected)
        Sharing system audio: \(sharingSystemAudio)
        Transmitting: \(transmitting)

        Audio route
        -----------
        Input: \(audio.inputRoute)
        Output: \(audio.outputRoute)
        Sample rate: \(sampleRate)
        Actual I/O buffer: \(ioBuffer)
        Input buffer setting: \(inputBufferMilliseconds) ms
        Voice playout buffer: \(voicePlayoutBufferMilliseconds) ms
        Fixed jitter delay: \(fixedJitterDelayMilliseconds) ms
        Adaptive jitter: \(adaptiveJitterEnabled ? "On" : "Off")
        Maximum adaptive jitter delay: \(maximumAdaptiveJitterDelayMilliseconds) ms
        Apple voice processing: \(echoCancellation)
        WebRTC echo cancellation: \(webrtcEchoCancellation)
        Automatic gain control: \(automaticGainControl)

        Microphone capabilities
        ------------------------
        \(microphoneCapabilityLines)

        Network
        -------
        UDP ping: \(udpPing)
        TCP ping: \(tcpPing)
        Statistics API: \(network.statisticsAvailable ? "Available" : "Unavailable")
        UDP server silence: \(network.statisticsAvailable ? "\(network.udpServerSilenceSeconds) s since any server UDP traffic" : "Not measured")
        TCP server silence: \(network.statisticsAvailable ? "\(network.tcpServerSilenceSeconds) s since any server TCP traffic" : "Not measured")
        Input startup delay: \(inputDelay)
        Voice UDP traffic: \(network.voiceTrafficObserved ? "Observed" : "Not observed")
        Voice bytes sent: \(network.voiceBytesSent)
        Voice bytes received: \(network.voiceBytesReceived)
        Reconnects: \(network.reconnectCount)

        Remote voice packet loss
        -------------------------
        \(remoteUserLines.isEmpty ? "No remote users" : remoteUserLines)

        Mixer
        -----
        State: \(mixerState)
        Mic queue: \(mixer.active ? "\(mixer.micFrames)/\(mixer.micCapacity) frames" : "Inactive")
        System queue: \(mixer.active ? "\(mixer.systemFrames)/\(mixer.systemCapacity) frames" : "Inactive")
        Dropped mic frames: \(mixer.droppedMicFrames)
        Dropped system frames: \(mixer.droppedSystemFrames)
        Mic underruns: \(mixer.micUnderruns)
        System underruns: \(mixer.systemUnderruns)
        Late blocks: \(mixer.lateBlocks)
        Max lateness: \(mixer.maxLatenessMilliseconds) ms
        Peak: \(mixer.active ? "\(mixer.peak)" : "Inactive")
        RMS: \(mixer.active ? "\(mixer.rms)" : "Inactive")
        """
    }

    nonisolated func handleTeamTalkMessage(_ message: TTMessage) {
        // Only these events affect TT Custom's state. TeamTalk also emits
        // high-rate state/activity notifications that the app does not use;
        // forwarding those to the main actor can starve SwiftUI and VoiceOver.
        switch message.nClientEvent {
        case CLIENTEVENT_CON_SUCCESS,
             CLIENTEVENT_CON_FAILED,
             CLIENTEVENT_CON_LOST,
             CLIENTEVENT_CMD_MYSELF_LOGGEDIN,
             CLIENTEVENT_CMD_CHANNEL_NEW,
             CLIENTEVENT_CMD_CHANNEL_UPDATE,
             CLIENTEVENT_CMD_CHANNEL_REMOVE,
             CLIENTEVENT_CMD_USER_JOINED,
             CLIENTEVENT_CMD_USER_LEFT,
             CLIENTEVENT_CMD_PROCESSING,
             CLIENTEVENT_CMD_ERROR,
             CLIENTEVENT_DESKTOPWINDOW_TRANSFER:
            break
        default:
            return
        }
        guard messageMailbox.enqueue(message) else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            for message in self.messageMailbox.drain() {
                self.processTeamTalkMessage(message)
            }
        }
    }

    func processTeamTalkMessage(_ message: TTMessage) {
        switch message.nClientEvent {
        case CLIENTEVENT_CON_SUCCESS:
            connectionLifecycle.markConnected()
            status = "Connected; logging in…"
            let command = client.login(
                nickname: nickname,
                username: username,
                password: password,
                clientName: "TT Custom iOS"
            )
            loginCommandID = command > 0 ? command : nil
            connectionLifecycle.markLoggingIn()
            if command <= 0 {
                status = "Login request failed"
            }
        case CLIENTEVENT_CON_FAILED:
            connectionLifecycle.fail("Connection failed")
            handleConnectionFailure("Connection failed", generation: connectionGeneration)
        case CLIENTEVENT_CON_LOST:
            connectionLifecycle.fail("Connection lost")
            handleConnectionFailure("Connection lost", generation: connectionGeneration)
        case CLIENTEVENT_CMD_MYSELF_LOGGEDIN:
            loggedIn = true
            connectionLifecycle.markLoggingIn()
            status = "Logged in; loading channels…"
            refreshServerChannels()
            joinRootWhenAvailable()
        case CLIENTEVENT_CMD_CHANNEL_NEW:
            refreshServerChannels()
            if channelCreationCommandID != nil {
                channelActionStatus = "Channel created"
                channelCreationCommandID = nil
            }
            joinRootWhenAvailable()
        case CLIENTEVENT_CMD_CHANNEL_UPDATE:
            refreshServerChannels()
            refreshChannelAudio()
            if channelAudioCommandID != nil {
                channelAudioStatus = "Channel audio settings applied"
                channelAudioCommandID = nil
            }
        case CLIENTEVENT_CMD_CHANNEL_REMOVE:
            refreshServerChannels()
        case CLIENTEVENT_CMD_USER_JOINED:
            let user = TeamTalkMessagePayload.user(from: message)
            let userID = user.nUserID
            if userID == client.myUserID {
                let joinedChannelName = pendingJoinChannelName ?? "channel"
                connected = true
                connectionTimeoutWorkItem?.cancel()
                connectionTimeoutWorkItem = nil
                joinCommandID = nil
                pendingJoinChannelName = nil
                pendingJoinIsRoot = false
                status = "Connected to \(joinedChannelName)"
                channelActionStatus = "Joined \(joinedChannelName)"
                connectionLifecycle.markJoined()
                refreshChannelAudio()
                if systemCallControlsEnabled {
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
                } else {
                    configureAudio()
                }
                return
            }
            addRemoteUser(user)
            joinedUserIDs.insert(userID)
            let command = client.subscribe(userID: userID, subscriptions: SUBSCRIBE_VOICE.rawValue)
            if command > 0 {
                subscriptionCommandIDs.insert(command)
            }
            applyReceiveBuffer(to: userID)
        case CLIENTEVENT_CMD_USER_LEFT:
            joinedUserIDs.remove(message.nSource)
            remoteUsers.removeAll { $0.id == message.nSource }
        case CLIENTEVENT_CMD_PROCESSING:
            if message.nSource == channelCreationCommandID, !TeamTalkMessagePayload.isActive(message) {
                channelActionStatus = "Channel created"
                channelCreationCommandID = nil
                refreshServerChannels()
                break
            }
            guard message.nSource == channelAudioCommandID else { break }
            if TeamTalkMessagePayload.isActive(message) {
                channelAudioStatus = "Applying channel audio settings…"
            } else {
                channelAudioStatus = "Channel audio settings applied"
                channelAudioCommandID = nil
                refreshChannelAudio()
            }
        case CLIENTEVENT_CMD_ERROR:
            let error = TeamTalkMessagePayload.clientError(from: message)
            if message.nSource == channelAudioCommandID {
                channelAudioCommandID = nil
                channelAudioStatus = "Channel audio update failed: \(TeamTalkString.clientError(error))"
                return
            }
            if subscriptionCommandIDs.remove(message.nSource) != nil {
                if error.nErrorNo == CMDERR_USER_NOT_FOUND.rawValue {
                    // A user can leave between USER_JOINED and SUBSCRIBE. This is harmless.
                    joinedUserIDs.remove(message.nSource)
                    return
                }
                status = "Voice subscription failed: \(TeamTalkString.clientError(error))"
                return
            }
            if message.nSource == loginCommandID {
                status = "Login failed: \(TeamTalkString.clientError(error))"
            } else if message.nSource == joinCommandID {
                let wasRootJoin = pendingJoinIsRoot
                let channelName = pendingJoinChannelName ?? "channel"
                joinCommandID = nil
                pendingJoinChannelName = nil
                pendingJoinIsRoot = false
                if wasRootJoin { didRequestRootJoin = false }
                let reason = TeamTalkString.clientError(error)
                status = "Channel join failed: \(reason)"
                channelActionStatus = "Could not join \(channelName): \(reason)"
            } else if message.nSource == channelCreationCommandID {
                channelCreationCommandID = nil
                channelActionStatus = "Channel creation failed: \(TeamTalkString.clientError(error))"
            } else {
                status = "Server error: \(TeamTalkString.clientError(error))"
            }
        case CLIENTEVENT_DESKTOPWINDOW_TRANSFER:
            handleDesktopTransfer(bytesRemaining: message.nBytesRemain)
        default:
            break
        }
    }

    func joinRootWhenAvailable() {
        guard loggedIn, !didRequestRootJoin else { return }
        let rootID = client.rootChannelID
        guard rootID > 0 else {
            status = "Logged in; waiting for root channel…"
            scheduleRootJoinRetry()
            return
        }
        let command = client.joinChannel(id: rootID)
        guard command > 0 else {
            status = "Could not request root channel"
            return
        }
        didRequestRootJoin = true
        joinCommandID = command
        pendingJoinChannelName = "root channel"
        pendingJoinIsRoot = true
        connectionLifecycle.markJoiningRoot()
        status = "Joining root channel…"
    }

    private func scheduleRootJoinRetry() {
        guard rootJoinWorkItem == nil else { return }
        let generation = connectionGeneration
        let workItem = DispatchWorkItem { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.connectionGeneration == generation else { return }
                self.rootJoinWorkItem = nil
                self.joinRootWhenAvailable()
            }
        }
        rootJoinWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: workItem)
    }

    func startPolling() {
        pollTimer?.setEventHandler {}
        pollTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(
            flags: .strict,
            queue: DispatchQueue(label: "com.derrick.ttcustom.teamtalk-poll", qos: .userInitiated)
        )
        let client = self.client
        timer.schedule(
            deadline: .now(),
            repeating: .milliseconds(50),
            leeway: .milliseconds(5)
        )
        timer.setEventHandler {
            client.pollMessages()
        }
        timer.resume()
        pollTimer = timer
    }

    func scheduleConnectionTimeout(generation: UInt64) {
        connectionTimeoutWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.connectionGeneration == generation else { return }
                self.handleConnectionFailure("Connection timed out", generation: generation)
            }
        }
        connectionTimeoutWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 15, execute: workItem)
    }

    func handleConnectionFailure(_ message: String, generation: UInt64? = nil) {
        if let generation, generation != connectionGeneration { return }
        connectionTimeoutWorkItem?.cancel()
        connectionTimeoutWorkItem = nil

        guard let delay = retryPolicy.delayBeforeRetry(after: connectionAttempt) else {
            finishConnection(with: "\(message) after \(retryPolicy.maximumAttempts) attempts")
            return
        }

        let nextAttempt = connectionAttempt + 1
        networkHealth.reconnectCount += 1
        status = "\(message); retrying \(nextAttempt)/\(retryPolicy.maximumAttempts)…"
        connectionRetryWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
                self.disconnect { [weak self] in
                guard let self else { return }
                    self.beginConnect(host: self.host, tcpPort: self.tcpPort, udpPort: self.udpPort, generation: self.connectionGeneration)
            }
        }
        connectionRetryWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }
}

