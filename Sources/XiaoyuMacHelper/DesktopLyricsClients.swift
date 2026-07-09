import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

struct DesktopLyricsSearchResult: Sendable {
    let providerName: String
    let lines: [DesktopLyricLine]
}

final class DesktopLyricsSearchService: @unchecked Sendable {
    private let providers: [DesktopLyricsProvider]
    private let preferredLanguage: DesktopLyricsPreferredLanguage

    init(settings: AppSettings) {
        preferredLanguage = settings.desktopLyricsPreferredLanguage
        let enabledSources = Set(settings.enabledDesktopLyricsSources)
        providers = settings.desktopLyricsSourceOrder.filter { enabledSources.contains($0) }.map { source -> DesktopLyricsProvider in
            switch source {
            case .appleMusic:
                return AppleMusicLyricsProvider(
                    mediaUserToken: settings.appleMusicMediaUserToken,
                    preferredLanguage: settings.desktopLyricsPreferredLanguage
                )
            case .qqMusic:
                return QQMusicLyricsProvider()
            case .netease:
                return NeteaseLyricsProvider()
            }
        }
    }

    func searchLyrics(for track: DesktopLyricsTrack) async -> DesktopLyricsSearchResult? {
        for provider in providers {
            guard !Task.isCancelled else { return nil }
            do {
                let lines = try await provider.lyrics(for: track)
                guard !Task.isCancelled else { return nil }
                guard !lines.isEmpty else { continue }
                return DesktopLyricsSearchResult(providerName: provider.name, lines: lines)
            } catch {
                guard !Task.isCancelled else { return nil }
                continue
            }
        }
        return nil
    }
}

private protocol DesktopLyricsProvider: Sendable {
    var name: String { get }
    func lyrics(for track: DesktopLyricsTrack) async throws -> [DesktopLyricLine]
}

enum LyricsNetwork {
    static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126 Safari/537.36"

