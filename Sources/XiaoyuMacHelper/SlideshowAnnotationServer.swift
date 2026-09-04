import Foundation
import Network
import CryptoKit

// MARK: - 上报数据

/// 加载项上报的放映开始信息（VBA 语义坐标：主屏左上原点、y 向下、单位 pt）。
struct SlideshowBeginReport {
    var x: CGFloat?
    var y: CGFloat?
    var width: CGFloat?
    var height: CGFloat?
    var pageIndex: Int?
    /// 演示文稿总页数；取不到时为 nil。
    var totalPages: Int?
}

/// 加载项上报的事件（加载项 → MacHelper）。
enum SlideshowReportEndpoint {
    case begin(SlideshowBeginReport)
    /// 翻页：当前页码（1 起）与总页数。
    case page(Int?, Int?)
    case end
    /// 活跃连接自身断开（WPS 退出/页面销毁/网络瞬断）。与加载项主动上报的
    /// end 区分：断开可能只是瞬断，控制器据此进入重连宽限而非直接清数据。
    case connectionClosed
    case heartbeat
    /// 加载项侧诊断文本。
    case log(String)
    /// 按需导出回执分块：单页 base64 按块上报（seq 从 0 起、total 为总块数）。
    /// 实测 WPS 的 WebSocket 一次发送 ~0.9MB 大帧会直接断链，故分块传输、
    /// 主程序按序重组。ok=false 或 total<=1 时 data 即为完整结果（或空）。
    case exported(page: Int, ok: Bool, seq: Int, total: Int, data: String)
}

/// MacHelper 下发到加载项的命令（MacHelper → 加载项）。
enum SlideshowCommand {
    case next
    case previous
    case goto(Int)
    case exit
    /// 按需导出指定页缩略图（页码预览懒加载）。
    case exportPages([Int])
}

// MARK: - WebSocket 桥接服务

