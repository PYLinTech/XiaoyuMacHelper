import Foundation

struct DesktopLyricsTrack: Equatable, Sendable {
    let title: String
    let artist: String
    let album: String
    let duration: TimeInterval?
    let elapsedTime: TimeInterval
    let isPlaying: Bool
    let appName: String
    let appBundleIdentifier: String

    var displayTitle: String {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedArtist = artist.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedArtist.isEmpty else { return trimmedTitle }
        return "\(trimmedTitle) - \(trimmedArtist)"
    }

    var searchKeyword: String {
        [title, artist]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    var cacheKey: String {
        let durationPart = duration.flatMap { value -> String? in
            guard value.isFinite, value > 0 else { return nil }
            return String(Int(value.rounded()))
        } ?? ""
        return [title, artist, album, durationPart]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .joined(separator: "|")
    }

    var isValidForLyrics: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

struct DesktopLyricLine: Equatable, Sendable {
    let time: TimeInterval
    let text: String
    let translation: String?

    init(time: TimeInterval, text: String, translation: String? = nil) {
        self.time = time
        self.text = text
        self.translation = translation?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }
}

struct DesktopLyricLineContext: Equatable, Sendable {
    let index: Int
    let line: DesktopLyricLine
    let duration: TimeInterval?
    let elapsedInLine: TimeInterval
    let previousDuration: TimeInterval?
    let nextDuration: TimeInterval?
}

enum DesktopLyricsParser {
    static func parseLRC(_ rawText: String) -> [DesktopLyricLine] {
        let lines = rawText.components(separatedBy: .newlines)
        var result: [DesktopLyricLine] = []
        let timestampPattern = #"\[(\d{1,2}):(\d{1,2})(?:\.(\d{1,3}))?\]"#
        guard let regex = try? NSRegularExpression(pattern: timestampPattern) else { return [] }

        for rawLine in lines {
            let range = NSRange(rawLine.startIndex..<rawLine.endIndex, in: rawLine)
            let matches = regex.matches(in: rawLine, range: range)
            guard !matches.isEmpty else { continue }

            let textStart = matches.last?.range.upperBound ?? range.upperBound
            let textRange = NSRange(location: textStart, length: max(0, range.upperBound - textStart))
            let text = substring(rawLine, nsRange: textRange)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, !isMetadataLine(text) else { continue }

            for match in matches {
                guard let minutes = Double(substring(rawLine, nsRange: match.range(at: 1))),
                      let seconds = Double(substring(rawLine, nsRange: match.range(at: 2))) else {
                    continue
                }

                let fractionText = substring(rawLine, nsRange: match.range(at: 3))
                let fraction = fractionText.isEmpty ? 0 : (Double(fractionText) ?? 0) / pow(10, Double(fractionText.count))
                result.append(DesktopLyricLine(time: minutes * 60 + seconds + fraction, text: text))
            }
        }

        return normalized(result)
    }

    static func parseTTML(_ rawText: String) -> [DesktopLyricLine] {
        let normalizedText = rawText
            .replacingOccurrences(of: "\\\"", with: "\"")
            .replacingOccurrences(of: "\\n", with: "\n")
        guard let paragraphRegex = try? NSRegularExpression(
            pattern: #"<p\b([^>]*)>(.*?)</p>"#,
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        ), let beginRegex = try? NSRegularExpression(
            pattern: #"\bbegin\s*=\s*[\"']([^\"']+)[\"']"#,
            options: [.caseInsensitive]
        ), let lineBreakRegex = try? NSRegularExpression(pattern: #"<br\s*/?>"#, options: [.caseInsensitive]),
           let tagRegex = try? NSRegularExpression(pattern: #"<[^>]+>"#, options: []) else {
            return []
        }

        let fullRange = NSRange(normalizedText.startIndex..<normalizedText.endIndex, in: normalizedText)
        let paragraphs = paragraphRegex.matches(in: normalizedText, range: fullRange)
        var result: [DesktopLyricLine] = []

        for paragraph in paragraphs {
            let attributes = substring(normalizedText, nsRange: paragraph.range(at: 1))
            let attrRange = NSRange(attributes.startIndex..<attributes.endIndex, in: attributes)
            guard let beginMatch = beginRegex.firstMatch(in: attributes, range: attrRange) else { continue }
            let begin = substring(attributes, nsRange: beginMatch.range(at: 1))
            guard let time = parseTime(begin) else { continue }

            let body = substring(normalizedText, nsRange: paragraph.range(at: 2))
            let bodyRange = NSRange(body.startIndex..<body.endIndex, in: body)
            let withLineBreakSpaces = lineBreakRegex.stringByReplacingMatches(in: body, range: bodyRange, withTemplate: " ")
            let tagRange = NSRange(withLineBreakSpaces.startIndex..<withLineBreakSpaces.endIndex, in: withLineBreakSpaces)
            let withoutTags = tagRegex.stringByReplacingMatches(in: withLineBreakSpaces, range: tagRange, withTemplate: "")
            let text = decodeEntities(withoutTags)
                .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            result.append(DesktopLyricLine(time: time, text: text))
        }

        return normalized(result)
    }

    static func merge(primary: [DesktopLyricLine], translation: [DesktopLyricLine]) -> [DesktopLyricLine] {
        guard !primary.isEmpty, !translation.isEmpty else { return primary }
        var merged: [DesktopLyricLine] = []

        for line in primary {
            let translationLine = translation.min { abs($0.time - line.time) < abs($1.time - line.time) }
            let translatedText = translationLine.flatMap { abs($0.time - line.time) <= 0.75 ? $0.text : nil }
            if let translatedText, translatedText != line.text {
                merged.append(DesktopLyricLine(time: line.time, text: line.text, translation: translatedText))
            } else {
                merged.append(line)
            }
        }

        return normalized(merged)
    }

    static func currentLine(in lines: [DesktopLyricLine], at elapsedTime: TimeInterval) -> DesktopLyricLine? {
        currentLineContext(in: lines, at: elapsedTime, trackDuration: nil)?.line
    }

    static func currentLineContext(
        in lines: [DesktopLyricLine],
        at elapsedTime: TimeInterval,
        trackDuration: TimeInterval?
    ) -> DesktopLyricLineContext? {
        guard let index = lineIndex(in: lines, at: elapsedTime) else { return nil }
        return lineContext(in: lines, index: index, at: elapsedTime, trackDuration: trackDuration)
    }

    static func lineIndex(in lines: [DesktopLyricLine], at elapsedTime: TimeInterval) -> Int? {
        guard !lines.isEmpty else { return nil }
        let safeTime = elapsedTime.isFinite ? max(0, elapsedTime) : 0
        var lower = lines.startIndex
        var upper = lines.endIndex

        while lower < upper {
            let mid = lower + (upper - lower) / 2
            if lines[mid].time <= safeTime {
                lower = mid + 1
            } else {
                upper = mid
            }
        }

        return max(lines.startIndex, lower - 1)
    }

    static func lineContext(
        in lines: [DesktopLyricLine],
        index: Int,
        at elapsedTime: TimeInterval,
        trackDuration: TimeInterval?
    ) -> DesktopLyricLineContext? {
        guard lines.indices.contains(index) else { return nil }

        let line = lines[index]
        let nextTime: TimeInterval?
        if index + 1 < lines.count {
            nextTime = lines[index + 1].time
        } else {
            nextTime = trackDuration
        }

        let rawDuration = nextTime.map { max(0, $0 - line.time) }
        let duration = validLineDuration(rawDuration)
        let previousDuration = index > 0
            ? validLineDuration(max(0, line.time - lines[index - 1].time))
            : nil

        let nextDuration: TimeInterval?
        if index + 1 < lines.count {
            let nextLineStart = lines[index + 1].time
            let nextLineEnd: TimeInterval?
            if index + 2 < lines.count {
                nextLineEnd = lines[index + 2].time
            } else {
                nextLineEnd = trackDuration
            }
            nextDuration = validLineDuration(nextLineEnd.map { max(0, $0 - nextLineStart) })
        } else {
            nextDuration = nil
        }

        let safeElapsed = elapsedTime.isFinite ? elapsedTime : line.time
        let rawElapsed = max(0, safeElapsed - line.time)
        let elapsedInLine = duration.map { min(rawElapsed, $0) } ?? rawElapsed
        return DesktopLyricLineContext(
            index: index,
            line: line,
            duration: duration,
            elapsedInLine: elapsedInLine,
            previousDuration: previousDuration,
            nextDuration: nextDuration
        )
    }

    private static func normalized(_ lines: [DesktopLyricLine]) -> [DesktopLyricLine] {
        lines
            .filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted { $0.time == $1.time ? $0.text < $1.text : $0.time < $1.time }
    }

    private static func validLineDuration(_ value: TimeInterval?) -> TimeInterval? {
        guard let value, value.isFinite, value > 0.12 else { return nil }
        return value
    }


    private static func parseTime(_ value: String) -> TimeInterval? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasSuffix("s"), let seconds = Double(trimmed.dropLast()) {
            return seconds
        }

        let parts = trimmed.split(separator: ":").map(String.init)
        guard parts.count >= 2 else { return Double(trimmed) }

        let seconds = Double(parts.last ?? "") ?? 0
        let minutes = Double(parts.dropLast().last ?? "") ?? 0
        let hours = parts.count >= 3 ? (Double(parts.dropLast(2).last ?? "") ?? 0) : 0
        return hours * 3600 + minutes * 60 + seconds
    }

    private static func substring(_ string: String, nsRange: NSRange) -> String {
        guard nsRange.location != NSNotFound, let range = Range(nsRange, in: string) else { return "" }
        return String(string[range])
    }

    private static func decodeEntities(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&apos;", with: "'")
    }

    private static func isMetadataLine(_ text: String) -> Bool {
        let lowercased = text.lowercased()
        return lowercased.hasPrefix("ar:")
            || lowercased.hasPrefix("al:")
            || lowercased.hasPrefix("ti:")
            || lowercased.hasPrefix("by:")
            || lowercased.hasPrefix("offset:")
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
