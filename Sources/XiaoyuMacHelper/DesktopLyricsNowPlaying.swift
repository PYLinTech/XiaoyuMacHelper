import Foundation

enum DesktopLyricsNowPlayingProvider {
    private static let reader = SystemNowPlayingReader()

    static func currentTrack() async -> DesktopLyricsTrack? {
        await reader.currentTrack()
    }
}

private actor SystemNowPlayingReader {
    private struct Snapshot: Sendable {
        let track: DesktopLyricsTrack
        let fetchedAt: Date
    }

    private struct JavaScriptResult: Sendable {
        let stdout: String
        let stderr: String
        let exitStatus: Int32
    }

    private struct Response: Decodable, Sendable {
        struct Derived: Decodable, Sendable {
            let appName: String?
            let title: String?
            let artist: String?
            let album: String?
            let duration: Double?
            let elapsedTime: Double?
            let playbackRate: Double?
            let isPlaying: Bool?
            let bundleIdentifier: String?
        }

        let ok: Bool
        let error: String?
        let derived: Derived?
    }

    private let minimumFetchInterval: TimeInterval = 0.25
    private let maximumStaleInterval: TimeInterval = 3.0
    private static let processTimeout: TimeInterval = 5.0
    private var lastSnapshot: Snapshot?
    private var inFlightFetch: Task<JavaScriptResult, Never>?

    func currentTrack() async -> DesktopLyricsTrack? {
        let now = Date()
        if let snapshot = lastSnapshot,
           now.timeIntervalSince(snapshot.fetchedAt) < minimumFetchInterval {
            return adjustedTrack(from: snapshot, at: now)
        }

        let result = await fetchNowPlayingJSON()
        let fetchedAt = Date()
        guard result.exitStatus == 0,
              let data = result.stdout.data(using: .utf8),
              let response = try? JSONDecoder().decode(Response.self, from: data),
              response.ok,
              let derived = response.derived,
              let title = clean(derived.title),
              !title.isEmpty else {
            if let snapshot = lastSnapshot,
               fetchedAt.timeIntervalSince(snapshot.fetchedAt) < maximumStaleInterval {
                return adjustedTrack(from: snapshot, at: fetchedAt)
            }
            lastSnapshot = nil
            return nil
        }

        let playbackRate = derived.playbackRate ?? 0
        let isPlaying = derived.isPlaying ?? (playbackRate > 0.01)
        var elapsedTime = max(0, derived.elapsedTime ?? 0)
        if let duration = derived.duration, duration > 0 {
            elapsedTime = min(elapsedTime, duration)
        }

        let track = DesktopLyricsTrack(
            title: title,
            artist: clean(derived.artist) ?? "",
            album: clean(derived.album) ?? "",
            duration: derived.duration,
            elapsedTime: elapsedTime,
            isPlaying: isPlaying,
            appName: clean(derived.appName) ?? "",
            appBundleIdentifier: clean(derived.bundleIdentifier) ?? ""
        )
        lastSnapshot = Snapshot(track: track, fetchedAt: fetchedAt)
        return track
    }

    private func fetchNowPlayingJSON() async -> JavaScriptResult {
        if let inFlightFetch {
            return await inFlightFetch.value
        }

        let task = Task.detached(priority: .userInitiated) {
            Self.runJavaScript(script: Self.script)
        }
        inFlightFetch = task
        let result = await task.value
        inFlightFetch = nil
        return result
    }

    private func adjustedTrack(from snapshot: Snapshot, at now: Date) -> DesktopLyricsTrack {
        let track = snapshot.track
        var elapsedTime = track.elapsedTime
        if track.isPlaying {
            elapsedTime += now.timeIntervalSince(snapshot.fetchedAt)
        }
        if let duration = track.duration, duration > 0 {
            elapsedTime = min(elapsedTime, duration)
        }

        return DesktopLyricsTrack(
            title: track.title,
            artist: track.artist,
            album: track.album,
            duration: track.duration,
            elapsedTime: max(0, elapsedTime),
            isPlaying: track.isPlaying,
            appName: track.appName,
            appBundleIdentifier: track.appBundleIdentifier
        )
    }

    private func clean(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || trimmed == "<null>" ? nil : trimmed
    }

    private static func runJavaScript(script: String) -> JavaScriptResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-l", "JavaScript", "-e", script]

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            return JavaScriptResult(stdout: "", stderr: String(describing: error), exitStatus: -1)
        }

        // 轮询链依赖本次调用返回（inFlightFetch 去重期间所有后续查询都在等它），
        // osascript 万一挂起必须强制了结，否则歌词轮询从此卡死。
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        if exited.wait(timeout: .now() + Self.processTimeout) == .timedOut {
            process.terminate()
            if exited.wait(timeout: .now() + 1.0) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                _ = exited.wait(timeout: .now() + 1.0)
            }
            return JavaScriptResult(stdout: "", stderr: "osascript timed out after \(Self.processTimeout)s", exitStatus: -2)
        }

        let stdout = String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return JavaScriptResult(stdout: stdout, stderr: stderr, exitStatus: process.terminationStatus)
    }

    private static let script = #"""