/// 幻灯片批注本机 WebSocket 服务：只监听 127.0.0.1，与 WPS 加载项建立长连接。
///
/// 采用 RFC 6455 WebSocket（文本帧、JSON 负载）而非 HTTP 短连接：
/// - 加载项通过 `ws://127.0.0.1:47613/slideshow` 连接，事件/页码/心跳随时上行；
/// - MacHelper 复用同一条连接下行 `next/previous/goto/exit` 命令（翻页不再投递按键）；
/// - 连接断开即代表加载项页面销毁或 WPS 退出，控制器据此收起批注层。
final class SlideshowAnnotationBridgeServer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.xiaoyu.slideshow-annotation.bridge")
    private var listener: NWListener?
    private var activeConnection: SlideshowWebSocketConnection?
    private let router: @Sendable (SlideshowReportEndpoint) -> Void

    init(router: @escaping @Sendable (SlideshowReportEndpoint) -> Void) {
        self.router = router
    }

    func start() {
        queue.async { [self] in
            startOnQueue()
        }
    }

    func stop() {
        queue.async { [self] in
            stopOnQueue()
        }
    }

    /// 向加载项下发命令；无活跃连接时静默丢弃。
    func send(_ command: SlideshowCommand) {
        let text = SlideshowCommandCodec.encode(command)
        queue.async { [self] in
            guard let connection = activeConnection else {
                // 仅异常路径留痕：正常通信（心跳/翻页/导出回执等高频事件）不落日志。
                SlideshowAnnotationLog.info("下发失败(无活跃连接): \(text)")
                return
            }
            connection.send(text: text)
        }
    }

    // MARK: - 监听（以下方法均只在 queue 上执行）

    private func startOnQueue() {
        guard listener == nil else { return }
        guard let port = NWEndpoint.Port(rawValue: SlideshowAnnotationAddin.helperPort) else {
            SlideshowAnnotationLog.info("WebSocket 桥接服务启动失败: 端口值非法 \(SlideshowAnnotationAddin.helperPort)")
            return
        }
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(
            host: .ipv4(.loopback),
            port: port
        )
        do {
            let listener = try NWListener(using: parameters)
            listener.newConnectionHandler = { [weak self] connection in
                guard let self else { return }
                self.queue.async { self.accept(connection) }
            }
            self.listener = listener
            listener.start(queue: queue)
            SlideshowAnnotationLog.info("WebSocket 桥接服务已监听 127.0.0.1:\(SlideshowAnnotationAddin.helperPort)")
        } catch {
            // 端口被占用等异常：保持功能静默不可用，不影响其他模块。
            self.listener = nil
            SlideshowAnnotationLog.info("WebSocket 桥接服务监听失败(端口被占用?): \(error)")
        }
    }

    private func stopOnQueue() {
        listener?.cancel()
        listener = nil
        activeConnection?.close()
        activeConnection = nil
    }

    private func accept(_ connection: NWConnection) {
        // 只维护最新一条连接：WPS 重载加载项页面时会建立新连接。
        // 旧连接被替换时静默关闭（不触发 end），避免页面重连瞬间误收起批注层；
        // 只有活跃连接自身断开（WPS 退出/页面销毁）才上报 end。
        let previous = activeConnection
        let webSocket = SlideshowWebSocketConnection(connection: connection) { [weak self] message in
            self?.dispatch(message)
        } onClose: { [weak self] in
            guard let self else { return }
            self.activeConnection = nil
            SlideshowAnnotationLog.info("加载项连接已断开")
            // 不直接路由 end：瞬断（休眠唤醒/NWConnection 错误等）下加载项会
            // 重连并补发 begin 自愈，是否真正收层由控制器宽限窗口决定。
            self.router(.connectionClosed)
        }
        activeConnection = webSocket
        previous?.closeSilently()
        webSocket.start(on: queue)
    }

    /// 解析上行 JSON 消息并路由。
    private func dispatch(_ text: String) {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String else {
            SlideshowAnnotationLog.info("收到无法解析的上报 \(text.prefix(200))")
            return
        }
        // 上行消息一律静默路由（心跳 3s 一条、exported 单页可达数十条、
        // begin/page/end 均属通信热路径）：异常帧才留痕，避免高频磁盘 IO。
        func number(_ key: String) -> CGFloat? {
            (object[key] as? NSNumber).map { CGFloat($0.doubleValue) }
        }
        func integer(_ key: String) -> Int? {
            (object[key] as? NSNumber).map { $0.intValue }
        }
        switch type {
        case "begin":
            let report = SlideshowBeginReport(
                x: number("x"),
                y: number("y"),
                width: number("w"),
                height: number("h"),
                pageIndex: integer("page"),
                totalPages: integer("total")
            )
            router(.begin(report))
        case "page":
            router(.page(integer("page"), integer("total")))
        case "end":
            router(.end)
        case "heartbeat":
            router(.heartbeat)
        case "log":
            router(.log(object["msg"] as? String ?? ""))
        case "exported":
            router(.exported(
                page: integer("page") ?? 0,
                ok: (object["ok"] as? NSNumber)?.boolValue ?? false,
                seq: integer("seq") ?? 0,
                total: integer("total") ?? 1,
                data: object["data"] as? String ?? ""
            ))
        default:
            break
        }
    }
}

// MARK: - 命令编码

enum SlideshowCommandCodec {
    static func encode(_ command: SlideshowCommand) -> String {
        switch command {
        case .next:
            return #"{"type":"next"}"#
        case .previous:
            return #"{"type":"previous"}"#
        case .goto(let page):
            return #"{"type":"goto","page":\#(page)}"#
        case .exit:
            return #"{"type":"exit"}"#
        case .exportPages(let pages):
            let list = pages.map(String.init).joined(separator: ",")
            return #"{"type":"export","pages":[\#(list)]}"#
        }
    }
}

// MARK: - WebSocket 连接（RFC 6455 服务端）

/// 一条 WebSocket 连接：HTTP Upgrade 握手 → 文本帧收发。
/// 所有回调均在所属 queue 上执行；消息负载均为 JSON 字符串。
private final class SlideshowWebSocketConnection: @unchecked Sendable {
    /// 单帧负载上限（见 consumeFrame 内的校验）。
    static let maxFrameLength = 2 * 1024 * 1024

    private enum Phase {
        case handshake
        case frames
    }

