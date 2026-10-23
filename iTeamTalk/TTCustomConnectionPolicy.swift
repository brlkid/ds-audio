import Foundation

struct TTCustomRetryPolicy {
    let maximumAttempts: Int
    let maximumDelay: TimeInterval

    init(maximumAttempts: Int = 3, maximumDelay: TimeInterval = 8) {
        self.maximumAttempts = max(1, maximumAttempts)
        self.maximumDelay = max(0, maximumDelay)
    }

    func delayBeforeRetry(after attempt: Int) -> TimeInterval? {
        guard attempt < maximumAttempts else { return nil }
        let exponent = max(0, attempt - 1)
        return min(maximumDelay, TimeInterval(1 << exponent))
    }
}
