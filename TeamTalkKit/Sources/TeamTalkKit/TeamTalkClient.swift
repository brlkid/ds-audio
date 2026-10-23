import Foundation
import TeamTalkC

public protocol TeamTalkMessageObserver: AnyObject {
    func handleTeamTalkMessage(_ message: TTMessage)
}

public typealias TeamTalkRawAudioBlockHandler = @Sendable (_ samples: [Int16], _ sampleRate: Int32, _ channels: Int32, _ userID: Int32) -> Void

final class TeamTalkMessageHandler {
    weak var value: TeamTalkMessageObserver?

    init(value: TeamTalkMessageObserver) {
        self.value = value
    }
}

public struct TeamTalkClientFlags: OptionSet {
    public let rawValue: UInt32

    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    public static let connected = TeamTalkClientFlags(rawValue: CLIENT_CONNECTED.rawValue)
    public static let authorized = TeamTalkClientFlags(rawValue: CLIENT_AUTHORIZED.rawValue)
    public static let soundInputReady = TeamTalkClientFlags(rawValue: CLIENT_SNDINPUT_READY.rawValue)
    public static let transmittingVoice = TeamTalkClientFlags(rawValue: CLIENT_TX_VOICE.rawValue)
    public static let voiceActivated = TeamTalkClientFlags(rawValue: CLIENT_SNDINPUT_VOICEACTIVATED.rawValue)
    public static let voiceActive = TeamTalkClientFlags(rawValue: CLIENT_SNDINPUT_VOICEACTIVE.rawValue)
}

public struct TeamTalkNativeAudioSetupResult: Sendable {
    public let inputReady: Bool
    public let outputReady: Bool

    public init(inputReady: Bool, outputReady: Bool) {
        self.inputReady = inputReady
        self.outputReady = outputReady
    }
}

public struct TeamTalkEncryptionConfiguration {
    public var caCertificate: String
    public var certificate: String
    public var privateKey: String
    public var verifyPeer: Bool

    public init(
        caCertificate: String = "",
        certificate: String = "",
        privateKey: String = "",
        verifyPeer: Bool = false
    ) {
        self.caCertificate = caCertificate
        self.certificate = certificate
        self.privateKey = privateKey
        self.verifyPeer = verifyPeer
    }
}

public struct TeamTalkClientNetworkStatistics: Sendable {
    public let isAvailable: Bool
    public let udpBytesSent: Int64
    public let udpBytesReceived: Int64
    public let voiceBytesSent: Int64
    public let voiceBytesReceived: Int64
    public let udpPingMilliseconds: Int32
    public let tcpPingMilliseconds: Int32
    public let tcpServerSilenceSeconds: Int32
    public let udpServerSilenceSeconds: Int32
    public let soundInputDelayMilliseconds: Int32

    public var hasUdpPing: Bool { udpPingMilliseconds >= 0 }
    public var hasTcpPing: Bool { tcpPingMilliseconds >= 0 }

    public init(
        isAvailable: Bool = false,
        udpBytesSent: Int64 = 0,
        udpBytesReceived: Int64 = 0,
        voiceBytesSent: Int64 = 0,
        voiceBytesReceived: Int64 = 0,
        udpPingMilliseconds: Int32 = -1,
        tcpPingMilliseconds: Int32 = -1,
        tcpServerSilenceSeconds: Int32 = 0,
        udpServerSilenceSeconds: Int32 = 0,
        soundInputDelayMilliseconds: Int32 = 0
    ) {
        self.isAvailable = isAvailable
        self.udpBytesSent = udpBytesSent
        self.udpBytesReceived = udpBytesReceived
        self.voiceBytesSent = voiceBytesSent
        self.voiceBytesReceived = voiceBytesReceived
        self.udpPingMilliseconds = udpPingMilliseconds
        self.tcpPingMilliseconds = tcpPingMilliseconds
        self.tcpServerSilenceSeconds = tcpServerSilenceSeconds
        self.udpServerSilenceSeconds = udpServerSilenceSeconds
        self.soundInputDelayMilliseconds = soundInputDelayMilliseconds
    }
}