    private let connection: NWConnection
    private let onMessage: @Sendable (String) -> Void
    private let onClose: @Sendable () -> Void
    private var receiveBuffer = Data()
    private var phase: Phase = .handshake
    private var finished = false
    /// 静默关闭（被新连接替换时置位）：不触发 onClose，避免误报放映结束。
    private var suppressCloseNotification = false

    init(
        connection: NWConnection,
        onMessage: @escaping @Sendable (String) -> Void,
        onClose: @escaping @Sendable () -> Void
    ) {
        self.connection = connection
        self.onMessage = onMessage
        self.onClose = onClose
    }

    func start(on queue: DispatchQueue) {
        connection.start(queue: queue)
        receiveLoop()
    }

    func close() {
        finish()
    }

    /// 被新连接替换时静默关闭：不触发 onClose 上报。
    func closeSilently() {
        suppressCloseNotification = true
        finish()
    }

    // MARK: - 接收

    private func receiveLoop() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data {
                self.receiveBuffer.append(data)
                self.drainBuffer()
            }
            if error != nil {
                self.finish()
                return
            }
            if isComplete {
                self.finish()
                return
            }
            if !self.finished {
                self.receiveLoop()
            }
        }
    }

    /// 尝试消费缓冲区：握手阶段解析 Upgrade 头，之后逐帧解析。
    private func drainBuffer() {
        if finished { return }
        switch phase {
        case .handshake:
            guard performHandshakeIfReady() else { return }
            fallthrough
        case .frames:
            while !finished, let frame = consumeFrame() {
                handle(frame)
            }
        }
    }

    // MARK: - 握手

    private func performHandshakeIfReady() -> Bool {
        guard let headerEnd = receiveBuffer.firstRange(of: Data("\r\n\r\n".utf8)) else {
            if receiveBuffer.count > 16 * 1024 {
                finish()
            }
            return false
        }
        let headerData = receiveBuffer.subdata(in: receiveBuffer.startIndex..<headerEnd.lowerBound)
        receiveBuffer.removeSubrange(receiveBuffer.startIndex..<headerEnd.upperBound)
        guard let headerText = String(data: headerData, encoding: .utf8) else {
            finish()
            return true
        }

        var lines = headerText.components(separatedBy: "\r\n")
        guard !lines.isEmpty else {
            finish()
            return true
        }
        let requestLine = lines.removeFirst().components(separatedBy: " ")
        guard requestLine.count >= 2, requestLine[0] == "GET",
              lines.contains(where: { $0.caseInsensitiveCompare("Upgrade: websocket") == .orderedSame }),
              lines.contains(where: { $0.caseInsensitiveCompare("Connection: Upgrade") == .orderedSame }) else {
            finish()
            return true
        }

        var key: String?
        for line in lines where line.lowercased().hasPrefix("sec-websocket-key:") {
            // omittingEmptySubsequences: false 保证冒号后为空值时也能取到第 2 个元素，
            // 避免 .map(String.init)[1] 因数组越界导致整 App 崩溃。
            let parts = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            guard parts.count >= 2 else { continue }
            key = parts[1].trimmingCharacters(in: .whitespaces)
        }
        guard let key, !key.isEmpty else {
            finish()
            return true
        }

        let accept = Self.webSocketAccept(for: key)
        var response = "HTTP/1.1 101 Switching Protocols\r\n"
        response += "Upgrade: websocket\r\n"
        response += "Connection: Upgrade\r\n"
        response += "Sec-WebSocket-Accept: \(accept)\r\n"
        response += "\r\n"
        send(raw: Data(response.utf8))
        phase = .frames
        return true
    }

    private static func webSocketAccept(for key: String) -> String {
        // RFC 6455 §4.2.2：Sec-WebSocket-Accept = base64(SHA-1(key + GUID))。
        let magic = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
        let digest = Insecure.SHA1.hash(data: Data((key + magic).utf8))
        return Data(digest).base64EncodedString()
    }

    // MARK: - 帧解析（客户端帧必须掩码）

    private func consumeFrame() -> (opcode: UInt8, payload: Data)? {
        let buffer = receiveBuffer
        guard buffer.count >= 2 else { return nil }
        let first = buffer[buffer.startIndex]
        let second = buffer[buffer.startIndex + 1]
        guard first & 0x80 != 0 else {
            // 不支持分片：本服务消息均为小 JSON，单帧送达。
            finish()
            return nil
        }
        let opcode = first & 0x0F
        let masked = second & 0x80 != 0
        guard masked else {
            // 客户端帧必须掩码（RFC 6455 §5.1）。
            finish()
            return nil
        }
        var length = Int(second & 0x7F)
        var offset = 2
        if length == 126 {
            guard buffer.count >= offset + 2 else { return nil }
            length = Int(buffer[buffer.startIndex + offset]) << 8
                | Int(buffer[buffer.startIndex + offset + 1])
            offset += 2
        } else if length == 127 {
            guard buffer.count >= offset + 8 else { return nil }
            var extended: UInt64 = 0
            for i in 0..<8 {
                extended = extended << 8 | UInt64(buffer[buffer.startIndex + offset + i])
            }
            guard extended <= UInt64(Int.max) else {
                finish()
                return nil
            }
            length = Int(extended)
            offset += 8
        }
        // 帧长上限：分块协议单帧 ≤64KB，2MB 余量充足。防止本机恶意/异常进程
        // 声明超长帧迫使 receiveBuffer 无限累积（服务只绑 127.0.0.1，仍设防）。
        guard length <= Self.maxFrameLength else {
            finish()
            return nil
        }
        guard buffer.count >= offset + 4 + length else { return nil }
        let maskStart = buffer.startIndex + offset
        let mask = Array(buffer[maskStart..<(maskStart + 4)])
        offset += 4
        var payload = Data(buffer[(buffer.startIndex + offset)..<(buffer.startIndex + offset + length)])
        for i in 0..<payload.count {
            payload[payload.startIndex + i] ^= mask[i % 4]
        }
        receiveBuffer.removeSubrange(receiveBuffer.startIndex..<(buffer.startIndex + offset + length))
        return (opcode, payload)
    }

    private func handle(_ frame: (opcode: UInt8, payload: Data)) {
        switch frame.opcode {
        case 0x1: // text
            if let text = String(data: frame.payload, encoding: .utf8) {
                onMessage(text)
            }
        case 0x8: // close：回 close 帧并待发送完成后再断开
            send(raw: Data([0x88, 0x00]), completion: { [weak self] in
                self?.finish()
            })
        case 0x9: // ping → pong
            sendPong()
        default:
            break
        }
    }

    // MARK: - 发送（服务端帧不掩码）

    func send(text: String) {
        guard !finished, let data = text.data(using: .utf8) else { return }
        send(raw: Self.textFrame(payload: data))
    }

    private func sendPong() {
        guard !finished else { return }
        send(raw: Data([0x8A, 0x00]))
    }

    private func send(raw: Data, completion: (@Sendable () -> Void)? = nil) {
        connection.send(content: raw, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            // 发送失败说明链路已不可用：立即断开触发 onClose 收层，
            // 不等心跳超时（≤8s）才发现，避免命令静默丢失。
            if error != nil {
                self.finish()
                return
            }
            completion?()
        })
    }

    private static func textFrame(payload: Data) -> Data {
        var frame = Data()
        frame.append(0x81) // FIN + text
        let length = payload.count
        if length < 126 {
            frame.append(UInt8(length))
        } else if length <= 0xFFFF {
            frame.append(126)
            frame.append(UInt8((length >> 8) & 0xFF))
            frame.append(UInt8(length & 0xFF))
        } else {
            frame.append(127)
            // RFC 6455 §5.2：64 位长度按网络字节序（大端）。
            let extended = UInt64(length)
            for shift in stride(from: 56, through: 0, by: -8) {
                frame.append(UInt8((extended >> UInt64(shift)) & 0xFF))
            }        }
        frame.append(payload)
        return frame
    }

    private func finish() {
        guard !finished else { return }
        finished = true
        connection.cancel()
        if !suppressCloseNotification {
            onClose()
        }
    }
}
