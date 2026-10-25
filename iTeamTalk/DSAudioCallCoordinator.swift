import AVFoundation
import CallKit
import Foundation

final class DSAudioCallCoordinator: NSObject, CXProviderDelegate {
    private let provider: CXProvider
    private let controller = CXCallController()
    private var callUUID: UUID?
    private var endingFromApp = false

    var onMuteChanged: ((Bool) -> Void)?
    var onEnded: (() -> Void)?

    override init() {
        let configuration = CXProviderConfiguration()
        configuration.supportsVideo = false
        configuration.maximumCallsPerCallGroup = 1
        configuration.maximumCallGroups = 1
        configuration.supportedHandleTypes = [.generic]
        configuration.includesCallsInRecents = false
        provider = CXProvider(configuration: configuration)
        super.init()
        provider.setDelegate(self, queue: .main)
    }

    var isActive: Bool { callUUID != nil }

    func begin(roomName: String) {
        guard callUUID == nil else { return }
        let uuid = UUID()
        callUUID = uuid
        let action = CXStartCallAction(call: uuid, handle: CXHandle(type: .generic, value: roomName))
        controller.request(CXTransaction(action: action)) { [weak self] error in
            guard let self else { return }
            Task { @MainActor in
                guard self.callUUID == uuid else { return }
                if error != nil {
                    self.callUUID = nil
                    self.onEnded?()
                    return
                }
                let update = CXCallUpdate()
                update.localizedCallerName = "D’s Audio"
                update.supportsDTMF = false
                update.supportsHolding = false
                update.supportsGrouping = false
                self.provider.reportCall(with: uuid, updated: update)
                self.provider.reportOutgoingCall(with: uuid, startedConnectingAt: Date())
            }
        }
    }

    func endFromApp() {
        guard let uuid = callUUID else { return }
        endingFromApp = true
        controller.request(CXTransaction(action: CXEndCallAction(call: uuid))) { [weak self] error in
            guard let self else { return }
            Task { @MainActor in
                if error != nil { self.provider.reportCall(with: uuid, endedAt: Date(), reason: .remoteEnded) }
                self.callUUID = nil
                self.endingFromApp = false
            }
        }
    }

    func providerDidReset(_ provider: CXProvider) {
        callUUID = nil
        endingFromApp = false
    }

    func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playAndRecord, mode: .voiceChat, options: [.allowBluetoothHFP, .allowBluetoothA2DP])
            action.fulfill()
        } catch { action.fail() }
    }

    func provider(_ provider: CXProvider, perform action: CXSetMutedCallAction) {
        onMuteChanged?(action.isMuted)
        action.fulfill()
    }

    func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        let shouldNotify = !endingFromApp
        endingFromApp = false
        callUUID = nil
        action.fulfill()
        if shouldNotify { onEnded?() }
    }

    func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
        guard let uuid = callUUID else { return }
        provider.reportOutgoingCall(with: uuid, connectedAt: Date())
    }

    func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {}
    func provider(_ provider: CXProvider, timedOutPerforming action: CXAction) { action.fail() }
}
