import Foundation
import Network

/// Receives PCM blocks from the ReplayKit broadcast extension over localhost.
/// The TeamTalk client and existing mixer remain owned by the main app.
final class TTCustomReplayKitBridge {
    private let queue = DispatchQueue(label: "com.derrick.ttcustom.replaykit-bridge", qos: .userInitiated)
    private var listener: NWListener?
    private var connection: NWConnection?
    private(set) var isRunning = false
    var onMicrophoneAudio: (([Int16]) -> Void)?
    var onSystemAudio: (([Int16]) -> Void)?

    func start() throws {
        guard listener == nil else { return }
        let listener = try NWListener(using: .udp, on: 39_551)
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.stateUpdateHandler = { [weak self] state in
            self?.isRunning = state == .ready
        }
        self.listener = listener
        listener.start(queue: queue)
    }

    func stop() {
        listener?.cancel()
        listener = nil
        connection?.cancel()
        connection = nil
        isRunning = false
    }

    private func accept(_ connection: NWConnection) {
        self.connection?.cancel()
        self.connection = connection
        connection.stateUpdateHandler = { [weak self] state in
            if case .failed = state { self?.connection = nil }
        }
        connection.start(queue: queue)
        receive(on: connection)
    }

    private func receive(on connection: NWConnection) {
        connection.receiveMessage { [weak self, weak connection] data, _, _, error in
            guard let self, let connection else { return }
            if let data, let packet = Self.decode(data) {
                switch packet.source {
                case 1: self.onMicrophoneAudio?(packet.samples)
                case 2: self.onSystemAudio?(packet.samples)
                default: break
                }
            }
            if error == nil { self.receive(on: connection) }
        }
    }

    private struct Packet {
        let source: UInt8
        let samples: [Int16]
    }

    private static func decode(_ data: Data) -> Packet? {
        guard data.count >= 13 else { return nil }
        let bytes = [UInt8](data)
        guard bytes[0] == 0x54, bytes[1] == 0x54, bytes[2] == 0x41, bytes[3] == 0x55 else { return nil }
        let source = bytes[4]
        let sampleRate = UInt32(bytes[5]) | UInt32(bytes[6]) << 8 | UInt32(bytes[7]) << 16 | UInt32(bytes[8]) << 24
        guard sampleRate == 48_000 else { return nil }
        let count = Int(UInt16(bytes[9]) | UInt16(bytes[10]) << 8)
        guard data.count >= 11 + count * 2 else { return nil }
        var samples = [Int16](repeating: 0, count: count)
        for index in 0..<count {
            let offset = 11 + index * 2
            samples[index] = Int16(bitPattern: UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8)
        }
        return Packet(source: source, samples: samples)
    }
}