    static func getData(url: URL, referer: String? = nil, extraHeaders: [String: String] = [:]) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json,text/plain,*/*", forHTTPHeaderField: "Accept")
        if let referer { request.setValue(referer, forHTTPHeaderField: "Referer") }
        extraHeaders.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
        return try await data(for: request)
    }

    static func postJSON(url: URL, json: Any, referer: String? = nil, extraHeaders: [String: String] = [:]) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: json, options: [])
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json,text/plain,*/*", forHTTPHeaderField: "Accept")
        if let referer { request.setValue(referer, forHTTPHeaderField: "Referer") }
        extraHeaders.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
        return try await data(for: request)
    }

    static func postForm(url: URL, form: [String: String], referer: String? = nil, extraHeaders: [String: String] = [:]) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = form
            .map { "\(escape($0.key))=\(escape($0.value))" }
            .joined(separator: "&")
            .data(using: .utf8)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/x-www-form-urlencoded; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json,text/plain,*/*", forHTTPHeaderField: "Accept")
        if let referer { request.setValue(referer, forHTTPHeaderField: "Referer") }
        extraHeaders.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
        return try await data(for: request)
    }

    static func jsonObject(from data: Data) throws -> Any {
        try JSONSerialization.jsonObject(with: data, options: [])
    }

    static func jsonDictionary(from data: Data) throws -> [String: Any] {
        try jsonObject(from: data) as? [String: Any] ?? [:]
    }

    private static func data(for request: URLRequest) async throws -> Data {
        try Task.checkCancellation()
        let (data, response) = try await URLSession.shared.data(for: request)
        try Task.checkCancellation()
        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return data
    }

    private static func escape(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? value
    }
}

private final class QQMusicLyricsProvider: DesktopLyricsProvider, @unchecked Sendable {
    let name = "QQ音乐"

    func lyrics(for track: DesktopLyricsTrack) async throws -> [DesktopLyricLine] {
        guard let songMid = try await searchSongMid(for: track) else { return [] }
        return try await fetchLyrics(songMid: songMid)
    }

    private func searchSongMid(for track: DesktopLyricsTrack) async throws -> String? {
        let body: [String: Any] = [
            "req_1": [
                "method": "DoSearchForQQMusicDesktop",
                "module": "music.search.SearchCgiService",
                "param": [
                    "num_per_page": 6,
                    "page_num": 1,
                    "query": track.searchKeyword,
                    "search_type": 0
                ]
            ]
        ]

        let data = try await LyricsNetwork.postJSON(
            url: URL(string: "https://u.y.qq.com/cgi-bin/musicu.fcg")!,
            json: body,
            referer: "https://y.qq.com/"
        )
        let dictionary = try LyricsNetwork.jsonDictionary(from: data)
        let list = (((dictionary["req_1"] as? [String: Any])?["data"] as? [String: Any])?["body"] as? [String: Any])?["song"] as? [String: Any]
        let songs = list?["list"] as? [[String: Any]] ?? []
        return bestMatch(in: songs, track: track)?["mid"] as? String
            ?? bestMatch(in: songs, track: track)?["songmid"] as? String
    }

    private func fetchLyrics(songMid: String) async throws -> [DesktopLyricLine] {
        let callback = "MusicJsonCallback_lrc"
        let form: [String: String] = [
            "callback": callback,
            "pcachetime": String(Int(Date().timeIntervalSince1970 * 1000)),
            "songmid": songMid,
            "g_tk": "5381",
            "jsonpCallback": callback,
            "loginUin": "0",
            "hostUin": "0",
            "format": "jsonp",
            "inCharset": "utf8",
            "outCharset": "utf8",
            "notice": "0",
            "platform": "yqq",
            "needNewCode": "0"
        ]

        let data = try await LyricsNetwork.postForm(
            url: URL(string: "https://c.y.qq.com/lyric/fcgi-bin/fcg_query_lyric_new.fcg")!,
            form: form,
            referer: "https://y.qq.com/"
        )
        let responseText = String(decoding: data, as: UTF8.self)
        let jsonText = stripJSONP(responseText, callback: callback)
        guard let jsonData = jsonText.data(using: .utf8) else { return [] }
        let dictionary = try LyricsNetwork.jsonDictionary(from: jsonData)
        let lyric = decodeBase64(dictionary["lyric"] as? String)
        let translation = decodeBase64(dictionary["trans"] as? String)
        let primaryLines = DesktopLyricsParser.parseLRC(lyric)
        return DesktopLyricsParser.merge(
            primary: primaryLines,
            translation: DesktopLyricsParser.parseLRC(translation)
        )
    }

    private func bestMatch(in songs: [[String: Any]], track: DesktopLyricsTrack) -> [String: Any]? {
        scoredBestMatch(in: songs, track: track) { song in
            let singers = (song["singer"] as? [[String: Any]] ?? [])
                .compactMap { $0["name"] as? String }
                .joined(separator: " ")
            return LyricsCandidateInfo(
                title: (song["title"] as? String) ?? (song["name"] as? String) ?? "",
                artist: singers,
                duration: qqSongDuration(from: song)
            )
        }
    }

    private func stripJSONP(_ text: String, callback: String) -> String {
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix(callback), let start = value.firstIndex(of: "("), let end = value.lastIndex(of: ")"), start < end {
            value = String(value[value.index(after: start)..<end])
        }
        return value
    }

    private func decodeBase64(_ value: String?) -> String {
        guard let value, let data = Data(base64Encoded: value) else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }
}

private final class NeteaseLyricsProvider: DesktopLyricsProvider, @unchecked Sendable {
    let name = "网易云音乐"

    func lyrics(for track: DesktopLyricsTrack) async throws -> [DesktopLyricLine] {
        guard let songId = try await searchSongId(for: track) else { return [] }
        return try await fetchLyrics(songId: songId)
    }

    private func searchSongId(for track: DesktopLyricsTrack) async throws -> String? {
        var components = URLComponents(string: "https://music.163.com/api/search/get/web")!
        components.queryItems = [
            URLQueryItem(name: "csrf_token", value: ""),
            URLQueryItem(name: "hlpretag", value: ""),
            URLQueryItem(name: "hlposttag", value: ""),
            URLQueryItem(name: "s", value: track.searchKeyword),
            URLQueryItem(name: "type", value: "1"),
            URLQueryItem(name: "offset", value: "0"),
            URLQueryItem(name: "total", value: "true"),
            URLQueryItem(name: "limit", value: "6")
        ]
        let data = try await LyricsNetwork.getData(url: components.url!, referer: "https://music.163.com/")
        let dictionary = try LyricsNetwork.jsonDictionary(from: data)
        let songs = ((dictionary["result"] as? [String: Any])?["songs"] as? [[String: Any]]) ?? []
        return bestMatch(in: songs, track: track).flatMap { song in
            if let id = song["id"] as? NSNumber { return id.stringValue }
            if let id = song["id"] as? Int { return String(id) }
            if let id = song["id"] as? String { return id }
            return nil
        }
    }

    private func fetchLyrics(songId: String) async throws -> [DesktopLyricLine] {
        var components = URLComponents(string: "https://music.163.com/api/song/lyric")!
        components.queryItems = [
            URLQueryItem(name: "id", value: songId),
            URLQueryItem(name: "lv", value: "1"),
            URLQueryItem(name: "kv", value: "1"),
            URLQueryItem(name: "tv", value: "-1")
        ]
        let data = try await LyricsNetwork.getData(url: components.url!, referer: "https://music.163.com/")
        let dictionary = try LyricsNetwork.jsonDictionary(from: data)
        let lyric = ((dictionary["lrc"] as? [String: Any])?["lyric"] as? String) ?? ""
        let translation = ((dictionary["tlyric"] as? [String: Any])?["lyric"] as? String) ?? ""
        let primaryLines = DesktopLyricsParser.parseLRC(lyric)
        return DesktopLyricsParser.merge(
            primary: primaryLines,
            translation: DesktopLyricsParser.parseLRC(translation)
        )
    }

    private func bestMatch(in songs: [[String: Any]], track: DesktopLyricsTrack) -> [String: Any]? {
        scoredBestMatch(in: songs, track: track) { song in
            let artists = (song["artists"] as? [[String: Any]] ?? [])
                .compactMap { $0["name"] as? String }
                .joined(separator: " ")
            return LyricsCandidateInfo(
                title: song["name"] as? String ?? "",
                artist: artists,
                duration: neteaseSongDuration(from: song)
            )
        }
    }
}

private final class AppleMusicLyricsProvider: DesktopLyricsProvider, @unchecked Sendable {
    let name = "Apple Music"

    private let mediaUserToken: String
    private let preferredLanguage: DesktopLyricsPreferredLanguage
    private var accessToken: String?
    private var storefront = "us"

    init(mediaUserToken: String, preferredLanguage: DesktopLyricsPreferredLanguage) {
        self.mediaUserToken = mediaUserToken.trimmingCharacters(in: .whitespacesAndNewlines)
        self.preferredLanguage = preferredLanguage
    }

    func lyrics(for track: DesktopLyricsTrack) async throws -> [DesktopLyricLine] {
        try await ensureInitialized()
        guard let songId = try await searchSongId(for: track) else { return [] }
        return try await fetchLyrics(songId: songId)
    }

    private func ensureInitialized() async throws {
        if accessToken == nil {
            accessToken = try await fetchAccessToken()
        }

        guard !mediaUserToken.isEmpty else { return }
        do {
            let headers = try authHeaders()
            let data = try await LyricsNetwork.getData(
                url: URL(string: "https://amp-api.music.apple.com/v1/me/storefront")!,
                referer: "https://music.apple.com/",
                extraHeaders: headers
            )
            let dictionary = try LyricsNetwork.jsonDictionary(from: data)
            if let first = (dictionary["data"] as? [[String: Any]])?.first {
                storefront = (first["id"] as? String) ?? storefront
            }
        } catch {
            storefront = "us"
        }
    }

    private func searchSongId(for track: DesktopLyricsTrack) async throws -> String? {
        var components = URLComponents(string: "https://amp-api.music.apple.com/v1/catalog/\(storefront)/search")!
        components.queryItems = [
            URLQueryItem(name: "term", value: track.searchKeyword),
            URLQueryItem(name: "types", value: "songs"),
            URLQueryItem(name: "limit", value: "6")
        ]

        let data = try await LyricsNetwork.getData(
            url: components.url!,
            referer: "https://music.apple.com/",
            extraHeaders: try authHeaders()
        )
        let dictionary = try LyricsNetwork.jsonDictionary(from: data)
        let songs = (((dictionary["results"] as? [String: Any])?["songs"] as? [String: Any])?["data"] as? [[String: Any]]) ?? []
        return bestMatch(in: songs, track: track)?["id"] as? String
    }

    private func fetchLyrics(songId: String) async throws -> [DesktopLyricLine] {
        let headers = try authHeaders()
        var fallbackLines: [DesktopLyricLine] = []

        for languageTag in preferredLanguage.appleMusicLyricsLanguageCandidates {
            var components = URLComponents(string: "https://amp-api.music.apple.com/v1/catalog/\(storefront)/songs/\(songId)/syllable-lyrics")!
            components.queryItems = [
                URLQueryItem(name: "l", value: languageTag),
                URLQueryItem(name: "extend", value: "ttmlLocalizations")
            ]

            let data = try await LyricsNetwork.getData(
                url: components.url!,
                referer: "https://music.apple.com/",
                extraHeaders: headers
            )
            let dictionary = try LyricsNetwork.jsonDictionary(from: data)
            let candidates = collectAppleMusicTTMLCandidates(from: dictionary)
            guard !candidates.isEmpty else { continue }

            if let exact = selectTTML(from: candidates, preferredTags: [languageTag], minimumScore: 60) {
                let lines = DesktopLyricsParser.parseTTML(exact)
                if !lines.isEmpty { return lines }
            }

            if let preferred = selectTTML(from: candidates, preferredTags: preferredLanguage.appleMusicLyricsLanguageCandidates, minimumScore: 60) {
                let lines = DesktopLyricsParser.parseTTML(preferred)
                if !lines.isEmpty {
                    if preferredLanguage.matches(ttml: preferred) { return lines }
                }
            }

            if fallbackLines.isEmpty, let fallback = selectAnyTimedTTML(from: candidates), !isConflictingChineseFallback(fallback) {
                fallbackLines = DesktopLyricsParser.parseTTML(fallback)
            }
        }

        return fallbackLines
    }

    private func collectAppleMusicTTMLCandidates(from value: Any) -> [String] {
        var result: [String] = []

        func visit(_ node: Any) {
            if let string = node as? String {
                if string.contains("<tt") && string.contains("</tt>") {
                    result.append(string)
                }
                return
            }

            if let dictionary = node as? [String: Any] {
                for key in ["ttmlLocalizations", "ttml", "lyrics", "value", "text"] {
                    if let child = dictionary[key] {
                        visit(child)
                    }
                }
                for (_, child) in dictionary {
                    visit(child)
                }
                return
            }

            if let array = node as? [Any] {
                array.forEach(visit)
            }
        }

        visit(value)
        var seen = Set<String>()
        return result.filter { seen.insert($0).inserted }
    }

    private func selectTTML(from candidates: [String], preferredTags: [String], minimumScore: Int) -> String? {
        let tags = preferredTags.map(normalizeLanguageTag)
        guard let best = candidates.max(by: { lhs, rhs in
            scoreTTML(lhs, preferredTags: tags) < scoreTTML(rhs, preferredTags: tags)
        }) else {
            return nil
        }
        return scoreTTML(best, preferredTags: tags) >= minimumScore ? best : nil
    }

    private func selectAnyTimedTTML(from candidates: [String]) -> String? {
        candidates.first { candidate in
            let lines = DesktopLyricsParser.parseTTML(candidate)
            return !lines.isEmpty
        }
    }

    private func isConflictingChineseFallback(_ ttml: String) -> Bool {
        let language = normalizeLanguageTag(extractXMLLanguage(from: ttml) ?? "")
        guard !language.isEmpty else { return false }
        if preferredLanguage.isSimplifiedChinese {
            return language.contains("hant") || language == "zh-tw" || language == "zh-hk" || language == "zh-mo"
        }
        if preferredLanguage.isTraditionalChinese {
            return language.contains("hans") || language == "zh-cn" || language == "zh-sg"
        }
        return false
    }

    private func scoreTTML(_ ttml: String, preferredTags: [String]) -> Int {
        let language = normalizeLanguageTag(extractXMLLanguage(from: ttml) ?? "")
        var score = 0

        if !language.isEmpty {
            if preferredLanguage.isSimplifiedChinese, language.contains("hant") {
                return 0
            }
            if preferredLanguage.isTraditionalChinese, language.contains("hans") {
                return 0
            }
            for (index, tag) in preferredTags.enumerated() {
                let rank = max(1, 20 - index)
                if language == tag {
                    score += 100 + rank
                } else if language.hasPrefix(tag + "-") || tag.hasPrefix(language + "-") {
                    score += 70 + rank
                }
            }

            if preferredLanguage.isSimplifiedChinese, language.contains("hans") {
                score += 60
            }
            if preferredLanguage.isTraditionalChinese, language.contains("hant") {
                score += 60
            }
            if preferredLanguage == .english, language.hasPrefix("en") {
                score += 60
            }
        }

        if ttml.contains("begin=") { score += 5 }
        if ttml.contains("end=") { score += 5 }
        if isWordTimedTTML(ttml) {
            score += 24
        } else if ttml.range(of: #"itunes:timing=["']Line["']"#, options: [.regularExpression, .caseInsensitive]) != nil {
            score += 4
        }
        return score
    }

    private func isWordTimedTTML(_ ttml: String) -> Bool {
        if ttml.range(of: #"itunes:timing=["']Word["']"#, options: [.regularExpression, .caseInsensitive]) != nil {
            return true
        }
        return ttml.range(of: #"<span\b[^>]*\bbegin\s*=\s*["'][^"']+["'][^>]*\bend\s*=\s*["']"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    private func extractXMLLanguage(from ttml: String) -> String? {
        matchFirst(pattern: #"xml:lang=[\"']([^\"']+)[\"']"#, in: ttml)
    }

    private func normalizeLanguageTag(_ tag: String) -> String {
        tag.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "_", with: "-")
            .lowercased()
    }

    private func fetchAccessToken() async throws -> String {
        let htmlData = try await LyricsNetwork.getData(url: URL(string: "https://music.apple.com/us/browse")!, referer: "https://music.apple.com/")
        let html = String(decoding: htmlData, as: UTF8.self)
        let jsPath = matchFirst(pattern: #"assets/index([^\"']+)\.js"#, in: html).map { "https://music.apple.com/assets/index\($0).js" }
            ?? matchFirst(pattern: #"src=[\"']([^\"']*index[^\"']*\.js)[\"']"#, in: html).map { path in
                path.hasPrefix("http") ? path : "https://music.apple.com\(path.hasPrefix("/") ? "" : "/")\(path)"
            }
        guard let jsPath, let jsURL = URL(string: jsPath) else { throw URLError(.badURL) }

        let jsData = try await LyricsNetwork.getData(url: jsURL, referer: "https://music.apple.com/")
        let js = String(decoding: jsData, as: UTF8.self)
        guard let token = matchFirst(pattern: #"(eyJ[a-zA-Z0-9_\-]+\.[a-zA-Z0-9_\-]+\.[a-zA-Z0-9_\-]+)"#, in: js) else {
            throw URLError(.userAuthenticationRequired)
        }
        return token
    }

    private func authHeaders() throws -> [String: String] {
        guard let accessToken, !accessToken.isEmpty else { throw URLError(.userAuthenticationRequired) }
        var headers = [
            "Origin": "https://music.apple.com",
            "Authorization": "Bearer \(accessToken)",
            "Accept-Language": preferredLanguage.acceptLanguageHeader
        ]
        if !mediaUserToken.isEmpty {
            headers["media-user-token"] = mediaUserToken
            headers["Cookie"] = "media-user-token=\(mediaUserToken)"
        }
        return headers
    }

    private func bestMatch(in songs: [[String: Any]], track: DesktopLyricsTrack) -> [String: Any]? {
        scoredBestMatch(in: songs, track: track) { song in
            let attributes = song["attributes"] as? [String: Any]
            return LyricsCandidateInfo(
                title: attributes?["name"] as? String ?? "",
                artist: attributes?["artistName"] as? String ?? "",
                duration: appleMusicSongDuration(from: attributes)
            )
        }
    }

    private func matchFirst(pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range), match.numberOfRanges > 1,
              let matchRange = Range(match.range(at: 1), in: text) else {
            return nil
        }
        return String(text[matchRange])
    }
}

private struct LyricsCandidateInfo {
    let title: String
    let artist: String
    let duration: TimeInterval?
}

private func scoredBestMatch(
    in songs: [[String: Any]],
    track: DesktopLyricsTrack,
    candidateInfo: ([String: Any]) -> LyricsCandidateInfo
) -> [String: Any]? {
    let scored = songs.map { song -> (song: [String: Any], score: Int) in
        let info = candidateInfo(song)
        return (song, lyricsMatchScore(candidate: info, track: track))
    }
    guard let best = scored.max(by: { $0.score < $1.score }) else { return nil }

    // Avoid accepting a random first result when the search API returns weak or unrelated matches.
    // A candidate must at least match the title, or title+duration reasonably well when artist info is missing.
    let minimumScore = track.artist.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 42 : 58
    return best.score >= minimumScore ? best.song : nil
}

private func lyricsMatchScore(candidate: LyricsCandidateInfo, track: DesktopLyricsTrack) -> Int {
    let trackTitle = normalize(track.title)
    let candidateTitle = normalize(candidate.title)
    let relaxedTrackTitle = normalizeRelaxedTitle(track.title)
    let relaxedCandidateTitle = normalizeRelaxedTitle(candidate.title)
    let trackArtist = normalize(track.artist)
    let candidateArtist = normalize(candidate.artist)

    var score = 0

    if !trackTitle.isEmpty, candidateTitle == trackTitle {
        score += 72
    } else if !relaxedTrackTitle.isEmpty, relaxedCandidateTitle == relaxedTrackTitle {
        score += 62
    } else if !trackTitle.isEmpty, !candidateTitle.isEmpty,
              candidateTitle.contains(trackTitle) || trackTitle.contains(candidateTitle) {
        score += 44
    } else if !relaxedTrackTitle.isEmpty, !relaxedCandidateTitle.isEmpty,
              relaxedCandidateTitle.contains(relaxedTrackTitle) || relaxedTrackTitle.contains(relaxedCandidateTitle) {
        score += 36
    }

    if !trackArtist.isEmpty, candidateArtist == trackArtist {
        score += 30
    } else if !trackArtist.isEmpty, !candidateArtist.isEmpty,
              candidateArtist.contains(trackArtist) || trackArtist.contains(candidateArtist) {
        score += 20
    }

    score += durationMatchScore(candidateDuration: candidate.duration, trackDuration: track.duration)
    return score
}

private func durationMatchScore(candidateDuration: TimeInterval?, trackDuration: TimeInterval?) -> Int {
    guard let candidateDuration = validDuration(candidateDuration),
          let trackDuration = validDuration(trackDuration) else {
        return 0
    }

    let diff = abs(candidateDuration - trackDuration)
    let tightTolerance = max(2.5, trackDuration * 0.025)
    let normalTolerance = max(5.0, trackDuration * 0.055)
    let looseTolerance = max(8.0, trackDuration * 0.09)
    let severeTolerance = max(12.0, trackDuration * 0.14)

    if diff <= tightTolerance { return 24 }
    if diff <= normalTolerance { return 18 }
    if diff <= looseTolerance { return 10 }
    if diff <= severeTolerance { return -12 }
    return -42
}

private func qqSongDuration(from song: [String: Any]) -> TimeInterval? {
    if let value = timeIntervalValue(song["interval"]) { return value }
    if let value = timeIntervalValue(song["duration"]) { return value }
    return nil
}

private func neteaseSongDuration(from song: [String: Any]) -> TimeInterval? {
    if let value = timeIntervalValue(song["duration"]) { return value > 1000 ? value / 1000 : value }
    if let value = timeIntervalValue(song["dt"]) { return value > 1000 ? value / 1000 : value }
    return nil
}

private func appleMusicSongDuration(from attributes: [String: Any]?) -> TimeInterval? {
    guard let attributes else { return nil }
    if let value = timeIntervalValue(attributes["durationInMillis"]) { return value / 1000 }
    if let value = timeIntervalValue(attributes["durationMillis"]) { return value / 1000 }
    return nil
}

private func timeIntervalValue(_ value: Any?) -> TimeInterval? {
    switch value {
    case let value as TimeInterval:
        return value.isFinite ? value : nil
    case let value as NSNumber:
        let doubleValue = value.doubleValue
        return doubleValue.isFinite ? doubleValue : nil
    case let value as String:
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let doubleValue = Double(trimmed), doubleValue.isFinite else { return nil }
        return doubleValue
    default:
        return nil
    }
}

private func validDuration(_ value: TimeInterval?) -> TimeInterval? {
    guard let value, value.isFinite, value > 20 else { return nil }
    return value
}

private func normalizeRelaxedTitle(_ value: String) -> String {
    let trimmed = value
        .replacingOccurrences(of: #"\([^\)]*\)"#, with: "", options: .regularExpression)
        .replacingOccurrences(of: #"\[[^\]]*\]"#, with: "", options: .regularExpression)
        .replacingOccurrences(of: #"(?i)\b(feat\.?|ft\.?|remaster(?:ed)?|live|version|版|现场|伴奏|纯音乐)\b.*$"#, with: "", options: .regularExpression)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? normalize(value) : normalize(trimmed)
}

private func normalize(_ value: String) -> String {
    value
        .lowercased()
        .replacingOccurrences(of: #"\s+"#, with: "", options: .regularExpression)
        .replacingOccurrences(of: #"[\p{P}\p{S}]"#, with: "", options: .regularExpression)
}
