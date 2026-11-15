import Foundation

/// Checks a clean-up against what was said. Clean-up models sometimes summarise, answer, turn a question into a
/// statement or prose into a command; when the cleaned text strays that far, the speaker's own words are typed.
public enum CleanupGuard {
    /// Words a clean-up may drop: fillers, and spoken symbols it writes as characters.
    static let droppable: Set<String> = [
        "um", "uh", "erm", "er", "ah", "hmm", "mm", "like", "so", "you", "know", "basically", "actually", "just",
        "okay", "ok", "well", "right", "alright", "all", "hey", "now", "wait", "mean", "sorry", "scratch",
        "tilde", "slash", "backslash", "dot", "dash", "hyphen", "underscore", "colon", "at", "pipe", "star", "equals",
    ]

    /// Below this many words, word counts say too little; only the question mark is checked.
    static let minimumWords = 6

    /// This many of the speaker's words in a row, missing from the clean text, is a passage left out rather than
    /// a false start removed.
    static let longestGap = 5
    /// When the speaker corrects themselves, everything before the correction may go.
    static let longestGapWithCorrection = 10
    static let corrections = ["no wait", "i mean", "scratch that", "sorry", "actually", "no no", "let me rephrase"]

    /// Puts back a final question mark the clean-up dropped, the one change it makes most often.
    public static func repair(raw: String, cleaned: String, profile: Profile) -> String {
        guard profile.punctuation != .spokenOnly,
              raw.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("?"), !cleaned.contains("?")
        else { return cleaned }
        var text = cleaned
        while let last = text.last, last == "." || last.isWhitespace { text.removeLast() }
        return text + "?"
    }

    /// Why the cleaned text cannot stand for what was said, or nil when it can.
    public static func problem(raw: String, cleaned: String, profile: Profile, dictionary: UserDictionary) -> String? {
        if profile.punctuation != .spokenOnly, raw.contains("?"), !cleaned.contains("?") {
            return "Lost the question mark"
        }

        var expected = droppable
        var allowedExtra: Set<String> = []
        for entry in dictionary.entries where entry.applies(to: profile.name) {
            for form in entry.misheard + entry.spoken { expected.formUnion(words(form)) }
            allowedExtra.formUnion(words(entry.written))
        }

        let said = words(raw).filter { !expected.contains($0) }
        guard said.count >= minimumWords else { return nil }
        let saidSet = Set(words(raw))
        let typed = words(cleaned)
        let typedSet = Set(typed)

        let kept = Double(said.filter { typedSet.contains($0) }.count) / Double(said.count)
        if kept < minimumKept(profile.correctness) {
            return "Dropped \(Int(((1 - kept) * 100).rounded()))% of what was said"
        }

        if profile.correctness != .polished, let gap = longestMissingRun(said, from: typed), gap.count >= gapLimit(raw) {
            return "Left out \"" + gap.joined(separator: " ") + "\""
        }

        let added = typed.filter { !saidSet.contains($0) && !allowedExtra.contains($0) }
        if !typed.isEmpty, Double(added.count) / Double(typed.count) > maximumAdded(profile.correctness) {
            return "Added words that were not said: " + added.prefix(6).joined(separator: " ")
        }
        return nil
    }

    static func gapLimit(_ raw: String) -> Int {
        let said = raw.lowercased()
        return corrections.contains { said.contains($0) } ? longestGapWithCorrection : longestGap
    }

    static func minimumKept(_ correctness: Profile.Correctness) -> Double {
        switch correctness {
        case .asSaid: 0.9
        case .clean: 0.75
        case .corrected: 0.7
        case .polished: 0.45
        }
    }

    static func maximumAdded(_ correctness: Profile.Correctness) -> Double {
        correctness == .polished ? 0.5 : 0.3
    }

    /// The longest run of `said` words that do not line up with `typed`, aligning the two in order. They are
    /// aligned from the end, because a speaker who corrects themselves keeps the later wording.
    static func longestMissingRun(_ said: [String], from typed: [String]) -> [String]? {
        let said = Array(said.reversed()), typed = Array(typed.reversed())
        let n = said.count, m = typed.count
        var table = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                table[i][j] = said[i] == typed[j] ? table[i + 1][j + 1] + 1 : max(table[i + 1][j], table[i][j + 1])
            }
        }
        var matched = Array(repeating: false, count: n)
        var i = 0, j = 0
        while i < n, j < m {
            if said[i] == typed[j] {
                matched[i] = true
                i += 1
                j += 1
            } else if table[i + 1][j] >= table[i][j + 1] {
                i += 1
            } else {
                j += 1
            }
        }
        var best: Range<Int>?
        var start: Int?
        for k in 0...n {
            if k < n, !matched[k] {
                if start == nil { start = k }
            } else if let s = start {
                if (k - s) > (best?.count ?? 0) { best = s..<k }
                start = nil
            }
        }
        return best.map { Array(said[$0].reversed()) }
    }

    /// Lower-cased words: letters, digits and apostrophes.
    static func words(_ text: String) -> [String] {
        text.lowercased()
            .split { !($0.isLetter || $0.isNumber || $0 == "'" || $0 == "’") }
            .map { String($0) }
    }
}
