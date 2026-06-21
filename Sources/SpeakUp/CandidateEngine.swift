import Foundation

/// Milestone 3 — "Live Patch" mode. This is a small, deliberately scoped
/// port of the matching primitives from the LivePatch Chrome extension
/// (livepatch-v0.3-extension/content.js): Levenshtein distance, normalized
/// similarity, and case-matching for the replacement. The full extension
/// also tracks many simultaneous "candidates" (recently-typed suspicious
/// tokens) with a multi-factor recency/proximity/timing score. For this
/// macOS v0 we instead always compare the heard phrase against ONE
/// candidate — the word at/just before the text cursor — using the same
/// similarity floor the extension uses at patch-acceptance time
/// (MIN_PATCH_SIMILARITY). That's the "is the suggestion close enough to be
/// a smart correction" check from the extension, applied live.
enum CandidateEngine {
    /// Extension: MIN_PATCH_SIMILARITY. Extra floor applied at patch-acceptance
    /// time (separate from the lower MIN_SIMILARITY used just to consider a
    /// candidate at all). Below this, we don't guess.
    ///
    /// Raised from 0.50 -> 0.62 after two observed false positives at the
    /// 0.50-0.60 band: "Lets" -> "Yes" (sim=0.50, garbled transcript) and
    /// "correction" -> "Directions" (sim=0.60, in Claude — patched a
    /// stray 10-letter word elsewhere in the doc while the user was
    /// dictating an unrelated sentence, then the whole-document AXValue
    /// splice fallback rewrote the field and visibly "morphed" its
    /// spacing). The confirmed GOOD matches we've seen are all well above
    /// this (0.75 its->it's, 0.83 wouldnt->Wouldn't, 0.86 invoce->Invoice,
    /// 0.88 tomorroe->Tomorrow), so 0.62 should keep those while cutting
    /// the weak/coincidental whole-document matches.
    static let minPatchSimilarity = 0.62

    /// Extension: SPEECH_MAX_WORDS. More than this many words almost
    /// certainly isn't a single-word/short-phrase correction — background
    /// conversation, TV audio, etc. Reject cleanly.
    static let speechMaxWords = 3

    /// Levenshtein edit distance with adjacent-transposition as a single
    /// edit (so "tomorow"/"tommorow" style swaps don't get double-penalized).
    /// Direct port of the extension's `levenshtein`.
    static func levenshtein(_ a: String, _ b: String) -> Int {
        let a = Array(a)
        let b = Array(b)
        let m = a.count, n = b.count
        if m == 0 { return n }
        if n == 0 { return m }

        var dp = Array(repeating: Array(repeating: 0, count: n + 1), count: m + 1)
        for i in 0...m { dp[i][0] = i }
        for j in 0...n { dp[0][j] = j }

        for i in 1...m {
            for j in 1...n {
                if a[i - 1] == b[j - 1] {
                    dp[i][j] = dp[i - 1][j - 1]
                } else {
                    dp[i][j] = 1 + min(dp[i - 1][j - 1], dp[i - 1][j], dp[i][j - 1])
                }
                if i > 1 && j > 1 && a[i - 1] == b[j - 2] && a[i - 2] == b[j - 1] {
                    dp[i][j] = min(dp[i][j], dp[i - 2][j - 2] + 1)
                }
            }
        }
        return dp[m][n]
    }

    /// Normalized similarity in [0, 1]. Direct port of the extension's
    /// `similarity`.
    static func similarity(_ a: String, _ b: String) -> Double {
        if a.isEmpty && b.isEmpty { return 1 }
        let dist = Double(levenshtein(a, b))
        let denom = Double(max(a.count, b.count))
        return 1 - dist / denom
    }

    /// Match the case pattern of `original` on `replacement`. Direct port
    /// of the extension's `matchCase`: ALL-CAPS -> ALL-CAPS, Capitalized ->
    /// Capitalized, otherwise pass through unchanged.
    static func matchCase(_ original: String, _ replacement: String) -> String {
        guard !original.isEmpty, !replacement.isEmpty else { return replacement }
        if original == original.uppercased() {
            return replacement.uppercased()
        }
        let firstOriginal = original[original.startIndex]
        if firstOriginal == Character(firstOriginal.uppercased()) {
            return replacement.prefix(1).uppercased() + replacement.dropFirst().lowercased()
        }
        return replacement.lowercased()
    }

    /// Splits a heard phrase into words the same way the extension does
    /// for its SPEECH_MAX_WORDS guard: collapse whitespace, split on it.
    static func wordCount(_ phrase: String) -> Int {
        phrase.split(whereSeparator: { $0.isWhitespace }).count
    }

