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

struct DesktopLyricWordTiming: Equatable, Sendable {
    let start: TimeInterval
    let end: TimeInterval
    let utf16Location: Int
    let utf16Length: Int

    var utf16End: Int { utf16Location + utf16Length }
}

struct DesktopLyricLine: Equatable, Sendable {
    let time: TimeInterval
    let text: String
    let translation: String?
    let endTime: TimeInterval?
    let wordTimings: [DesktopLyricWordTiming]

    init(
        time: TimeInterval,
        text: String,
        translation: String? = nil,
        endTime: TimeInterval? = nil,
        wordTimings: [DesktopLyricWordTiming] = []
    ) {
        self.time = time
        self.text = text
        self.translation = translation?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        if let endTime, endTime.isFinite, endTime > time + 0.12 {
            self.endTime = endTime
        } else {
            self.endTime = nil
        }

        let textLength = text.utf16.count
        self.wordTimings = wordTimings
            .filter { timing in
                timing.start.isFinite
                    && timing.end.isFinite
                    && timing.end > timing.start + 0.015
                    && timing.utf16Location >= 0
                    && timing.utf16Length > 0
                    && timing.utf16End <= textLength
            }
            .sorted { lhs, rhs in
                if abs(lhs.start - rhs.start) > 0.0005 { return lhs.start < rhs.start }
                return lhs.utf16Location < rhs.utf16Location
            }
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
    private static let silencePlaceholderText = "..."
    private static let longSilencePlaceholderThreshold: TimeInterval = 5.0

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

        return normalized(result, insertsLeadingPlaceholder: true)
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
        ), let endRegex = try? NSRegularExpression(
            pattern: #"\bend\s*=\s*[\"']([^\"']+)[\"']"#,
            options: [.caseInsensitive]
        ) else {
            return []
        }

        let fullRange = NSRange(normalizedText.startIndex..<normalizedText.endIndex, in: normalizedText)
        let paragraphs = paragraphRegex.matches(in: normalizedText, range: fullRange)
        let leadingSilence = parseTTMLLeadingSilence(in: normalizedText)
        var result: [DesktopLyricLine] = []

        for paragraph in paragraphs {
            let attributes = substring(normalizedText, nsRange: paragraph.range(at: 1))
            let attrRange = NSRange(attributes.startIndex..<attributes.endIndex, in: attributes)
            guard let beginMatch = beginRegex.firstMatch(in: attributes, range: attrRange) else { continue }
            let begin = substring(attributes, nsRange: beginMatch.range(at: 1))
            guard let time = parseTime(begin) else { continue }
            let explicitEndTime = endRegex.firstMatch(in: attributes, range: attrRange)
                .flatMap { parseTime(substring(attributes, nsRange: $0.range(at: 1))) }

            let body = substring(normalizedText, nsRange: paragraph.range(at: 2))
            let parsedBody = parseTTMLParagraphBody(body, lineStart: time)
            guard !parsedBody.text.isEmpty else { continue }
            let endTime = explicitEndTime ?? parsedBody.absoluteEndTime
            result.append(DesktopLyricLine(time: time, text: parsedBody.text, endTime: endTime, wordTimings: parsedBody.wordTimings))
        }