public struct TeamTalkUserNetworkStatistics: Sendable {
    public let voicePacketsReceived: Int64
    public let voicePacketsLost: Int64

    public var voicePacketLossPercent: Double {
        let total = voicePacketsReceived + voicePacketsLost
        guard total > 0 else { return 0 }
        return Double(voicePacketsLost) / Double(total) * 100
    }

    public init(voicePacketsReceived: Int64 = 0, voicePacketsLost: Int64 = 0) {
        self.voicePacketsReceived = voicePacketsReceived
        self.voicePacketsLost = voicePacketsLost
    }
}

public enum TeamTalkSoundDeviceID {
    public static let voiceProcessingIO = TT_SOUNDDEVICE_ID_VOICEPREPROCESSINGIO
    public static let remoteIO = TT_SOUNDDEVICE_ID_REMOTEIO
}
public final class TeamTalkClient: @unchecked Sendable {
    public static let shared = TeamTalkClient()

    private var instance: UnsafeMutableRawPointer?
    private var observers = [TeamTalkMessageHandler]()
    private let stateQueue = DispatchQueue(label: "com.derrick.teamtalkkit.client-state")
    /// TeamTalk's C API is stateful and the poll API may run concurrently with
    /// commands from the UI/audio queues. A dedicated serial executor keeps
    /// native calls ordered without holding a lock while client callbacks run.
    private let nativeQueue = DispatchQueue(label: "com.derrick.teamtalkkit.client-native")
    private var rawAudioBlockHandler: TeamTalkRawAudioBlockHandler?

    private init() {}

    private func withNative<T>(_ body: (UnsafeMutableRawPointer?) -> T) -> T {
        nativeQueue.sync {
            body(stateQueue.sync { instance })
        }
    }

    public static func touchLinkerSymbolsForTests() {
        if TT_GetRootChannelID(nil) == 1 {
            TT_CloseSoundOutputDevice(nil)
            TT_StartSoundLoopbackTest(0, 0, 0, 0, 0, nil)
            TT_CloseSoundLoopbackTest(nil)
            TT_CloseSoundInputDevice(nil)
            TT_GetSoundDevices(nil, nil)
            TT_DoLeaveChannel(nil)
            TT_GetRootChannelID(nil)
            TT_DBG_SetSoundInputTone(nil, 0, 0)
            TT_DoLogin(nil, "", "", "")
            TT_RestartSoundSystem()
        }
    }

    public var flags: TeamTalkClientFlags {
        withNative { TeamTalkClientFlags(rawValue: TT_GetFlags($0)) }
    }

    public var isStarted: Bool {
        stateQueue.sync { instance != nil }
    }

    public var isConnected: Bool {
        flags.contains(.connected)
    }

    public var isSoundInputReady: Bool {
        flags.contains(.soundInputReady)
    }

    public var isAuthorized: Bool {
        flags.contains(.authorized)
    }

    public var isVoiceTransmitting: Bool {
        isTransmitting(STREAMTYPE_VOICE)
    }

    public var myUserID: Int32 {
        withNative { TT_GetMyUserID($0) }
    }

    public var myChannelID: Int32 {
        withNative { TT_GetMyChannelID($0) }
    }

    public var myUserRights: UInt32 {
        withNative { TT_GetMyUserRights($0) }
    }

    public var myUserType: UInt32 {
        withNative { instance in
            var user = User()
            guard TT_GetUser(instance, TT_GetMyUserID(instance), &user) != 0 else { return 0 }
            return user.uUserType
        }
    }

    public var rootChannelID: Int32 {
        withNative { TT_GetRootChannelID($0) }
    }

    public var soundOutputVolume: Int32 {
        withNative { TT_GetSoundOutputVolume($0) }
    }

    public var soundInputGainLevel: Int32 {
        withNative { TT_GetSoundInputGainLevel($0) }
    }

