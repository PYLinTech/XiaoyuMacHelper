import Foundation
import IOKit
import IOKit.hidsystem

enum ActiveVisionTiming {
    static func readDisplaySleepTimeoutFromPMSet() -> TimeInterval? {
        let process = Process()
        let outputPipe = Pipe()

        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = ["-g"]
        process.standardOutput = outputPipe
        // stderr 直接丢弃：不读取的 Pipe 在子进程输出超过缓冲区（64KB）时会永久阻塞。
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return nil
        }

        // 先排空管道再等退出：顺序反了且输出超过管道缓冲时会父子互锁。
        let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            return nil
        }

        guard let output = String(data: data, encoding: .utf8) else {
            return nil
        }

        return displaySleepTimeout(fromPMSetOutput: output)
    }

    static func currentUserIdleTime() -> TimeInterval? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching(kIOHIDSystemClass))
        guard service != IO_OBJECT_NULL else {
            return nil
        }

        defer {
            IOObjectRelease(service)
        }

        // 单键读取：整表拷贝（IORegistryEntryCreateCFProperties）会每 0.2s 复制
        // HID System 全部属性，只为取一个 HIDIdleTime。
        guard let idle = IORegistryEntryCreateCFProperty(
            service,
            "HIDIdleTime" as CFString,
            kCFAllocatorDefault,
            0
        )?.takeRetainedValue() as? NSNumber else {
            return nil
        }

        return idle.doubleValue / 1_000_000_000
    }

    private static func displaySleepTimeout(fromPMSetOutput output: String) -> TimeInterval? {
        var displaySleepMinutes: Double?
        var systemSleepMinutes: Double?

        for line in output.components(separatedBy: .newlines) {
            let parts = line
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .split { character in character == " " || character == "\t" }

            guard parts.count >= 2, let minutes = Double(parts[1]) else {
                continue
            }

            switch parts[0] {
            case "displaysleep":
                displaySleepMinutes = minutes
            case "sleep":
                systemSleepMinutes = minutes
            default:
                continue
            }
        }

        // `displaysleep 0` means the user explicitly set display sleep to Never.
        // In that case 主动视觉感知不应该用 system sleep 兜底，否则会在不需要息屏的场景下继续启动检测。
        if let displaySleepMinutes {
            return displaySleepMinutes > 0 ? displaySleepMinutes * 60 : nil
        }

        if let systemSleepMinutes, systemSleepMinutes > 0 {
            return systemSleepMinutes * 60
        }

        return nil
    }
}
