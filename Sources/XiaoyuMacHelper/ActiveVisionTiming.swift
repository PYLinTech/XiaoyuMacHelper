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
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            return nil
        }

        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            return nil
        }

        let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
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

        var unmanagedProperties: Unmanaged<CFMutableDictionary>?
        let result = IORegistryEntryCreateCFProperties(service, &unmanagedProperties, kCFAllocatorDefault, 0)
        guard result == KERN_SUCCESS,
              let properties = unmanagedProperties?.takeRetainedValue() as? [String: Any],
              let idleNanoseconds = properties["HIDIdleTime"] as? NSNumber else {
            return nil
        }

        return idleNanoseconds.doubleValue / 1_000_000_000
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
