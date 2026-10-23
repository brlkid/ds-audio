import Foundation
@preconcurrency import TeamTalkKit

/// The small part of TeamTalk needed by the mixer.
///
/// Keeping this boundary narrow lets the mixer be tested with an in-memory
/// sink instead of requiring a live server or the device-only TeamTalk SDK.
protocol TTCustomAudioOutput: AnyObject {
    @discardableResult
    func insertAudioBlock(
        samples: [Int16],
        sampleRate: Int32,
        channels: Int32,
        streamID: Int32
    ) -> Bool

    func endInsertedAudioBlock()
}

extension TeamTalkClient: TTCustomAudioOutput {}