    public var networkStatistics: TeamTalkClientNetworkStatistics {
        withNative { instance in
            var statistics = ClientStatistics()
            guard TT_GetClientStatistics(instance, &statistics) != 0 else {
                return TeamTalkClientNetworkStatistics()
            }
            return TeamTalkClientNetworkStatistics(
                isAvailable: true,
                udpBytesSent: statistics.nUdpBytesSent,
                udpBytesReceived: statistics.nUdpBytesRecv,
                voiceBytesSent: statistics.nVoiceBytesSent,
                voiceBytesReceived: statistics.nVoiceBytesRecv,
                udpPingMilliseconds: statistics.nUdpPingTimeMs,
                tcpPingMilliseconds: statistics.nTcpPingTimeMs,
                tcpServerSilenceSeconds: statistics.nTcpServerSilenceSec,
                udpServerSilenceSeconds: statistics.nUdpServerSilenceSec,
                soundInputDelayMilliseconds: statistics.nSoundInputDeviceDelayMSec
            )
        }
    }

    @discardableResult
    public func ping() -> Int32 {
        withNative { TT_DoPing($0) }
    }

    public func userNetworkStatistics(userID: Int32) -> TeamTalkUserNetworkStatistics {
        withNative { instance in
            var statistics = UserStatistics()
            guard TT_GetUserStatistics(instance, userID, &statistics) != 0 else {
                return TeamTalkUserNetworkStatistics()
            }
            return TeamTalkUserNetworkStatistics(
                voicePacketsReceived: statistics.nVoicePacketsRecv,
                voicePacketsLost: statistics.nVoicePacketsLost
            )
        }
    }

    public var version: String {
        String(cString: TT_GetVersion())
    }

    public func start(licenseName: String, licenseKey: String) {
        guard !isStarted else {
            return
        }

        nativeQueue.sync {
            TT_SetLicenseInformation(licenseName, licenseKey)
            let newInstance = TT_InitTeamTalkPoll()
            stateQueue.sync { instance = newInstance }
        }
    }

    public func close() {
        nativeQueue.sync {
            guard let instance = stateQueue.sync(execute: { self.instance }) else {
                return
            }

            TT_CloseSoundDuplexDevices(instance)
            TT_CloseSoundInputDevice(instance)
            TT_CloseSoundOutputDevice(instance)
            TT_CloseTeamTalk(instance)
            stateQueue.sync {
                self.instance = nil
                self.observers.removeAll()
            }
        }
    }

    @discardableResult
    public func connect(toHost host: String, tcpPort: Int32, udpPort: Int32, encrypted: Bool) -> Bool {
        withNative { instance in
            TT_Connect(instance, host, tcpPort, udpPort, 0, 0, encrypted ? 1 : 0) != 0
        }
    }

    public func disconnect() {
        _ = withNative { TT_Disconnect($0) }
    }

    @discardableResult
    public func login(nickname: String, username: String, password: String, clientName: String) -> Int32 {
        withNative { TT_DoLoginEx($0, nickname, username, password, clientName) }
    }

    public func channelID(fromPath path: String) -> Int32 {
        withNative { TT_GetChannelIDFromPath($0, path) }
    }

    public func isChannelOperator(userID: Int32? = nil, channelID: Int32) -> Bool {
        let resolvedUserID = userID ?? myUserID
        return withNative { TT_IsChannelOperator($0, resolvedUserID, channelID) != 0 }
    }

    @discardableResult
    public func setChannelOperator(userID: Int32, channelID: Int32, enabled: Bool) -> Int32 {
        withNative { TT_DoChannelOp($0, userID, channelID, enabled ? 1 : 0) }
    }

    public func withServerProperties<T>(_ body: (inout ServerProperties) -> T) -> T {
        withNative { instance in
            var properties = ServerProperties()
            TT_GetServerProperties(instance, &properties)
            return body(&properties)
        }
    }

    public func withChannel<T>(id channelID: Int32, _ body: (inout Channel) -> T) -> T {
        withNative { instance in
            var channel = Channel()
            TT_GetChannel(instance, channelID, &channel)
            return body(&channel)
        }
    }

    public func withUser<T>(id userID: Int32, _ body: (inout User) -> T) -> T {
        withNative { instance in
            var user = User()
            TT_GetUser(instance, userID, &user)
            return body(&user)
        }
    }

