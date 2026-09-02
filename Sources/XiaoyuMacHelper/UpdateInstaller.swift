import Darwin
import Foundation

/// 下载、解包、校验与内容级替换安装。
///
/// 换包原理：运行中的 App 无法覆盖自身，由主进程下载并校验新包后，
/// 以 detached 方式启动自身二进制（--perform-update）作为辅助进程，
/// 主进程随即退出；辅助进程等待主进程退出后，仅替换目标 .app 内部的
/// Contents（.app 顶层目录项不动），全程不触碰 root 属主的 /Applications，
/// 因此无需提权。TCC 权限跟随"签名证书 + bundle id"跨版本保留。
enum UpdateInstaller {
    struct PerformUpdateArguments {
        let newApp: URL
        let targetApp: URL
        let oldPID: pid_t
    }

    private static var updatesRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(updateRootDirectoryName, isDirectory: true)
            .appendingPathComponent(updatesDirectoryName, isDirectory: true)
    }

    // MARK: - 主进程侧

    /// 下载 DMG（URLSession 自动跟随重定向）到 Updates 目录，每次先清空旧缓存。
    static func download(assetURL: URL) async throws -> URL {
        let (temporaryURL, response) = try await URLSession.shared.download(from: assetURL)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw UpdateError.downloadFailed
        }
        let fileManager = FileManager.default
        try? fileManager.removeItem(at: updatesRoot)
        try fileManager.createDirectory(at: updatesRoot, withIntermediateDirectories: true)
        let destination = updatesRoot.appendingPathComponent(assetURL.lastPathComponent)
        try fileManager.moveItem(at: temporaryURL, to: destination)
        return destination
    }

    /// 挂载 DMG，用 ditto 取出卷内 .app 到 staging（保留扩展属性与符号链接），随后卸载。
    static func extractApp(fromDMG dmgURL: URL) throws -> URL {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: updatesRoot, withIntermediateDirectories: true)
        let mountPoint = fileManager.temporaryDirectory
            .appendingPathComponent("XiaoyuMacHelper-Mount-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: mountPoint, withIntermediateDirectories: true)

        do {
            _ = try run("/usr/bin/hdiutil", [
                "attach", "-nobrowse", "-readonly", "-mountpoint", mountPoint.path, dmgURL.path
            ])
        } catch {
            try? fileManager.removeItem(at: mountPoint)
            throw error
        }

        defer {
            // 任何路径都要卸载；卷被占用时强制卸载。
            _ = runAllowFailure("/usr/bin/hdiutil", ["detach", mountPoint.path, "-force"])
            try? fileManager.removeItem(at: mountPoint)
        }

        guard let volumeItems = try? fileManager.contentsOfDirectory(atPath: mountPoint.path),
              let appName = volumeItems.first(where: { $0.hasSuffix(".app") })
        else { throw UpdateError.appNotFoundInDMG }

        let stagingApp = updatesRoot
            .appendingPathComponent("staging-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent(appName)
        try fileManager.createDirectory(at: stagingApp.deletingLastPathComponent(), withIntermediateDirectories: true)
        try run("/usr/bin/ditto", [mountPoint.appendingPathComponent(appName).path, stagingApp.path])
        return stagingApp
    }

    /// 三层校验：① 新包签名完整有效；② 新旧包签名证书（Authority）一致；③ bundle id 一致。
    static func verify(newApp: URL, targetApp: URL) -> Bool {
        guard (try? run("/usr/bin/codesign", ["--verify", "--deep", "--strict", newApp.path])) != nil,
              let newAuthorities = signingAuthorities(of: newApp),
              let oldAuthorities = signingAuthorities(of: targetApp),
              newAuthorities == oldAuthorities,
              bundleIdentifier(of: newApp) == appIdentifier
        else { return false }
        return true
    }

    private static func signingAuthorities(of app: URL) -> String? {
        guard let output = runAllowFailure("/usr/bin/codesign", ["-dvv", app.path]) else { return nil }
        let authorities = output
            .split(separator: "\n")
            .map(String.init)
            .filter { $0.hasPrefix("Authority=") }
            .sorted()
        return authorities.isEmpty ? nil : authorities.joined(separator: "\n")
    }

    private static func bundleIdentifier(of app: URL) -> String? {
        Bundle(path: app.path)?.bundleIdentifier
    }

    /// 启动更新辅助进程（同一二进制 --perform-update），随后调用方应立即退出本进程。
    static func launchUpdater(newApp: URL, targetApp: URL) throws {
        let executableName = Bundle.main.executableURL?.lastPathComponent ?? "XiaoyuMacHelper"
        let helperURL = targetApp
            .appendingPathComponent("Contents/MacOS", isDirectory: true)
            .appendingPathComponent(executableName)
        let process = Process()
        process.executableURL = helperURL
        process.arguments = [
            updatePerformFlag,
            newApp.path,
            targetApp.path,
            String(ProcessInfo.processInfo.processIdentifier)
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            throw UpdateError.updaterLaunchFailed
        }
    }

    // MARK: - 辅助进程侧（main.swift 早退分支调用）

    /// 解析 "--perform-update <newApp> <targetApp> <oldPID>"。
    static func parsePerformUpdateArguments(arguments: [String] = CommandLine.arguments) -> PerformUpdateArguments? {
        guard arguments.count == 5,
              arguments[1] == updatePerformFlag,
              let oldPID = pid_t(arguments[4]),
              FileManager.default.fileExists(atPath: arguments[2]),
              FileManager.default.fileExists(atPath: arguments[3])
        else { return nil }
        return PerformUpdateArguments(
            newApp: URL(fileURLWithPath: arguments[2], isDirectory: true),
            targetApp: URL(fileURLWithPath: arguments[3], isDirectory: true),
            oldPID: oldPID
        )
    }

    /// 等待原进程退出 → 内容级替换 Contents → 拉起新版本。
    /// 任何失败都回滚或保持旧版不动，绝不留下半成品。
    @discardableResult
    static func performUpdate(_ args: PerformUpdateArguments) -> Int32 {
        let fileManager = FileManager.default
        guard waitForExit(pid: args.oldPID, timeout: 30) else { return 1 }
        guard fileManager.isWritableFile(atPath: args.targetApp.path) else { return 2 }

        let contents = args.targetApp.appendingPathComponent("Contents", isDirectory: true)
        let backup = args.targetApp.appendingPathComponent("Contents.old", isDirectory: true)
        let newContents = args.newApp.appendingPathComponent("Contents", isDirectory: true)

        do {
            try? fileManager.removeItem(at: backup)
            try fileManager.moveItem(at: contents, to: backup)
        } catch {
            return 3
        }

        do {
            try run("/usr/bin/ditto", [newContents.path, contents.path])
        } catch {
            // 回滚：删除半成品，恢复旧 Contents
            try? fileManager.removeItem(at: contents)
            try? fileManager.moveItem(at: backup, to: contents)
            return 4
        }

        try? fileManager.removeItem(at: backup)

        do {
            try run("/usr/bin/open", [args.targetApp.path])
        } catch {
            return 5
        }
        return 0
    }

    private static func waitForExit(pid: pid_t, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if kill(pid, 0) != 0 { return true }
            usleep(200_000)
        }
        return false
    }

    // MARK: - 进程执行

    /// 同步执行命令，合并 stdout/stderr；退出码非 0 抛错。
    @discardableResult
    private static func run(_ executable: String, _ arguments: [String]) throws -> String {
        guard let output = runAllowFailure(executable, arguments) else {
            throw UpdateError.commandFailed(executable, "")
        }
        return output
    }

    /// 同步执行命令，成功返回合并输出，失败返回 nil（不抛错）。
    @discardableResult
    private static func runAllowFailure(_ executable: String, _ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            return nil
        }
        let outputData = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(data: outputData, encoding: .utf8)
    }
}
