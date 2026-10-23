import AVFoundation
@preconcurrency import TeamTalkKit

struct TTCustomInput: Identifiable, Hashable {
    let id: String
    let name: String
    let port: AVAudioSession.Port
}

struct TTCustomOutput: Identifiable, Hashable {
    let id: String
    let name: String
    let isSpeakerOverride: Bool
}

struct TTCustomRemoteUser: Identifiable, Hashable {
    let id: Int32
    let name: String
    let accountName: String
    var volume: Double
    var voicePacketsReceived: Int64 = 0
    var voicePacketsLost: Int64 = 0

    var voicePacketLossPercent: Double {
        let total = voicePacketsReceived + voicePacketsLost
        guard total > 0 else { return 0 }
        return Double(voicePacketsLost) / Double(total) * 100
    }
}

enum TTCustomStereoMode: String, CaseIterable, Identifiable {
    case both
    case left
    case right

    var id: String { rawValue }
    var title: String {
        switch self {
        case .both: return "Both speakers"
        case .left: return "Left speaker"
        case .right: return "Right speaker"
        }
    }
}

struct TTCustomChannelAudioSettings: Equatable {
    var codec: Codec = OPUS_CODEC
    var opusBitrate: Double = 32
    var opusSampleRate: Double = 48000
    var opusChannels: Int = 1
    var opusVBR = true
    var opusConstrainedVBR = false
    var opusFEC = true
    var opusDTX = false
    var opusFrameSize: Double = 20
    var opusTransmitInterval: Double = 20
    var isChannelOperator = false

    var codecName: String {
        switch codec {
        case OPUS_CODEC: return "Opus"
        case SPEEX_CODEC: return "Speex"
        case SPEEX_VBR_CODEC: return "Speex VBR"
        default: return "No audio"
        }
    }
}

struct TTCustomNetworkHealth: Equatable {
    var statisticsAvailable = false
    var udpPingMilliseconds: Int32 = -1
    var tcpPingMilliseconds: Int32 = -1
    var tcpServerSilenceSeconds: Int32 = 0
    var udpServerSilenceSeconds: Int32 = 0
    var soundInputDelayMilliseconds: Int32 = 0
    var reconnectCount = 0
    var voiceBytesSent: Int64 = 0
    var voiceBytesReceived: Int64 = 0

    var voiceTrafficObserved: Bool {
        voiceBytesSent > 0 || voiceBytesReceived > 0
    }
}

enum TTCustomLatencyPreset: String, CaseIterable, Identifiable {
    case low
    case balanced
    case stable

    var id: String { rawValue }

    var title: String {
        switch self {
        case .low: return "Low latency"
        case .balanced: return "Balanced"
        case .stable: return "Stable connection"
        }
    }

    var inputMilliseconds: Double {
        switch self {
        case .low: return 10
        case .balanced: return 20
        case .stable: return 40
        }
    }

    var receiveMilliseconds: Double {
        switch self {
        case .low: return 40
        case .balanced: return 80
        case .stable: return 140
        }
    }
}

