import Foundation

/// When Whisper reviews the log on its own: after a handful of new corrections, or once a day when there is
/// something to look at, and never twice within an hour.
public enum AutoReview {
    public static let correctionsNeeded = 5
    public static let dailyMinimum = 3

    /// `newFeedback`: corrections since the last attempt. `evidence`: dictations worth reviewing since the last
    /// saved review.
    public static func isDue(newFeedback: Int, evidence: Int, lastAttempt: Date?, now: Date) -> Bool {
        if let lastAttempt, now.timeIntervalSince(lastAttempt) < 3600 { return false }
        if newFeedback >= correctionsNeeded { return true }
        guard evidence >= dailyMinimum else { return false }
        return lastAttempt.map { now.timeIntervalSince($0) >= 86_400 } ?? true
    }
}
