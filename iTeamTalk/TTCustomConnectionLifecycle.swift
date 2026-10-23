import Foundation

enum TTCustomConnectionPhase: Equatable {
    case disconnected
    case connecting(attempt: Int)
    case connected
    case loggingIn
    case joiningRoot
    case joined
    case failed(String)
}

/// Pure connection state used by the session. Network callbacks and UI status
/// remain in `TTCustomSession`; this type owns only lifecycle transitions.
struct TTCustomConnectionLifecycle {
    private(set) var phase: TTCustomConnectionPhase = .disconnected

    mutating func reset() {
        phase = .disconnected
    }

    mutating func beginAttempt(_ attempt: Int) {
        phase = .connecting(attempt: max(1, attempt))
    }

    mutating func markConnected() {
        guard case .connecting = phase else { return }
        phase = .connected
    }

    mutating func markLoggingIn() {
        guard phase == .connected || phase == .loggingIn else { return }
        phase = .loggingIn
    }

    mutating func markJoiningRoot() {
        guard phase == .loggingIn || phase == .joiningRoot else { return }
        phase = .joiningRoot
    }

    mutating func markJoined() {
        guard phase == .joiningRoot || phase == .joined else { return }
        phase = .joined
    }

    mutating func fail(_ message: String) {
        phase = .failed(message)
    }
}
