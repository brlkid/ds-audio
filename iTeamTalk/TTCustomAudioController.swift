import AVFoundation
import Foundation
import ScreenCaptureKit
@preconcurrency import TeamTalkKit

enum TTCustomAudioPhase: Equatable {
    case idle
    case configuring
    case ready
    case sharing
    case stopping
}

// Diagnostic C switch: keep microphone input but leave TeamTalk's output
// AudioUnit closed, isolating output callbacks from the shared session.
private let ttCustomDisableTeamTalkOutputForABTest = false
// Diagnostic D switch: leave networking/UI active but do not claim any audio
// device or AVAudioSession. This isolates the session from TeamTalk traffic.
private let ttCustomDisableAllAudioForABTest = false
let ttCustomUsesAppleAudioPipeline = false

@MainActor
extension TTCustomSession {
func setTransmit(_ enabled: Bool) {
        if sharingSystemAudio {
            transmitting = enabled
            audioMixer?.setMicrophoneEnabled(enabled)
            return
        }
        if let appleAudioPipeline {
            appleAudioPipeline.setMicrophoneEnabled(enabled)
            transmitting = enabled
            return
        }
        if audioConfigured {
            guard client.enableVoiceTransmission(enabled) else {
                if enabled {
                    // The native audio unit can briefly lose its transmission
                    // handle during an AVAudioSession/CallKit route change.
                    // Rebuild the duplex device and retry instead of leaving
                    // the user permanently unable to unmute.
                    transmitting = true
                    audioConfigured = false
                    status = "Restarting microphone…"
                    configureAudio()
                } else {
                    status = "Could not mute microphone"
                }
                return
            }
            transmitting = enabled
            status = enabled ? "Microphone enabled" : "Microphone muted"
            return
        }
        guard enabled else {
            transmitting = false
            return
        }
        // The initial channel join can race audio-device setup. configureAudio
        // will enable transmission after the input device is ready.
        configureAudio()
        return
    }

    func setSystemAudioSharing(_ enabled: Bool) {
        if enabled {
            startSystemAudioSharing()
        } else {
            stopSystemAudioSharing(reconfigure: true)
        }
    }

    func setIncludeScreenVideo(_ enabled: Bool) {
        includeScreenVideo = enabled
        UserDefaults.standard.set(enabled, forKey: "ttcustom.includeScreenVideo")
        status = enabled
            ? "Screen video enabled for the next share"
            : "Screen video disabled for the next share"
    }

    func setSystemAudioMuted(_ muted: Bool) {
        guard sharingSystemAudio else { return }
        systemAudioMuted = muted
        audioMixer?.setSystemAudioEnabled(!muted)
    }

    func setMicGain(_ value: Double) {
        micGain = min(2, max(0, value))
        UserDefaults.standard.set(micGain, forKey: "ttcustom.micGain")
        audioMixer?.setMicGain(micGain)
    }

    func setSystemAudioGain(_ value: Double) {
        systemAudioGain = min(2, max(0, value))
        UserDefaults.standard.set(systemAudioGain, forKey: "ttcustom.systemAudioGain")
        audioMixer?.setSystemGain(systemAudioGain)
    }

    func setMasterTransmitGain(_ value: Double) {
        masterTransmitGain = min(2, max(0, value))
        UserDefaults.standard.set(masterTransmitGain, forKey: "ttcustom.masterTransmitGain")
        audioMixer?.setMasterGain(masterTransmitGain)
    }

    func setOutputVolume(_ value: Double) {
        outputVolume = min(200, max(0, value.rounded()))
        UserDefaults.standard.set(outputVolume, forKey: "ttcustom.outputVolume")
        client.setSoundOutputVolume(ttCustomOutputVolume(outputVolume))
    }

    func setAutomaticGainControl(_ enabled: Bool) {
        automaticGainControl = enabled
        audioMixer?.setAutomaticGainControl(enabled)
        UserDefaults.standard.set(enabled, forKey: "ttcustom.automaticGainControl")
        if connected && !sharingSystemAudio { configureAudio() }
    }

