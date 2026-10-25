import Foundation
import LiveKit

/// Small, UI-agnostic LiveKit transport used by TT Custom during the backend
/// migration. It intentionally owns only room/media lifecycle; authentication
/// stays in the app because the app already owns the saved server credentials.
@MainActor
public final class LiveKitRoomTransport: NSObject {
    public let room: Room

    public override init() {
        room = Room()
        super.init()
    }

    public var isConnected: Bool {
        room.connectionState == .connected
    }

    public func connect(url: String, token: String) async throws {
        let options = ConnectOptions(
            autoSubscribe: true,
            enableMicrophone: false
        )
        try await room.connect(url: url, token: token, connectOptions: options)
    }

    public func setMicrophone(enabled: Bool) async throws {
        try await room.localParticipant.setMicrophone(enabled: enabled)
    }

    public func disconnect() async {
        await room.disconnect()
    }
}
