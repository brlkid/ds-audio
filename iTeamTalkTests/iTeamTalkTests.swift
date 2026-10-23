import Foundation
import XCTest
@testable import TT_Custom
import TeamTalkKit

private final class FakeAudioOutput: TTCustomAudioOutput {
    var insertedBlocks = [[Int16]]()
    var endedStreamCount = 0

    @discardableResult
    func insertAudioBlock(
        samples: [Int16],
        sampleRate: Int32,
        channels: Int32,
        streamID: Int32
    ) -> Bool {
        insertedBlocks.append(samples)
        return true
    }

    func endInsertedAudioBlock() {
        endedStreamCount += 1
    }
}

final class TTCustomAudioTests: XCTestCase {
    func testSampleRingDropsOldestSamplesAndPreservesOrder() {
        var ring = TTCustomSampleRing(capacity: 3)
        ring.append([1, 2, 3, 4, 5])

        var output = [Int16](repeating: 0, count: 3)
        XCTAssertEqual(ring.pop(into: &output), 3)
        XCTAssertEqual(output, [3, 4, 5])
        XCTAssertEqual(ring.droppedSamples, 2)
    }

    func testSampleRingZeroFillsShortReads() {
        var ring = TTCustomSampleRing(capacity: 8)
        ring.append([100, -200])

        var output = [Int16](repeating: 7, count: 4)
        XCTAssertEqual(ring.pop(into: &output), 2)
        XCTAssertEqual(output, [100, -200, 0, 0])
    }

    func testResamplerProducesExpected48kFrameCount() {
        let source = [Int16](repeating: 1000, count: 240)
        let output = ttCustomResampleTo48k(source, sourceRate: 24_000)

        XCTAssertEqual(output.count, 480)
        XCTAssertTrue(output.allSatisfy { abs(Int($0) - 1000) <= 1 })
    }

    func testResamplerLeaves48kAudioUntouched() {
        let source: [Int16] = [0, 100, -200, 300]
        XCTAssertEqual(ttCustomResampleTo48k(source, sourceRate: 48_000), source)
    }

    func testStreamingResamplerPreservesConstantSignalAcrossCallbacks() {
        let resampler = TTCustomStreamingResampler()
        let first = resampler.process([Int16](repeating: 1000, count: 240), sourceRate: 24_000)
        let second = resampler.process([Int16](repeating: 1000, count: 240), sourceRate: 24_000)

        // One source sample remains pending between callbacks so the final
        // interpolation point can be resolved by the next callback.
        XCTAssertEqual(first.count + second.count, 958)
        XCTAssertTrue((first + second).allSatisfy { abs(Int($0) - 1000) <= 1 })
    }

    func testLatencyPresetsIncreaseBufferingForStability() {
        XCTAssertLessThan(TTCustomLatencyPreset.low.receiveMilliseconds,
                          TTCustomLatencyPreset.balanced.receiveMilliseconds)
        XCTAssertLessThan(TTCustomLatencyPreset.balanced.receiveMilliseconds,
                          TTCustomLatencyPreset.stable.receiveMilliseconds)
        XCTAssertEqual(TTCustomLatencyPreset.balanced.inputMilliseconds, 20)
    }

    func testReferenceVolumeMappingHasSafeZero() {
        XCTAssertEqual(ttCustomReferenceVolume(0), 0)
        XCTAssertEqual(ttCustomReferencePercent(0), 0)
        XCTAssertGreaterThan(ttCustomReferenceVolume(100), ttCustomReferenceVolume(50))
        XCTAssertEqual(ttCustomReferenceVolume(-10), 0)
        XCTAssertEqual(ttCustomReferenceVolume(250), ttCustomReferenceVolume(200))
    }

    func testOutputVolumeMappingPreservesTeamTalkDefault() {
        XCTAssertEqual(ttCustomOutputVolume(0), 0)
        XCTAssertEqual(ttCustomOutputVolume(100), 1000)
        XCTAssertEqual(ttCustomOutputVolume(200), 2000)
        XCTAssertEqual(ttCustomOutputVolume(5000), 32000)
    }

    func testAutomaticGainControlReducesLoudInputAndRecoversSlowly() {
        var agc = TTCustomAGC()
        let initial = agc.gain
        let reduced = agc.process(rms: Double(Int16.max) * 0.8, enabled: true)
        let recovered = agc.process(rms: 0, enabled: true)

        XCTAssertLessThan(reduced, initial)
        XCTAssertGreaterThan(recovered, reduced)
        XCTAssertLessThan(recovered, 1.0)
    }

    func testAutomaticGainControlResetsWhenDisabled() {
        var agc = TTCustomAGC()
        _ = agc.process(rms: Double(Int16.max), enabled: true)

        XCTAssertEqual(agc.process(rms: 10, enabled: false), 1.0)
        XCTAssertEqual(agc.gain, 1.0)
    }

    func testRetryPolicyUsesBoundedExponentialBackoff() {
        let policy = TTCustomRetryPolicy(maximumAttempts: 3, maximumDelay: 8)

        XCTAssertEqual(policy.delayBeforeRetry(after: 1), 1)
        XCTAssertEqual(policy.delayBeforeRetry(after: 2), 2)
        XCTAssertNil(policy.delayBeforeRetry(after: 3))
    }

    func testPortValidationRejectsMalformedAndOutOfRangeValues() {
        XCTAssertTrue(ttCustomIsValidPort("1"))
        XCTAssertTrue(ttCustomIsValidPort("65535"))
        XCTAssertFalse(ttCustomIsValidPort("0"))
        XCTAssertFalse(ttCustomIsValidPort("65536"))
        XCTAssertFalse(ttCustomIsValidPort("relay"))
    }

    func testAudioOutputBoundaryRecordsBlocksAndCanEndStream() {
        let output = FakeAudioOutput()
        XCTAssertTrue(output.insertAudioBlock(
            samples: [1, -2, 3],
            sampleRate: 48_000,
            channels: 1,
            streamID: 7
        ))
        output.endInsertedAudioBlock()

        XCTAssertEqual(output.insertedBlocks, [[1, -2, 3]])
        XCTAssertEqual(output.endedStreamCount, 1)
    }

    func testConnectionLifecycleTracksHappyPath() {
        var lifecycle = TTCustomConnectionLifecycle()
        XCTAssertEqual(lifecycle.phase, .disconnected)

        lifecycle.beginAttempt(0)
        XCTAssertEqual(lifecycle.phase, .connecting(attempt: 1))
        lifecycle.markConnected()
        lifecycle.markLoggingIn()
        lifecycle.markJoiningRoot()
        lifecycle.markJoined()

        XCTAssertEqual(lifecycle.phase, .joined)
    }

    func testConnectionLifecyclePreservesFailureReasonUntilReset() {
        var lifecycle = TTCustomConnectionLifecycle()
        lifecycle.fail("Connection lost")

        XCTAssertEqual(lifecycle.phase, .failed("Connection lost"))
        lifecycle.reset()
        XCTAssertEqual(lifecycle.phase, .disconnected)
    }

    func testTextMessageFactorySplitsOnUTF8Boundaries() {
        let message = TextMessage()
        let content = String(repeating: "🙂", count: 200)
        let fragments = TeamTalkTextMessageFactory.messages(from: message, content: content)

        XCTAssertGreaterThan(fragments.count, 1)
        XCTAssertTrue(fragments.allSatisfy {
            let copy = $0
            return TeamTalkString.textMessage(copy).lengthOfBytes(using: .utf8) < Int(TT_STRLEN)
        })
    }
}