    public func channelUsers(id channelID: Int32) -> [User] {
        withNative { instance in
            var count: Int32 = 0
            guard TT_GetChannelUsers(instance, channelID, nil, &count) != 0, count > 0 else { return [] }
            var users = [User](repeating: User(), count: Int(count))
            let success = users.withUnsafeMutableBufferPointer { buffer in
                TT_GetChannelUsers(instance, channelID, buffer.baseAddress, &count)
            }
            guard success != 0 else { return [] }
            return Array(users.prefix(Int(count)))
        }
    }

    public var serverChannels: [Channel] {
        withNative { instance in
            var count: Int32 = 0
            guard TT_GetServerChannels(instance, nil, &count) != 0, count > 0 else { return [] }
            var channels = [Channel](repeating: Channel(), count: Int(count))
            let success = channels.withUnsafeMutableBufferPointer { buffer in
                TT_GetServerChannels(instance, buffer.baseAddress, &count)
            }
            guard success != 0 else { return [] }
            return Array(channels.prefix(Int(count)))
        }
    }

    @discardableResult
    public func join(channel: inout Channel) -> Int32 {
        withNative { TT_DoJoinChannel($0, &channel) }
    }

    @discardableResult
    public func joinChannel(id channelID: Int32, password: String = "") -> Int32 {
        withNative { TT_DoJoinChannelByID($0, channelID, password) }
    }

    @discardableResult
    public func makeChannel(_ channel: inout Channel) -> Int32 {
        withNative { TT_DoMakeChannel($0, &channel) }
    }

    @discardableResult
    public func update(channel: inout Channel) -> Int32 {
        withNative { TT_DoUpdateChannel($0, &channel) }
    }

    @discardableResult
    public func removeChannel(id channelID: Int32) -> Int32 {
        withNative { TT_DoRemoveChannel($0, channelID) }
    }

    @discardableResult
    public func changeNickname(_ nickname: String) -> Int32 {
        withNative { TT_DoChangeNickname($0, nickname) }
    }

    @discardableResult
    public func changeStatus(mode: Int32, message: String = "") -> Int32 {
        withNative { TT_DoChangeStatus($0, mode, message) }
    }

    @discardableResult
    public func kickUser(id userID: Int32, fromChannelID channelID: Int32) -> Int32 {
        withNative { TT_DoKickUser($0, userID, channelID) }
    }

    @discardableResult
    public func banUser(id userID: Int32, fromChannelID channelID: Int32) -> Int32 {
        withNative { TT_DoBanUser($0, userID, channelID) }
    }

    @discardableResult
    public func moveUser(id userID: Int32, toChannelID channelID: Int32) -> Int32 {
        withNative { TT_DoMoveUser($0, userID, channelID) }
    }

    @discardableResult
    public func sendTextMessage(_ message: inout TextMessage) -> Int32 {
        withNative { TT_DoTextMessage($0, &message) }
    }

    @discardableResult
    public func sendTextMessage(_ message: TextMessage, content: String) -> Bool {
        TeamTalkTextMessageFactory.messages(from: message, content: content).reduce(true) { sent, textMessage in
            var textMessage = textMessage
            return sent && sendTextMessage(&textMessage) > 0
        }
    }

    @discardableResult
    public func setEncryptionContext(_ encryption: inout EncryptionContext) -> Bool {
        withNative { TT_SetEncryptionContext($0, &encryption) != 0 }
    }

