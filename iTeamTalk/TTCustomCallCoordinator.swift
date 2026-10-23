import AVFoundation
@preconcurrency import CallKit
import Foundation

/// Represents the currently joined TeamTalk channel to iOS as a VoIP call.
/// TeamTalk still owns the audio transport; CallKit supplies system controls.
final class TTCustomCallCoordinator: NSObject, CXProviderDelegate {
    private weak var session: TTCustomSession?
    private let provider: CXProvider
    private let callController = CXCallController()
    private var callUUID: UUID?
    private var endingFromApp = false

    init(session: TTCustomSession) {
        self.session = session
        let configuration = CXProviderConfiguration()
        configuration.supportsVideo = false
        configuration.maximumCallsPerCallGroup = 1
        configuration.maximumCallGroups = 1
        configuration.supportedHandleTypes = [.generic]
        configuration.includesCallsInRecents = false
        self.provider = CXProvider(configuration: configuration)
        super.init()
        provider.setDelegate(self, queue: DispatchQueue.main)
    }

    var isActive: Bool { callUUID != nil }

    func begin(channelName: String) {
        guard callUUID == nil else { return }
        let uuid = UUID()
        callUUID = uuid
        let action = CXStartCallAction(
            call: uuid,
            handle: CXHandle(type: .generic, value: channelName)
        )
        callController.request(CXTransaction(action: action)) { [weak self] error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let error {
                    self.callUUID = nil
                    if let session = self.session {
                        Task { @MainActor in
                            session.status = "Native call controls unavailable: \(error.localizedDescription)"
                        }
                    }
                    return
                }
                self.provider.reportOutgoingCall(with: uuid, startedConnectingAt: Date())
                self.provider.reportOutgoingCall(with: uuid, connectedAt: Date())
            }
        }
    }

    func endFromApp() {
        guard let uuid = callUUID else { return }
        endingFromApp = true
        let action = CXEndCallAction(call: uuid)
        callController.request(CXTransaction(action: action)) { [weak self] error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if error != nil {
                    self.endingFromApp = false
                    self.provider.reportCall(with: uuid, endedAt: Date(), reason: .remoteEnded)
                    self.callUUID = nil
                }
            }
        }
    }

    func providerDidReset(_ provider: CXProvider) {
        callUUID = nil
        endingFromApp = false
    }

    func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
        action.fulfill()
    }

    func provider(_ provider: CXProvider, perform action: CXSetMutedCallAction) {
        let session = session
        Task { @MainActor in session?.setTransmit(!action.isMuted) }
        action.fulfill()
    }

    func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        let shouldDisconnect = !endingFromApp
        endingFromApp = false
        action.fulfill()
        callUUID = nil
        if shouldDisconnect {
            let session = session
            Task { @MainActor in session?.disconnect() }
        }
    }

    func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
        // Do not rebuild the TeamTalk graph here. It is already configured
        // before the call is announced, avoiding route and VoiceOver churn.
    }

    func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
        // Normal TeamTalk teardown remains the source of truth.
    }

    func provider(_ provider: CXProvider, timedOutPerforming action: CXAction) {
        action.fail()
    }
}