ObjC.import('Foundation');

function run() {
  function text(value) {
    try {
      if (value === null || value === undefined) return null;
      if (value.isNil && value.isNil()) return null;
      if (value.js !== undefined) return String(value.js);
      return String(value);
    } catch (_) {
      return null;
    }
  }

  function number(value) {
    const raw = text(value);
    if (raw === null || raw === '') return null;
    const parsed = Number(raw);
    return Number.isFinite(parsed) ? parsed : null;
  }

  function boolFromNumber(value) {
    const parsed = number(value);
    if (parsed === null) return null;
    return parsed > 0.01;
  }

  function dictValue(dict, key) {
    try {
      if (!dict) return null;
      return dict.valueForKey(key);
    } catch (_) {
      try { return dict.objectForKey(key); } catch (__) { return null; }
    }
  }

  try {
    const mediaRemote = $.NSBundle.bundleWithPath('/System/Library/PrivateFrameworks/MediaRemote.framework/');
    // JXA 桥对返回 BOOL 的零参方法（-load）暴露为属性而非函数：
    // 属性读取即调用 load 并返回 true；写成 load() 会抛 TypeError 使脚本每次轮询必败。
    if (mediaRemote) mediaRemote.load;

    const requestClass = $.NSClassFromString('MRNowPlayingRequest');
    if (!requestClass) {
      return JSON.stringify({ ok: false, error: 'MRNowPlayingRequest class is null' });
    }

    const playerPath = requestClass.localNowPlayingPlayerPath;
    const client = playerPath ? playerPath.client : null;
    const appName = text(client ? client.displayName : null);
    const bundleIdentifier = text(client ? client.bundleIdentifier : null);
    const item = requestClass.localNowPlayingItem;
    const info = item ? item.nowPlayingInfo : null;
    const metadata = item ? item.metadata : null;

    if (!info) {
      return JSON.stringify({ ok: false, error: 'localNowPlayingItem.nowPlayingInfo is null' });
    }

    const title = text(dictValue(info, 'kMRMediaRemoteNowPlayingInfoTitle'));
    const artist = text(dictValue(info, 'kMRMediaRemoteNowPlayingInfoArtist'));
    const album = text(dictValue(info, 'kMRMediaRemoteNowPlayingInfoAlbum'));
    const duration = number(dictValue(info, 'kMRMediaRemoteNowPlayingInfoDuration'));
    const elapsedFromInfo = number(dictValue(info, 'kMRMediaRemoteNowPlayingInfoElapsedTime'));
    const playbackRate = number(dictValue(info, 'kMRMediaRemoteNowPlayingInfoPlaybackRate'));
    let calculatedPlaybackPosition = null;
    try { calculatedPlaybackPosition = number(metadata ? metadata.calculatedPlaybackPosition : null); } catch (_) {}

    return JSON.stringify({
      ok: true,
      error: null,
      derived: {
        appName: appName,
        bundleIdentifier: bundleIdentifier,
        title: title,
        artist: artist,
        album: album,
        duration: duration,
        elapsedTime: calculatedPlaybackPosition !== null ? calculatedPlaybackPosition : elapsedFromInfo,
        playbackRate: playbackRate,
        isPlaying: boolFromNumber(dictValue(info, 'kMRMediaRemoteNowPlayingInfoPlaybackRate'))
      }
    });
  } catch (error) {
    return JSON.stringify({ ok: false, error: String(error) });
  }
}
"""#
}