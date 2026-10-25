import AVFoundation
import Foundation

@MainActor
extension TTCustomSession {
func refreshRoutes() {
        let session = AVAudioSession.sharedInstance()
        let activeInputs = session.currentRoute.inputs
        availableInputs = (session.availableInputs ?? []).map { input in
            let activeInput = activeInputs.first(where: { $0.uid == input.uid })
            let sources = input.dataSources ?? activeInput?.dataSources ?? []
            return TTCustomInput(
                id: input.uid,
                name: input.portName,
                port: input.portType,
                dataSources: sources.map {
                    TTCustomInputSource(id: $0.dataSourceID.intValue, name: $0.dataSourceName)
                }
            )
        }
        if selectedInputID == nil {
            selectedInputID = session.preferredInput?.uid ?? availableInputs.first?.id
        }
        if let selectedInputID, !availableInputs.contains(where: { $0.id == selectedInputID }) {
            self.selectedInputID = session.preferredInput?.uid ?? availableInputs.first?.id
        }
        if let selectedInputID,
           let input = availableInputs.first(where: { $0.id == selectedInputID }) {
            if let activeSourceID = session.inputDataSource?.dataSourceID.intValue,
               input.dataSources.contains(where: { $0.id == activeSourceID }) {
                selectedInputDataSourceID = activeSourceID
            } else if let selectedInputDataSourceID,
                      !input.dataSources.contains(where: { $0.id == selectedInputDataSourceID }) {
                self.selectedInputDataSourceID = nil
            }
        }

        // The receiver is an AVAudioSession override rather than a normal
        // hardware route, so expose it as a stable synthetic choice.
        var outputs = [
            TTCustomOutput(id: "speaker", name: "iPhone Speaker", isSpeakerOverride: true),
            TTCustomOutput(id: "receiver", name: "iPhone Receiver", isSpeakerOverride: false)
        ]
        for output in session.currentRoute.outputs {
            if output.portType != .builtInSpeaker && output.portType != .builtInReceiver {
                outputs.append(TTCustomOutput(id: output.uid, name: output.portName, isSpeakerOverride: false))
            }
        }
        availableOutputs = outputs.reduce(into: [TTCustomOutput]()) { result, output in
            if !result.contains(where: { $0.id == output.id }) {
                result.append(output)
            }
        }

        // Keep external routes visible in the app's picker. Do not infer a
        // receiver selection from a transient built-in route: the receiver
        // is never an automatic destination for this app.
        if let currentOutput = session.currentRoute.outputs.first {
            switch currentOutput.portType {
            case .builtInSpeaker:
                actualOutputID = "speaker"
            case .builtInReceiver:
                actualOutputID = "receiver"
            default:
                if availableOutputs.contains(where: { $0.id == currentOutput.uid }) {
                    actualOutputID = currentOutput.uid
                }
            }
        }
    }

    func selectInput(_ inputID: String?) {
        selectInput(inputID, dataSourceID: nil)
    }

    func inputSelectionID(for input: TTCustomInput, source: TTCustomInputSource?) -> String {
        guard let source else { return input.id }
        return "\(input.id)|\(source.id)"
    }

    func selectInputSelection(_ selectionID: String) {
        let parts = selectionID.split(separator: "|", maxSplits: 1).map(String.init)
        guard let inputID = parts.first else { return }
        let sourceID = parts.count == 2 ? Int(parts[1]) : nil
        selectInput(inputID, dataSourceID: sourceID)
    }

    private func selectInput(_ inputID: String?, dataSourceID: Int?) {
        selectedInputID = inputID
        selectedInputDataSourceID = dataSourceID
        UserDefaults.standard.set(inputID, forKey: "ttcustom.inputID")
        if let dataSourceID {
            UserDefaults.standard.set(dataSourceID, forKey: "ttcustom.inputDataSourceID")
        } else {
            UserDefaults.standard.removeObject(forKey: "ttcustom.inputDataSourceID")
        }
        let session = AVAudioSession.sharedInstance()
        guard let inputID, let input = session.availableInputs?.first(where: { $0.uid == inputID }) else { return }
        do {
            if !session.isOtherAudioPlaying {
                try session.setActive(true)
            }
            try session.setPreferredInput(input)
            let availableDataSources = input.dataSources
                ?? session.currentRoute.inputs.first(where: { $0.uid == input.uid })?.dataSources
                ?? []
            if let dataSourceID,
               let dataSource = availableDataSources.first(where: { $0.dataSourceID.intValue == dataSourceID }) {
                try input.setPreferredDataSource(dataSource)
                try session.setInputDataSource(dataSource)
            }
            if connected { applySelectedAudioRoute() }
        } catch {
            status = "Could not select microphone: \(error.localizedDescription)"
        }
    }

    func selectOutput(_ outputID: String) {
        selectedOutputID = outputID
        UserDefaults.standard.set(outputID, forKey: "ttcustom.outputID")
        hasExplicitOutputSelection = true
        applySelectedAudioRoute()
    }