    /// The extension's STOPWORDS set (content.js lines 14-21), kept here for
    /// reference. The extension applies this to its always-on
    /// "suspicious recently-typed word" detector — without it, nearly every
    /// sentence would light up "the"/"was"/"your" as candidates as you type,
    /// which is pure noise for that continuous background job.
    ///
    /// SpeakUp's Live Patch is NOT continuous in that sense — it only acts
    /// when you explicitly SAY something close to existing text, gated by
    /// `minPatchSimilarity`, exact-match exclusion, and `speechMaxWords`.
    /// Those guards are the noise filter here, so this set is intentionally
    /// NOT applied in `wordCandidates` — doing so would block exactly the
    /// homophone corrections (your/you're, its/it's, there/their, ...) that
    /// are this feature's best use case, since those words are all stopwords.
    static let stopwords: Set<String> = [
        "the", "a", "an", "is", "are", "was", "were", "be", "been", "being", "to", "of", "and", "or",
        "in", "on", "at", "for", "with", "as", "by", "from", "that", "this", "these", "those",
        "it", "its", "he", "she", "they", "we", "you", "i", "his", "her", "their", "our", "your",
        "should", "would", "could", "can", "will", "shall", "may", "might", "must", "do", "does",
        "did", "have", "has", "had", "not", "no", "yes", "so", "but", "if", "then", "than", "too",
        "very", "just", "also", "there", "here", "what", "when", "where", "who", "how", "why"
    ]

    /// A "candidate" word found in the focused field's text — a token that's
    /// long enough to be eligible as the target of a Live Patch correction.
    /// Port of the extension's `detectSuspicious` tokenization (regex
    /// `[A-Za-z']+`, length >= 3), minus the STOPWORDS filter (see above)
    /// and the typing-history/timing bookkeeping that v0 doesn't track.
    struct WordCandidate {
        let text: String
        let range: NSRange
    }

    /// Scans `text` for all `[A-Za-z']+` runs with length >= 3, returning
    /// each with its NSRange in `text`. This lets Live Patch consider every
    /// eligible word in the focused field, not just the one at/before the
    /// cursor.
    static func wordCandidates(in text: NSString) -> [WordCandidate] {
        guard let regex = try? NSRegularExpression(pattern: "[A-Za-z']+") else { return [] }
        let fullRange = NSRange(location: 0, length: text.length)
        var results: [WordCandidate] = []
        regex.enumerateMatches(in: text as String, range: fullRange) { match, _, _ in
            guard let match = match else { return }
            let range = match.range
            guard range.length >= 3 else { return }
            let word = text.substring(with: range)
            results.append(WordCandidate(text: word, range: range))
        }
        return results
    }

    /// How far (in characters) a candidate can be from the cursor before its
    /// proximity contribution drops to ~0. Loosely mirrors the "proximity"
    /// factor in the extension's scoreCandidate: with STOPWORDS no longer
    /// filtering candidates (see wordCandidates), very common short words
    /// like "you"/"are"/"was" can appear many times in a document and some
    /// occurrence may happen to be highly similar to a heard correction —
    /// but a correction is almost always for text near where you're
    /// currently typing, not a lookalike word somewhere else entirely.
    static let proximityWindow: Double = 60

    /// The core of Live Patch's "smart suggestion" check, scoped to v0: scan
    /// every eligible word in `text`, and rank candidates by a blend of (a)
    /// similarity to `phrase` and (b) proximity to `cursorLoc`. A candidate
    /// must still clear `minPatchSimilarity` on raw similarity alone to be
    /// considered at all (and not be an exact case-insensitive match for
    /// `phrase`) — proximity only breaks ties among otherwise-eligible
    /// candidates, it doesn't let a poor match through. Returns nil if
    /// nothing qualifies.
    static func bestMatch(in text: NSString, for phrase: String, cursorLoc: Int) -> (candidate: WordCandidate, similarity: Double)? {
        let lowerPhrase = phrase.lowercased()
        var best: (candidate: WordCandidate, similarity: Double, score: Double)? = nil
        for candidate in wordCandidates(in: text) {
            let lowerWord = candidate.text.lowercased()
            if lowerWord == lowerPhrase { continue }
            let sim = similarity(lowerWord, lowerPhrase)
            guard sim >= minPatchSimilarity else { continue }

            let distance: Int
            if cursorLoc < candidate.range.location {
                distance = candidate.range.location - cursorLoc
            } else if cursorLoc > candidate.range.location + candidate.range.length {
                distance = cursorLoc - (candidate.range.location + candidate.range.length)
            } else {
                distance = 0
            }
            let proximity = max(0, 1 - Double(distance) / proximityWindow)
            let score = sim * 0.6 + proximity * 0.4

            if best == nil || score > best!.score {
                best = (candidate, sim, score)
            }
        }
        return best.map { ($0.candidate, $0.similarity) }
    }
}