    @discardableResult
    public func configureEncryption(
        _ configuration: TeamTalkEncryptionConfiguration,
        temporaryDirectory: URL? = nil
    ) throws -> Bool {
        var encryption = EncryptionContext()
        let directory: URL
        if let temporaryDirectory {
            directory = temporaryDirectory
        } else {
            directory = try FileManager.default.url(
                for: .autosavedInformationDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
        }

        let caCertificateURL = directory.appendingPathComponent("ca_cert.pem")
        let certificateURL = directory.appendingPathComponent("cert.pem")
        let privateKeyURL = directory.appendingPathComponent("key.pem")
        let temporaryFiles = [
            (configuration.caCertificate, caCertificateURL, TeamTalkEncryptionStringProperty.caFile),
            (configuration.certificate, certificateURL, TeamTalkEncryptionStringProperty.certificateFile),
            (configuration.privateKey, privateKeyURL, TeamTalkEncryptionStringProperty.privateKeyFile)
        ]

        defer {
            for (_, url, _) in temporaryFiles {
                try? FileManager.default.removeItem(at: url)
            }
        }

        for (contents, url, property) in temporaryFiles where contents.isEmpty == false {
            try contents.write(to: url, atomically: true, encoding: .utf8)
            TeamTalkString.setEncryption(property, on: &encryption, to: url.path)
        }

        encryption.bVerifyPeer = configuration.verifyPeer ? 1 : 0
        encryption.nVerifyDepth = configuration.verifyPeer ? 0 : -1

        return setEncryptionContext(&encryption)
    }

    public func addObserver(_ observer: TeamTalkMessageObserver) {
        stateQueue.sync {
            if observers.contains(where: { $0.value === observer }) { return }
            observers.append(TeamTalkMessageHandler(value: observer))
        }
    }

    public func removeObserver(_ observer: TeamTalkMessageObserver) {
        stateQueue.sync {
            observers.removeAll { $0.value === observer || $0.value == nil }
        }
    }

    public func removeAllObservers() {
        stateQueue.sync { observers.removeAll() }
    }

    public func pollMessages() {
        // Never let a high-rate audio/event stream monopolize the polling
        // queue. The next timer tick will continue draining the backlog.
        var processedMessages = 0
        while processedMessages < 128 {
            let nextMessage: TTMessage? = nativeQueue.sync {
                guard let instance = stateQueue.sync(execute: { self.instance }) else { return nil }
                var message = TTMessage()
                var waitMSec: Int32 = 0
                return TT_GetMessage(instance, &message, &waitMSec) != 0 ? message : nil
            }

            guard let message = nextMessage else { return }
            processedMessages += 1
            if message.nClientEvent == CLIENTEVENT_USER_AUDIOBLOCK {
                deliverRawAudioBlock(for: message.nSource)
            }
            // These events are intentionally consumed by the transport layer;
            // forwarding them to every legacy observer can create an event
            // storm on the main actor. Raw audio has its own callback above.
            if message.nClientEvent == CLIENTEVENT_AUDIOINPUT ||
                message.nClientEvent == CLIENTEVENT_USER_AUDIOBLOCK {
                continue
            }
            let currentObservers: [TeamTalkMessageObserver] = stateQueue.sync {
                observers.removeAll { $0.value == nil }
                return observers.compactMap(\.value)
            }
            for observer in currentObservers {
                observer.handleTeamTalkMessage(message)
            }
        }
    }

    /// Initializes TeamTalk's native sound devices and input preprocessing on
    /// the native serial queue. The completion resumes off-main; callers can
    /// hop back to their UI actor after awaiting this method.
    public func configureNativeSoundDevices(
        inputID: Int32,
        outputID: Int32,
        preprocessor: AudioPreprocessor
    ) async -> TeamTalkNativeAudioSetupResult {
        await withCheckedContinuation { continuation in
            nativeQueue.async {
                let instance = self.stateQueue.sync { self.instance }
                guard let instance else {
                    continuation.resume(returning: TeamTalkNativeAudioSetupResult(inputReady: false, outputReady: false))
                    return
                }
                TT_CloseSoundDuplexDevices(instance)
                TT_CloseSoundInputDevice(instance)
                TT_CloseSoundOutputDevice(instance)
                let inputReady = TT_InitSoundInputDevice(instance, inputID) != 0
                let outputReady = TT_InitSoundOutputDevice(instance, outputID) != 0
                var preprocessor = preprocessor
                let preprocessReady = inputReady && TT_SetSoundInputPreprocessEx(instance, &preprocessor) != 0
                continuation.resume(returning: TeamTalkNativeAudioSetupResult(
                    inputReady: preprocessReady,
                    outputReady: outputReady
                ))
            }
        }
    }

    /// Installs a raw decoded-audio callback. The callback is invoked from
    /// TeamTalk's polling queue, never from the main actor. The receiver must
    /// copy or enqueue the samples before returning.
    public func setRawAudioBlockHandler(_ handler: TeamTalkRawAudioBlockHandler?) {
        stateQueue.sync { rawAudioBlockHandler = handler }
    }

    /// Enables TeamTalk's decoded mixed voice stream without opening a
    /// TeamTalk sound output device. This leaves capture and playback to the
    /// app's AVAudioEngine pipeline.
    @discardableResult
    public func enableRawMixedVoiceAudio(sampleRate: Int32 = 48_000, channels: Int32 = 1) -> Bool {
        withNative { instance in
            var format = AudioFormat(
                nAudioFmt: AFF_WAVE_FORMAT,
                nSampleRate: sampleRate,
                nChannels: channels
            )
            return TT_EnableAudioBlockEventEx(
                instance,
                TT_MUXED_USERID,
                STREAMTYPE_VOICE.rawValue,
                &format,
                1
            ) != 0
        }
    }

    public func disableRawMixedVoiceAudio() {
        _ = withNative {
            TT_EnableAudioBlockEventEx($0, TT_MUXED_USERID, STREAMTYPE_VOICE.rawValue, nil, 0)
        }
    }

    private func deliverRawAudioBlock(for userID: Int32) {
        let block = withNative { instance -> (samples: [Int16], sampleRate: Int32, channels: Int32)? in
            guard let audioBlock = TT_AcquireUserAudioBlock(instance, STREAMTYPE_VOICE.rawValue, userID) else { return nil }
            guard audioBlock.pointee.nSamples > 0,
                  audioBlock.pointee.nChannels > 0,
                  let rawAudio = audioBlock.pointee.lpRawAudio else {
                _ = TT_ReleaseUserAudioBlock(instance, audioBlock)
                return nil
            }
            let sampleCount = Int(audioBlock.pointee.nSamples) * Int(audioBlock.pointee.nChannels)
            let samples = Array(UnsafeBufferPointer(
                start: rawAudio.assumingMemoryBound(to: Int16.self),
                count: sampleCount
            ))
            let result = (samples, audioBlock.pointee.nSampleRate, audioBlock.pointee.nChannels)
            _ = TT_ReleaseUserAudioBlock(instance, audioBlock)
            return result
        }
        guard let block else { return }
        let handler = stateQueue.sync { rawAudioBlockHandler }
        handler?(block.samples, block.sampleRate, block.channels, userID)
    }

    public func isTransmitting(_ stream: StreamType) -> Bool {
        switch stream {
        case STREAMTYPE_VOICE:
            let currentFlags = flags
            return currentFlags.contains(.transmittingVoice) ||
                (currentFlags.contains(.voiceActivated) && currentFlags.contains(.voiceActive))
        default:
            return false
        }
    }

    @discardableResult
    public func enableVoiceTransmission(_ enabled: Bool) -> Bool {
        withNative { TT_EnableVoiceTransmission($0, enabled ? 1 : 0) != 0 }
    }

    @discardableResult
    public func enableVoiceActivation(_ enabled: Bool) -> Bool {
        withNative { TT_EnableVoiceActivation($0, enabled ? 1 : 0) != 0 }
    }

    /// Inserts one raw PCM audio block as the voice input stream.
    /// The caller owns the array; TeamTalk consumes the data before this call returns.
    @discardableResult
    public func insertAudioBlock(
        samples: [Int16],
        sampleRate: Int32 = 48_000,
        channels: Int32 = 1,
        streamID: Int32 = 1
    ) -> Bool {
        guard samples.isEmpty == false else { return false }
        var block = AudioBlock()
        block.nStreamID = streamID
        block.nSampleRate = sampleRate
        block.nChannels = channels
        block.nSamples = Int32(samples.count / max(1, Int(channels)))
        block.uSampleIndex = 0
        block.uStreamTypes = STREAMTYPE_VOICE.rawValue
        return withNative { instance in samples.withUnsafeBytes { rawBuffer in
            block.lpRawAudio = UnsafeMutableRawPointer(mutating: rawBuffer.baseAddress)
            return TT_InsertAudioBlock(instance, &block) != 0
        }}
    }

    /// Ends an injected raw voice stream.
    public func endInsertedAudioBlock() {
        _ = withNative { TT_InsertAudioBlock($0, nil) }
    }

    public func setVoiceActivationLevel(_ level: Int32) {
        _ = withNative { TT_SetVoiceActivationLevel($0, level) }
    }

    public func setSoundInputGainLevel(_ level: Int32) {
        _ = withNative { TT_SetSoundInputGainLevel($0, level) }
    }

    public func setSoundOutputVolume(_ volume: Int32) {
        _ = withNative { TT_SetSoundOutputVolume($0, volume) }
    }

    public func closeSoundDevices() {
        withNative {
            TT_CloseSoundInputDevice($0)
            TT_CloseSoundOutputDevice($0)
        }
    }

    public func closeSoundInputDevice() {
        _ = withNative { TT_CloseSoundInputDevice($0) }
    }

    @discardableResult
    public func initSoundInputDevice(id soundDeviceID: Int32) -> Bool {
        withNative { TT_InitSoundInputDevice($0, soundDeviceID) != 0 }
    }

    @discardableResult
    public func initSoundOutputDevice(id soundDeviceID: Int32) -> Bool {
        withNative { TT_InitSoundOutputDevice($0, soundDeviceID) != 0 }
    }

    /// Initializes input and output as one synchronized duplex device.
    /// This is required by the native iOS Voice-Processing I/O echo canceller.
    @discardableResult
    public func initSoundDuplexDevices(inputID: Int32, outputID: Int32) -> Bool {
        withNative { TT_InitSoundDuplexDevices($0, inputID, outputID) != 0 }
    }

    public func closeSoundDuplexDevices() {
        _ = withNative { TT_CloseSoundDuplexDevices($0) }
    }

    @discardableResult
    public func setSoundInputPreprocess(_ preprocessor: inout AudioPreprocessor) -> Bool {
        withNative { TT_SetSoundInputPreprocessEx($0, &preprocessor) != 0 }
    }

    /// Applies a per-user voice playout buffer. Zero restores TeamTalk's default.
    @discardableResult
    public func setUserAudioStreamBufferSize(userID: Int32, milliseconds: Int32) -> Bool {
        withNative { TT_SetUserAudioStreamBufferSize($0, userID, STREAMTYPE_VOICE.rawValue, milliseconds) != 0 }
    }

    /// Applies fixed/adaptive de-jitter control to one user's voice stream.
    @discardableResult
    public func setUserJitterControl(
        userID: Int32,
        fixedDelayMilliseconds: Int32,
        adaptive: Bool,
        maximumAdaptiveDelayMilliseconds: Int32
    ) -> Bool {
        var config = JitterConfig(
            nFixedDelayMSec: fixedDelayMilliseconds,
            bUseAdativeDejitter: adaptive ? 1 : 0,
            nMaxAdaptiveDelayMSec: maximumAdaptiveDelayMilliseconds,
            nActiveAdaptiveDelayMSec: 0
        )
        return withNative { TT_SetUserJitterControl($0, userID, STREAMTYPE_VOICE, &config) != 0 }
    }

    public func setUserMute(userID: Int32, stream: StreamType, muted: Bool) {
        _ = withNative { TT_SetUserMute($0, userID, stream, muted ? 1 : 0) }
    }

    public func setUserVolume(userID: Int32, stream: StreamType, volume: Int32) {
        _ = withNative { TT_SetUserVolume($0, userID, stream, volume) }
    }

    public func setUserStereo(userID: Int32, stream: StreamType, leftSpeaker: TTBOOL, rightSpeaker: TTBOOL) {
        _ = withNative { TT_SetUserStereo($0, userID, stream, leftSpeaker, rightSpeaker) }
    }

    @discardableResult
    public func subscribe(userID: Int32, subscriptions: UInt32) -> Int32 {
        withNative { TT_DoSubscribe($0, userID, subscriptions) }
    }

    @discardableResult
    public func unsubscribe(userID: Int32, subscriptions: UInt32) -> Int32 {
        withNative { TT_DoUnsubscribe($0, userID, subscriptions) }
    }

    public func pump(_ event: ClientEvent, source: Int32) {
        _ = withNative { TT_PumpMessage($0, event, source) }
    }
}