        return normalized(result, leadingSilence: leadingSilence, insertsLeadingPlaceholder: true, insertsInterludePlaceholders: true)
    }

    static func merge(primary: [DesktopLyricLine], translation: [DesktopLyricLine]) -> [DesktopLyricLine] {
        guard !primary.isEmpty, !translation.isEmpty else { return primary }
        var merged: [DesktopLyricLine] = []

        for line in primary {
            let translationLine = translation.min { abs($0.time - line.time) < abs($1.time - line.time) }
            let translatedText = translationLine.flatMap { abs($0.time - line.time) <= 0.75 ? $0.text : nil }
            if let translatedText, translatedText != line.text {
                merged.append(DesktopLyricLine(time: line.time, text: line.text, translation: translatedText, endTime: line.endTime, wordTimings: line.wordTimings))
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
        guard safeTime + 0.001 >= lines[lines.startIndex].time else { return nil }
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

        let lineEndTime = validEndTime(line.endTime, start: line.time) ?? nextTime
        let rawDuration = lineEndTime.map { max(0, $0 - line.time) }
        let duration = validLineDuration(rawDuration)
        let previousDuration: TimeInterval?
        if index > 0 {
            let previousLine = lines[index - 1]
            let previousEnd = validEndTime(previousLine.endTime, start: previousLine.time) ?? line.time
            previousDuration = validLineDuration(max(0, previousEnd - previousLine.time))
        } else {
            previousDuration = nil
        }

        let nextDuration: TimeInterval?
        if index + 1 < lines.count {
            let nextLine = lines[index + 1]
            let nextLineStart = nextLine.time
            let nextLineEnd: TimeInterval?
            if let explicitEnd = validEndTime(nextLine.endTime, start: nextLineStart) {
                nextLineEnd = explicitEnd
            } else if index + 2 < lines.count {
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

    private static func normalized(
        _ lines: [DesktopLyricLine],
        leadingSilence: TimeInterval? = nil,
        insertsLeadingPlaceholder: Bool = false,
        insertsInterludePlaceholders: Bool = false
    ) -> [DesktopLyricLine] {
        let sortedLines = lines
            .filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted { $0.time == $1.time ? $0.text < $1.text : $0.time < $1.time }
        guard !sortedLines.isEmpty else { return [] }

        var result: [DesktopLyricLine] = []
        let first = sortedLines[0]
        if insertsLeadingPlaceholder, shouldInsertLeadingPlaceholder(before: first, leadingSilence: leadingSilence) {
            result.append(DesktopLyricLine(time: 0, text: silencePlaceholderText, endTime: first.time))
        }

        var previousVocalLine: DesktopLyricLine?
        for line in sortedLines {
            if insertsInterludePlaceholders,
               let previous = previousVocalLine,
               shouldInsertInterludePlaceholder(after: previous, before: line) {
                let start = previous.endTime ?? previous.time
                result.append(DesktopLyricLine(time: start, text: silencePlaceholderText, endTime: line.time))
            }
            result.append(line)
            if !isSilencePlaceholderText(line.text) {
                previousVocalLine = line
            }
        }

        return result
    }

    private static func validLineDuration(_ value: TimeInterval?) -> TimeInterval? {
        guard let value, value.isFinite, value > 0.12 else { return nil }
        return value
    }

    private static func validEndTime(_ value: TimeInterval?, start: TimeInterval) -> TimeInterval? {
        guard let value, value.isFinite, value > start + 0.12 else { return nil }
        return value
    }

    private static func shouldInsertLeadingPlaceholder(before firstLine: DesktopLyricLine, leadingSilence: TimeInterval?) -> Bool {
        guard !isSilencePlaceholderText(firstLine.text), firstLine.time.isFinite, firstLine.time > 0 else { return false }
        let metadata = (leadingSilence?.isFinite == true) ? (leadingSilence ?? 0) : 0
        return max(firstLine.time, metadata) > longSilencePlaceholderThreshold
    }

    private static func shouldInsertInterludePlaceholder(after previousLine: DesktopLyricLine, before nextLine: DesktopLyricLine) -> Bool {
        guard !isSilencePlaceholderText(previousLine.text), !isSilencePlaceholderText(nextLine.text) else { return false }
        guard let endTime = validEndTime(previousLine.endTime, start: previousLine.time) else { return false }
        let gap = nextLine.time - endTime
        return gap.isFinite && gap > longSilencePlaceholderThreshold
    }

    private static func isSilencePlaceholderText(_ text: String) -> Bool {
        let compact = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: " ", with: "")
        guard !compact.isEmpty else { return false }
        return compact.allSatisfy { $0 == "." || $0 == "…" || $0 == "⋯" }
    }

    private static func parseTTMLParagraphBody(
        _ body: String,
        lineStart: TimeInterval
    ) -> (text: String, wordTimings: [DesktopLyricWordTiming], absoluteEndTime: TimeInterval?) {
        guard let spanRegex = try? NSRegularExpression(
            pattern: #"<span\b([^>]*)>(.*?)</span>"#,
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        ), let beginRegex = try? NSRegularExpression(
            pattern: #"\bbegin\s*=\s*[\"']([^\"']+)[\"']"#,
            options: [.caseInsensitive]
        ), let endRegex = try? NSRegularExpression(
            pattern: #"\bend\s*=\s*[\"']([^\"']+)[\"']"#,
            options: [.caseInsensitive]
        ), let lineBreakRegex = try? NSRegularExpression(pattern: #"<br\s*/?>"#, options: [.caseInsensitive]),
           let tagRegex = try? NSRegularExpression(pattern: #"<[^>]+>"#, options: []) else {
            return (plainTTMLText(body), [], nil)
        }

        func plainText(_ fragment: String) -> String {
            let range = NSRange(fragment.startIndex..<fragment.endIndex, in: fragment)
            let withLineBreakSpaces = lineBreakRegex.stringByReplacingMatches(in: fragment, range: range, withTemplate: " ")
            let tagRange = NSRange(withLineBreakSpaces.startIndex..<withLineBreakSpaces.endIndex, in: withLineBreakSpaces)
            return decodeEntities(tagRegex.stringByReplacingMatches(in: withLineBreakSpaces, range: tagRange, withTemplate: ""))
        }

        let bodyRange = NSRange(body.startIndex..<body.endIndex, in: body)
        let spans = spanRegex.matches(in: body, range: bodyRange)
        guard !spans.isEmpty else { return (plainTTMLText(body), [], nil) }

        var text = ""
        var timings: [DesktopLyricWordTiming] = []
        var maxAbsoluteEndTime: TimeInterval?
        var cursor = bodyRange.location

        func appendPlain(_ fragment: String) {
            let normalized = normalizedInlineText(plainText(fragment))
            guard !normalized.isEmpty else { return }
            if text.last?.isWhitespace == false, normalized.first?.isWhitespace == false, shouldPreserveSeparator(before: text, next: normalized) {
                text.append(" ")
            }
            text.append(normalized)
        }

        for span in spans {
            if span.range.location > cursor {
                appendPlain(substring(body, nsRange: NSRange(location: cursor, length: span.range.location - cursor)))
            }

            let attributes = substring(body, nsRange: span.range(at: 1))
            let attrRange = NSRange(attributes.startIndex..<attributes.endIndex, in: attributes)
            let spanText = normalizedInlineText(plainText(substring(body, nsRange: span.range(at: 2))))
            if !spanText.isEmpty {
                if text.last?.isWhitespace == false, spanText.first?.isWhitespace == false, shouldPreserveSeparator(before: text, next: spanText) {
                    text.append(" ")
                }
                let location = text.utf16.count
                text.append(spanText)
                if let begin = beginRegex.firstMatch(in: attributes, range: attrRange).flatMap({ parseTime(substring(attributes, nsRange: $0.range(at: 1))) }),
                   let end = endRegex.firstMatch(in: attributes, range: attrRange).flatMap({ parseTime(substring(attributes, nsRange: $0.range(at: 1))) }),
                   end > begin + 0.015 {
                    timings.append(DesktopLyricWordTiming(start: max(0, begin - lineStart), end: max(0.015, end - lineStart), utf16Location: location, utf16Length: spanText.utf16.count))
                    maxAbsoluteEndTime = max(maxAbsoluteEndTime ?? end, end)
                }
            }
            cursor = span.range.location + span.range.length
        }

        let bodyEnd = bodyRange.location + bodyRange.length
        if cursor < bodyEnd {
            appendPlain(substring(body, nsRange: NSRange(location: cursor, length: bodyEnd - cursor)))
        }

        let trimmed = trimWordTimedText(text, timings: timings)
        return (trimmed.text, trimmed.timings, maxAbsoluteEndTime)
    }

    private static func plainTTMLText(_ body: String) -> String {
        guard let lineBreakRegex = try? NSRegularExpression(pattern: #"<br\s*/?>"#, options: [.caseInsensitive]),
              let tagRegex = try? NSRegularExpression(pattern: #"<[^>]+>"#, options: []) else {
            return decodeEntities(body)
                .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let bodyRange = NSRange(body.startIndex..<body.endIndex, in: body)
        let withLineBreakSpaces = lineBreakRegex.stringByReplacingMatches(in: body, range: bodyRange, withTemplate: " ")
        let tagRange = NSRange(withLineBreakSpaces.startIndex..<withLineBreakSpaces.endIndex, in: withLineBreakSpaces)
        return decodeEntities(tagRegex.stringByReplacingMatches(in: withLineBreakSpaces, range: tagRange, withTemplate: ""))
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func normalizedInlineText(_ text: String) -> String {
        text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func shouldPreserveSeparator(before text: String, next: String) -> Bool {
        guard let previous = text.last, let first = next.first else { return false }
        if previous.isWhitespace || first.isWhitespace { return false }
        return previous.isASCII && first.isASCII
    }

    private static func trimWordTimedText(
        _ rawText: String,
        timings: [DesktopLyricWordTiming]
    ) -> (text: String, timings: [DesktopLyricWordTiming]) {
        let leadingCount = rawText.prefix { $0.isWhitespace }.reduce(0) { $0 + String($1).utf16.count }
        let trimmedText = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else { return ("", []) }
        let length = trimmedText.utf16.count
        let adjusted = timings.compactMap { timing -> DesktopLyricWordTiming? in
            let location = timing.utf16Location - leadingCount
            guard location >= 0, location + timing.utf16Length <= length else { return nil }
            return DesktopLyricWordTiming(start: timing.start, end: timing.end, utf16Location: location, utf16Length: timing.utf16Length)
        }
        return (trimmedText, adjusted)
    }

    private static func parseTTMLLeadingSilence(in text: String) -> TimeInterval? {
        guard let regex = try? NSRegularExpression(
            pattern: #"\bleadingSilence\s*=\s*[\"']([^\"']+)[\"']"#,
            options: [.caseInsensitive]
        ) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range) else { return nil }
        return parseTime(substring(text, nsRange: match.range(at: 1)))
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