    func setNoiseGateEnabled(_ enabled: Bool) {
        noiseGateEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "ttcustom.noiseGate")
        audioMixer?.setNoiseGateEnabled(enabled)
    }

    func setCompressorEnabled(_ enabled: Bool) {
        compressorEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "ttcustom.compressor")
        audioMixer?.setCompressorEnabled(enabled)
    }

    func setLimiterEnabled(_ enabled: Bool) {
        limiterEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "ttcustom.limiter")
        audioMixer?.setLimiterEnabled(enabled)
    }

    func refreshAudioStats() {
        let session = AVAudioSession.sharedInstance()
        let localAudioHealth = TTCustomAudioHealth(
            sampleRate: session.sampleRate,
            bufferDuration: session.ioBufferDuration,
            inputRoute: session.currentRoute.inputs.first?.portName ?? "No input",
            outputRoute: session.currentRoute.outputs.first?.portName ?? "No output",
            mixerStats: audioMixer?.snapshot() ?? TTCustomMixerStats()
        )
        if audioHealth != localAudioHealth {
            audioHealth = localAudioHealth
        }
        guard !networkStatsRefreshInFlight else { return }
        networkStatsRefreshInFlight = true
        let client = self.client
        let userIDs = remoteUsers.map(\.id)
        let shouldPing = connected && Date().timeIntervalSince(lastDiagnosticsPing) >= 5
        if shouldPing { lastDiagnosticsPing = Date() }
        let reconnectCount = networkHealth.reconnectCount
        DispatchQueue.global(qos: .utility).async { [weak self] in
            if shouldPing { _ = client.ping() }
            let statistics = client.networkStatistics
            let users = userIDs.map { ($0, client.userNetworkStatistics(userID: $0)) }
            let health = TTCustomNetworkHealth(
                statisticsAvailable: statistics.isAvailable,
                udpPingMilliseconds: statistics.udpPingMilliseconds,
                tcpPingMilliseconds: statistics.tcpPingMilliseconds,
                tcpServerSilenceSeconds: statistics.tcpServerSilenceSeconds,
                udpServerSilenceSeconds: statistics.udpServerSilenceSeconds,
                soundInputDelayMilliseconds: statistics.soundInputDelayMilliseconds,
                reconnectCount: reconnectCount,
                voiceBytesSent: statistics.voiceBytesSent,
                voiceBytesReceived: statistics.voiceBytesReceived
            )
            DispatchQueue.main.async {
                guard let self else { return }
                self.networkStatsRefreshInFlight = false
                if self.networkHealth != health { self.networkHealth = health }
                for (userID, userStatistics) in users {
                    guard let index = self.remoteUsers.firstIndex(where: { $0.id == userID }) else { continue }
                    self.remoteUsers[index].voicePacketsReceived = userStatistics.voicePacketsReceived
                    self.remoteUsers[index].voicePacketsLost = userStatistics.voicePacketsLost
                }
            }
        }
    }

    func flushAndRestartAudio() {
        guard connected else {
            status = "Connect to a server before restarting audio"
            return
        }

        if sharingSystemAudio {
            // Keep ScreenCaptureKit alive, but reset the TeamTalk output and
            // mixer queues so the current gain values take effect cleanly.
            audioMixer?.flushBuffers()
            _ = client.enableVoiceTransmission(false)
            client.closeSoundDuplexDevices()
            client.closeSoundDevices()
            guard prepareAudioSession(),
                  client.initSoundOutputDevice(id: echoCancellation ? TeamTalkSoundDeviceID.voiceProcessingIO : TeamTalkSoundDeviceID.remoteIO) else {
                status = "Could not restart audio output"
                return
            }
            guard activateAudioSession() else { return }
            client.setSoundOutputVolume(ttCustomOutputVolume(outputVolume))
            audioMixer?.setMicGain(micGain)
            audioMixer?.setSystemGain(systemAudioGain)
            audioMixer?.setMasterGain(masterTransmitGain)
            audioMixer?.setAutomaticGainControl(automaticGainControl)
            audioMixer?.setNoiseGateEnabled(noiseGateEnabled)
            audioMixer?.setCompressorEnabled(compressorEnabled)
            audioMixer?.setLimiterEnabled(limiterEnabled)
            status = "Audio buffers flushed; sharing continues"
        } else {
            configureAudio()
            status = "Audio session restarted"
        }
    }

    func startSystemAudioSharing() {
        guard audioPhase == .idle || audioPhase == .ready else { return }
        guard connected else {
            status = "Join a channel before sharing system audio"
            return
        }
        guard #available(iOS 27.0, *) else {
            status = "System audio sharing requires iOS 27 or later"
            return
        }

        audioPhase = .configuring
        client.enableVoiceTransmission(false)
        client.closeSoundDuplexDevices()
        client.closeSoundDevices()
        guard prepareAudioSession(),
              client.initSoundOutputDevice(id: echoCancellation ? TeamTalkSoundDeviceID.voiceProcessingIO : TeamTalkSoundDeviceID.remoteIO) else {
            status = "Could not prepare audio for system sharing"
            audioPhase = .idle
            return
        }
        guard activateAudioSession() else {
            client.closeSoundDevices()
            audioPhase = .idle
            return
        }

        let mixer = TTCustomAudioMixer(client: client)
        do {
            try mixer.start(
                micEnabled: transmitting,
                systemEnabled: !systemAudioMuted,
                micGain: micGain,
                systemGain: systemAudioGain,
                masterGain: masterTransmitGain,
                automaticGainControl: automaticGainControl,
                noiseGateEnabled: noiseGateEnabled,
                compressorEnabled: compressorEnabled,
                limiterEnabled: limiterEnabled,
                useEngineMicrophone: true
            )
        } catch {
            client.closeSoundDevices()
            status = "Could not start microphone mixer: \(error.localizedDescription)"
            audioPhase = .idle
            return
        }

        let capture = TTCustomSystemAudioCapture()
        capture.onAudio = { [weak mixer] samples in
            mixer?.appendSystemAudio(samples)
        }
        capture.onScreenFrame = { [weak self] frame in
            Task { @MainActor [weak self] in
                self?.enqueueDesktopFrame(frame)
            }
        }
        capture.onFailure = { [weak self] message in
            Task { @MainActor [weak self] in
                self?.stopSystemAudioSharing(reconfigure: true)
                self?.status = message
            }
        }
        audioMixer = mixer
        systemAudioCapture = capture
        sharingSystemAudio = true
        sharingScreenVideo = includeScreenVideo
        desktopFrameInFlight = false
        pendingDesktopFrame = nil
        audioPhase = .sharing
        status = includeScreenVideo
            ? "Choose an app or display to share audio and video"
            : "Choose an app or display to share system audio"
        capture.presentPicker(capturesMicrophone: false, capturesVideo: includeScreenVideo)
    }

    func stopSystemAudioSharing(reconfigure: Bool, completion: (() -> Void)? = nil) {
        guard audioPhase != .stopping else { return }
        audioPhase = .stopping
        if #available(iOS 27.0, *) {
            let capture = systemAudioCapture as? TTCustomSystemAudioCapture
            capture?.stop { [weak self] in
                self?.finishStoppingSystemAudio(reconfigure: reconfigure, completion: completion)
            }
            if capture == nil {
                finishStoppingSystemAudio(reconfigure: reconfigure, completion: completion)
            }
        } else {
            finishStoppingSystemAudio(reconfigure: reconfigure, completion: completion)
        }
    }

    func finishStoppingSystemAudio(reconfigure: Bool, completion: (() -> Void)?) {
        systemAudioCapture = nil
        audioMixer?.stop()
        audioMixer = nil
        pendingDesktopFrame = nil
        desktopFrameInFlight = false
        if sharingScreenVideo {
            client.closeDesktopFrameStream()
        }
        sharingSystemAudio = false
        sharingScreenVideo = false
        audioPhase = .idle
        systemAudioMuted = false
        if reconfigure, connected {
            configureAudio()
        }
        completion?()
    }

    private func enqueueDesktopFrame(_ frame: TeamTalkDesktopFrame) {
        guard sharingSystemAudio, sharingScreenVideo else { return }
        // Keep only the newest frame while TeamTalk is transmitting. This
        // bounds memory and latency instead of allowing a stale frame queue.
        guard !desktopFrameInFlight else {
            pendingDesktopFrame = frame
            return
        }
        sendDesktopFrame(frame)
    }

    private func sendDesktopFrame(_ frame: TeamTalkDesktopFrame) {
        guard sharingSystemAudio, sharingScreenVideo else { return }
        let result = client.sendDesktopFrame(frame)
        guard result > 0 else {
            desktopFrameInFlight = false
            return
        }
        desktopFrameInFlight = true
    }

    func handleDesktopTransfer(bytesRemaining: Int32) {
        guard sharingScreenVideo, desktopFrameInFlight, bytesRemaining == 0 else { return }
        desktopFrameInFlight = false
        if let pendingDesktopFrame {
            self.pendingDesktopFrame = nil
            sendDesktopFrame(pendingDesktopFrame)
        }
    }

    func setEchoCancellation(_ enabled: Bool) {
        echoCancellation = enabled
        UserDefaults.standard.set(enabled, forKey: "ttcustom.echoCancellation")
        if connected { configureAudio() }
    }

    func setWebRTCEchoCancellation(_ enabled: Bool) {
        webrtcEchoCancellation = enabled
        UserDefaults.standard.set(enabled, forKey: "ttcustom.webrtcEchoCancellation")
        if connected { configureAudio() }
    }

    func configureAudio() {
        guard audioPhase != .configuring, audioPhase != .stopping else { return }
        audioPhase = .configuring
        if ttCustomDisableAllAudioForABTest {
            _ = client.enableVoiceTransmission(false)
            client.closeSoundDuplexDevices()
            client.closeSoundDevices()
            deactivateAudioSession()
            transmitting = false
            audioConfigured = true
            audioPhase = .ready
            status = "Connected • Network-only test (D)"
            return
        }
        guard prepareAudioSession() else {
            audioPhase = .idle
            return
        }

        // Preserve a user's mute choice when changing the audio-processing
        // mode. Initial channel entry still starts with transmission enabled.
        let shouldTransmit = audioConfigured ? transmitting : true
        _ = client.enableVoiceTransmission(false)
        transmitting = false
        audioConfigured = false
        let deviceID = echoCancellation
            ? TeamTalkSoundDeviceID.voiceProcessingIO
            : TeamTalkSoundDeviceID.remoteIO
        var preprocessor = TeamTalkAudioPreprocessor.makeWebRTCPreprocessor()
        preprocessor.webrtc.echocanceller.bEnable = webrtcEchoCancellation ? 1 : 0
        preprocessor.webrtc.noisesuppression.bEnable = noiseGateEnabled ? 1 : 0
        preprocessor.webrtc.gaincontroller2.adaptivedigital.bEnable = automaticGainControl ? 1 : 0
        let client = self.client
        Task { @MainActor [weak self] in
            guard let self else { return }
            let result = await client.configureNativeSoundDevices(
                inputID: deviceID,
                outputID: deviceID,
                preprocessor: preprocessor
            )
            guard self.connected, self.audioPhase == .configuring else {
                if self.audioPhase == .configuring { self.audioPhase = .idle }
                return
            }
            guard result.inputReady && (ttCustomDisableTeamTalkOutputForABTest || result.outputReady) else {
                client.closeSoundDuplexDevices()
                client.closeSoundDevices()
                self.audioPhase = .idle
                self.status = "TeamTalk audio device failed to initialize"
                return
            }
            if !ttCustomDisableTeamTalkOutputForABTest {
                client.setSoundOutputVolume(ttCustomOutputVolume(self.outputVolume))
            }
            guard self.activateAudioSession() else {
                self.audioPhase = .idle
                return
            }
            self.scheduleSpeakerRouteEnforcement()
            for user in client.channelUsers(id: client.myChannelID) {
                self.addRemoteUser(user)
            }
            self.audioConfigured = true
            if shouldTransmit {
                guard client.enableVoiceTransmission(true) else {
                    self.transmitting = false
                    self.status = "Microphone device is ready, but transmission could not be enabled"
                    self.audioPhase = .ready
                    return
                }
                self.transmitting = true
            }
            self.audioPhase = .ready
            self.status = ttCustomDisableTeamTalkOutputForABTest
                ? "Connected • Input-only test (C)"
                : (self.echoCancellation
                    ? (self.webrtcEchoCancellation
                        ? "Connected • Voice Processing + WebRTC echo cancellation"
                        : "Connected • Voice Processing enabled")
                    : (self.webrtcEchoCancellation
                        ? "Connected • WebRTC echo cancellation only"
                        : "Connected • Echo cancellation disabled"))
        }
    }

    func finishConnection(with message: String) {
        pollTimer?.setEventHandler {}
        pollTimer?.cancel()
        pollTimer = nil
        disconnect { [weak self] in
            self?.status = message
        }
    }
}

