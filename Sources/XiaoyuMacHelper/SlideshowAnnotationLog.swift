import Foundation

// MARK: - 幻灯片批注文件日志

/// 幻灯片批注模块的诊断日志：追加写入 `~/Library/Logs/XiaoyuMacHelper/SlideshowAnnotation.log`。
/// 覆盖「WPS 加载项 → 本机服务 → 控制器」全链路。仅记录生命周期与异常事件
/// （通信热路径不落日志），写入用常驻句柄 + 缓存大小，单条开销为一次 write。
enum SlideshowAnnotationLog {
    private static let queue = DispatchQueue(label: "local.xiaoyu-mac-helper.slideshow-annotation.log")
    private static let maxBytes = 1_048_576
    private static let keepBytes = 512 * 1024

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm:ss.SSS"
        return formatter
    }()

    private static let fileURL: URL =
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Logs/XiaoyuMacHelper/SlideshowAnnotation.log")
            ?? URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("SlideshowAnnotation.log")

    /// 常驻写句柄（首次写入时打开，截断/异常后置 nil 惰性重开），避免每条日志 open/close。
    /// 全部读写都 confined 在上方串行 queue 上，跨队列无共享访问。
    nonisolated(unsafe) private static var cachedHandle: FileHandle?
    /// 文件当前大小的缓存值（打开时测量，随后按写入量递增），避免每条日志 stat。
    nonisolated(unsafe) private static var cachedSize = 0

    /// 追加一条日志（线程安全，任意队列可调用）。
    static func info(_ message: String) {
        let line = "\(formatter.string(from: Date())) \(message)\n"
        queue.async { append(line) }
    }

    private static func append(_ line: String) {
        let data = Data(line.utf8)
        guard let handle = writableHandle() else {
            // 句柄不可用时的兜底：atomic 避免瞬态失败截断覆盖整份历史日志。
            try? data.write(to: fileURL, options: .atomic)
            return
        }
        // 写失败（磁盘满/句柄失效）不累计缓存大小，避免 trim 时机漂移。
        if (try? handle.write(contentsOf: data)) != nil {
            cachedSize += data.count
        }
        if cachedSize > maxBytes {
            trim()
        }
    }

    private static func writableHandle() -> FileHandle? {
        if let handle = cachedHandle { return handle }
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if let handle = try? FileHandle(forWritingTo: fileURL) {
            cachedHandle = handle
            _ = try? handle.seekToEnd()
            cachedSize = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            return handle
        }
        // 文件不存在则创建后重开。
        FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        cachedHandle = try? FileHandle(forWritingTo: fileURL)
        cachedSize = 0
        return cachedHandle
    }

    /// 超过 1MB 时截断保留后半段（从完整行首开始）；截断后关闭句柄惰性重开。
    private static func trim() {
        if let handle = cachedHandle {
            try? handle.close()
            cachedHandle = nil
        }
        guard let data = try? Data(contentsOf: fileURL) else {
            cachedSize = 0
            return
        }
        var trimmed = data.suffix(keepBytes)
        if let newline = trimmed.firstIndex(of: UInt8(ascii: "\n")) {
            trimmed = trimmed.suffix(from: trimmed.index(after: newline))
        }
        try? trimmed.write(to: fileURL)
        cachedSize = trimmed.count
    }
}