    func applySelectedAudioRoute() {
        guard connected else {
            _ = configureAudioSession()
            refreshRoutes()
            return
        }
        configureAudio()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self else { return }
            self.refreshRoutes()
            let actualInput = AVAudioSession.sharedInstance().currentRoute.inputs.first?.uid
            let actualOutput = self.actualOutputID ?? "Unknown"
            if let requested = self.selectedInputID, let actualInput, requested != actualInput {
                self.status = "Microphone route differs from the requested input"
            } else if self.selectedOutputID != actualOutput && self.selectedOutputID != "speaker" {
                self.status = "Output route is controlled by iOS; use the system route picker"
            }
        }
    }

    func setInputBuffer(_ value: Double) {
        let clampedValue = min(100, max(5, value.rounded()))
        inputBufferMilliseconds = clampedValue
        UserDefaults.standard.set(clampedValue, forKey: "ttcustom.inputBufferMS")
        do {
            try AVAudioSession.sharedInstance().setPreferredIOBufferDuration(clampedValue / 1000.0)
        } catch {
            status = "Could not set iOS audio buffer: \(error.localizedDescription)"
        }
    }

    func setReceiveBuffer(_ value: Double) {
        setVoicePlayoutBuffer(value)
    }

    func applyLatencyPreset(_ preset: TTCustomLatencyPreset) {
        latencyPreset = preset
        UserDefaults.standard.set(preset.rawValue, forKey: "ttcustom.latencyPreset")
        setInputBuffer(preset.inputMilliseconds)
        setVoicePlayoutBuffer(preset.receiveMilliseconds)
        setFixedJitterDelay(preset.receiveMilliseconds)
    }

func deactivateAudioSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.overrideOutputAudioPort(.none)
        try? session.setPreferredInput(nil)
        try? session.setActive(
            false,
            options: .notifyOthersOnDeactivation
        )
        // Return ownership of the I/O route completely. The next connection
        // will install the play-and-record category from a clean state.
        try? session.setCategory(.soloAmbient, options: [])
    }

    @discardableResult
    func prepareAudioSession() -> Bool {
        let session = AVAudioSession.sharedInstance()
        do {
            var options: AVAudioSession.CategoryOptions = [
                .allowBluetoothHFP,
                .allowAirPlay,
                // Do not interrupt or duck VoiceOver and other system audio
                // while the TeamTalk session is active.
                .mixWithOthers
            ]
            // VoiceProcessingIO uses the Bluetooth hands-free profile for
            // duplex audio. Advertising A2DP at the same time can make iOS
            // renegotiate AirPods between incompatible profiles and disrupt
            // VoiceOver. A2DP remains available when voice processing is off.
            if !echoCancellation {
                options.insert(.allowBluetoothA2DP)
            }
        if hasExplicitOutputSelection && selectedOutputID == "speaker" {
                options.insert(.defaultToSpeaker)
            }
            try session.setCategory(
                .playAndRecord,
                mode: echoCancellation ? .voiceChat : .default,
                options: options
            )
            try session.setPreferredIOBufferDuration(inputBufferMilliseconds / 1000.0)
            return true
        } catch {
            status = "Audio session setup failed: \(error.localizedDescription)"
            return false
        }
    }

    @discardableResult
    func activateAudioSession() -> Bool {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setActive(true)
            // Apple requires preferred input selection after the session is
            // active. Apply it after TeamTalk has opened its AudioUnit so the
            // system performs one route negotiation for the complete path.
            if let inputID = selectedInputID,
               let input = session.availableInputs?.first(where: { $0.uid == inputID }) {
                try session.setPreferredInput(input)
                let availableDataSources = input.dataSources
                    ?? session.currentRoute.inputs.first(where: { $0.uid == input.uid })?.dataSources
                    ?? []
                if let dataSourceID = selectedInputDataSourceID,
                   let dataSource = availableDataSources.first(where: { $0.dataSourceID.intValue == dataSourceID }) {
                    try input.setPreferredDataSource(dataSource)
                    try session.setInputDataSource(dataSource)
                }
            }
            // .none means the normal route. With no external route connected,
            // that is the receiver; .speaker is the explicit speaker override.
            try session.overrideOutputAudioPort(
                hasExplicitOutputSelection && selectedOutputID == "speaker" ? .speaker : .none
            )
            return true
        } catch {
            status = "Audio session setup failed: \(error.localizedDescription)"
            return false
        }
    }

    @discardableResult
    func configureAudioSession() -> Bool {
        prepareAudioSession() && activateAudioSession()
    }

func scheduleSpeakerRouteEnforcement() {
        guard hasExplicitOutputSelection, selectedOutputID == "speaker" else { return }
        speakerRouteWorkItem?.cancel()
        speakerRouteAttempts = 0
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.enforceSpeakerRoute()
        }
        speakerRouteWorkItem = workItem
        // The audio unit may publish a receiver route briefly while it opens.
        // Apply the override after that negotiation has completed.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: workItem)
    }

    func enforceSpeakerRoute() {
        guard hasExplicitOutputSelection, selectedOutputID == "speaker" else { return }
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setActive(true)
            try session.overrideOutputAudioPort(.speaker)
        } catch {
            status = "Could not select iPhone Speaker: \(error.localizedDescription)"
            return
        }

        let isReceiver = session.currentRoute.outputs.contains { $0.portType == .builtInReceiver }
        guard isReceiver, speakerRouteAttempts < 3 else { return }
        speakerRouteAttempts += 1
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.enforceSpeakerRoute()
        }
    }
}

