import Foundation

enum UpdateError: Error, LocalizedError, Sendable {
    case badResponse
    case invalidPayload
    case downloadFailed
    case commandFailed(String, String)
    case appNotFoundInDMG
    case verificationFailed
    case updaterLaunchFailed

    var errorDescription: String? {
        switch self {
        case .badResponse:
            return "更新服务响应异常"
        case .invalidPayload:
            return "更新服务返回数据无效"
        case .downloadFailed:
            return "更新包下载失败"
        case let .commandFailed(command, output):
            let detail = output.trimmingCharacters(in: .whitespacesAndNewlines)
            return detail.isEmpty ? "命令执行失败：\(command)" : "命令执行失败：\(detail)"
        case .appNotFoundInDMG:
            return "未在安装包中找到应用"
        case .verificationFailed:
            return "更新包签名校验失败"
        case .updaterLaunchFailed:
            return "无法启动更新进程"
        }
    }
}

/// 固定 x.y.z 三位版本号，逐段数值比较（如 1.0.10 < 1.1.9）。
struct Version: Comparable, CustomStringConvertible, Sendable {
    let major: Int
    let minor: Int
    let patch: Int

    /// 解析 "v1.2.3" / "1.2.3"。不是恰为三段数字则返回 nil（视为无更新）。
    init?(_ string: String) {
        let trimmed = string.hasPrefix("v") ? String(string.dropFirst()) : string
        let parts = trimmed.split(separator: ".")
        guard parts.count == 3,
              let major = Int(parts[0]),
              let minor = Int(parts[1]),
              let patch = Int(parts[2])
        else { return nil }
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    static func < (lhs: Version, rhs: Version) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        return lhs.patch < rhs.patch
    }

    var description: String { "\(major).\(minor).\(patch)" }
}

/// api.pylin.cn/release 返回结构（只声明用到的字段，其余忽略）。
struct UpdateAsset: Decodable, Sendable {
    let name: String
    let size: Int?
    let url: String
}

struct UpdatePayload: Decodable, Sendable {
    let ok: Bool
    let tagName: String
    let body: String?
    let htmlURL: String
    let assets: [UpdateAsset]

    enum CodingKeys: String, CodingKey {
        case ok, body, assets
        case tagName = "tag_name"
        case htmlURL = "html_url"
    }

    var latestVersion: Version? { Version(tagName) }

    var primaryAssetURL: URL? {
        assets.first.flatMap { URL(string: $0.url) }
    }

    var fallbackHTMLURL: URL {
        URL(string: htmlURL) ?? UpdateChannel.fallbackReleaseURL
    }
}

enum UpdateChannel {
    static let repo = "PYLinTech/XiaoyuMacHelper"

    /// 按本机系统地区一次判定：中国大陆用 gitee，其余用 github。
    static var preferred: String {
        Locale.current.region?.identifier == "CN" ? "gitee" : "github"
    }

    static var fallbackReleaseURL: URL {
        let host = preferred == "gitee" ? "https://gitee.com" : "https://github.com"
        return URL(string: "\(host)/\(repo)/releases")!
    }
}

enum UpdateChecker {
    static var queryURL: URL {
        var components = URLComponents(string: updateQueryURLString)!
        components.queryItems = [
            URLQueryItem(name: "repo", value: UpdateChannel.repo),
            URLQueryItem(name: "channel", value: UpdateChannel.preferred)
        ]
        return components.url!
    }

    /// 当前运行应用的版本；读取失败返回 nil（视为无更新，不弹窗）。
    static var localVersion: Version? {
        guard let raw = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String else { return nil }
        return Version(raw)
    }

    /// 查询最新版本。网络或解析异常抛错；`ok != true` / 无版本 / 无下载资产视为无效。
    static func checkLatest() async throws -> UpdatePayload {
        let (data, response) = try await URLSession.shared.data(from: queryURL)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw UpdateError.badResponse
        }
        let payload = try JSONDecoder().decode(UpdatePayload.self, from: data)
        guard payload.ok,
              payload.latestVersion != nil,
              payload.primaryAssetURL != nil
        else { throw UpdateError.invalidPayload }
        return payload
    }
}
