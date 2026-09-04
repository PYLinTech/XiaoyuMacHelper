import Foundation

// MARK: - WPS 桥接加载项

/// WPS 幻灯片批注桥接加载项：负责把内嵌的加载项文件安装/卸载到 WPS 的 jsaddons 目录。
///
/// 部署方式（WPS 官方「jsplugin 离线模式」，Windows/Linux/macOS 通用）：
/// - `jsaddons/publish.xml` 登记 `<jsplugin name version type url/>` 条目；
/// - `jsaddons/<name>_<version>/` 文件夹承载 `ribbon.xml`（根目录）与脚本
///   `js/main.js`（js 子目录）。实测铁证：WPS 启动时会自动创建根目录
///   `index.html`，内容固定为 `<script type='text/javascript' src='js/main.js'>`，
///   即脚本必须位于 `js/` 子目录才能被引入；开发者不应自建 `index.html`，
///   否则会与自动生成逻辑冲突；
/// - WPS 启动时读取 publish.xml 并加载对应文件夹的加载项（首次加载会弹授权确认）。
///
/// macOS 上沙盒版 WPS 的 jsaddons 位于
/// `~/Library/Containers/com.kingsoft.wpsoffice.mac/Data/.kingsoft/wps/jsaddons`，
/// 非沙盒版回退 `~/.kingsoft/wps/jsaddons`。
///
/// 通信方式：加载项后台页与 MacHelper 建立 `ws://127.0.0.1:47613/slideshow`
/// WebSocket 长连接（RFC 6455，JSON 文本帧），双向：
/// - 加载项 → MacHelper：`begin`（放映窗口精确位置/页码/总页数）、`page`（翻页）、
///   `end`（放映结束）、`heartbeat`（放映中保活）、`log`（仅异常留痕，常规
///   事件不落日志——通信热路径零日志零磁盘 IO）；
/// - MacHelper → 加载项：`next` / `previous` / `goto` / `exit` 命令，
///   加载项调用放映视图 `View.Next()/Previous()/GotoSlide()/Exit()`，不再投递按键。
enum SlideshowAnnotationAddin {
    /// 加载项标识（publish.xml 的 name 与文件夹前缀）。
    static let name = "XiaoyuMacHelper-SlideshowAddin"
    static let version = "1"

    /// 脚本修订号（helper 内置变量，插件自身不带版本号）：改动 main.js 时
    /// 递增，插件更新始终由 helper 执行。安装写盘成功后同步写入
    /// 主程序自己的 UserDefaults（主程序可读的外部数据层，零系统权限请求），
    /// 启动检查只比对这个记录版本，**不回读 WPS 容器内的脚本文件**——跨容器
    /// 读取会触发「访问其他 APP 数据」的系统授权弹窗。
    static let scriptRevision = 1

    /// 已安装脚本修订号的 UserDefaults 键（主程序自己的数据层）。
    private static let installedRevisionKey = "SlideshowAddinInstalledScriptRevision"

    /// MacHelper 本机 WebSocket 服务端口；与 main.js 内嵌端口保持一致。
    static let helperPort: UInt16 = 47613

    // MARK: - 路径

    /// WPS 的 jsaddons 目录：优先实际存在的候选路径，均不存在时默认沙盒容器路径。
    static var jsaddonsDirectory: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let sandboxed = home.appendingPathComponent(
            "Library/Containers/com.kingsoft.wpsoffice.mac/Data/.kingsoft/wps/jsaddons"
        )
        let standalone = home.appendingPathComponent(".kingsoft/wps/jsaddons")
        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: sandboxed.path),
           fileManager.fileExists(atPath: standalone.path) {
            return standalone
        }
        return sandboxed
    }

    private static var publishURL: URL {
        jsaddonsDirectory.appendingPathComponent("publish.xml")
    }

    private static var addonDirectory: URL {
        jsaddonsDirectory.appendingPathComponent("\(name)_\(version)")
    }

    // 缩略图导出目录不设 Swift 侧常量：导出目录在 WPS 容器的系统临时
    // 目录（FileSystem.tmpdir()/XiaoyuMacHelper-SlideshowAddin-WorkDir/SlideExport），
    // 由脚本运行时解析。实测（DiagTest v6/v7）：jsaddons 插件目录下文件任何
    // 时刻删除都静默失败（Remove/unlinkSync 对含 / 路径一律 ret=null），而
    // tmpdir() 所在容器 Data/tmp 区域 unlinkSync 任何时刻删除可用，故导出
    // 目录必须落在 tmp。主程序不读此目录，插件在放映开始/结束各清空一次。

    // MARK: - 安装 / 卸载

    /// 安装（幂等）：写入加载项文件并在 publish.xml 登记，需重启 WPS 后生效。
    /// 全部写盘成功后才把脚本修订号写入主程序自己的 UserDefaults——写盘失败
    /// （如未授予访问权限）不记版本，下次启动检查会自动重装并提示。
    static func install() throws {
        let fileManager = FileManager.default
        do {
            try fileManager.createDirectory(at: addonDirectory, withIntermediateDirectories: true)
            // WPS 自动生成的 index.html 固定以 `js/main.js` 引入脚本，脚本必须位于
            // js 子目录（实测铁证），ribbon.xml 保持在加载项根目录。
            let jsDirectory = addonDirectory.appendingPathComponent("js")
            try fileManager.createDirectory(at: jsDirectory, withIntermediateDirectories: true)
            try mainJSTemplate.write(
                to: jsDirectory.appendingPathComponent("main.js"),
                atomically: true,
                encoding: .utf8
            )
            try ribbonXML.write(
                to: addonDirectory.appendingPathComponent("ribbon.xml"),
                atomically: true,
                encoding: .utf8
            )
            try writePublishRegistration(registered: true)
            UserDefaults.standard.set(scriptRevision, forKey: installedRevisionKey)
            SlideshowAnnotationLog.info("加载项已安装 name=\(name) 修订=r\(scriptRevision) 目录=\(addonDirectory.path)")
        } catch {
            SlideshowAnnotationLog.info("加载项安装失败 name=\(name): \(error)")
            throw error
        }
    }

    /// 卸载：删除加载项文件夹并从 publish.xml 移除登记（其他加载项条目保持原样）；
    /// 同步清除主程序数据层的版本记录。
    static func uninstall() {
        try? FileManager.default.removeItem(at: addonDirectory)
        UserDefaults.standard.removeObject(forKey: installedRevisionKey)
        do {
            try writePublishRegistration(registered: false)
        } catch {
            SlideshowAnnotationLog.info("卸载: publish.xml 登记移除失败: \(error)")
        }
        SlideshowAnnotationLog.info("加载项已卸载 name=\(name)")
    }

    /// 是否需要脚本更新（只读主程序自己的 UserDefaults 版本记录，零权限请求）：
    /// 记录版本 ≠ 代码版本（含无记录）。真正重装由 refreshInstalledIfNeeded() 执行。
    static var needsScriptRefresh: Bool {
        UserDefaults.standard.integer(forKey: installedRevisionKey) != scriptRevision
    }

    /// 重装脚本（仅开关开启时调用）：记录版本 ≠ 代码版本（含无记录）时写 WPS
    /// jsaddons 并补写版本记录，返回是否发生了更新——更新后需重启 WPS 生效。
    /// 注意：写 WPS 目录会触发「访问其他 APP 数据」系统授权弹窗，调用前应先
    /// 向用户弹窗告知（先告知、后请求）。
    @discardableResult
    static func refreshInstalledIfNeeded() -> Bool {
        let installed = UserDefaults.standard.integer(forKey: installedRevisionKey)
        guard installed != scriptRevision else { return false }
        do {
            try install()
            SlideshowAnnotationLog.info("加载项脚本已更新: r\(installed) → r\(scriptRevision)，需重启 WPS 生效")
            return true
        } catch {
            SlideshowAnnotationLog.info("加载项脚本更新失败: \(error)")
            return false
        }
    }

    // MARK: - publish.xml 登记

    /// 增量更新 publish.xml：先移除本加载项旧条目，`registered` 时追加新条目。
    private static func writePublishRegistration(registered: Bool) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: jsaddonsDirectory, withIntermediateDirectories: true)

        let document: XMLDocument
        if let data = try? Data(contentsOf: publishURL),
           let existing = try? XMLDocument(data: data, options: [.nodePreserveAll]),
           existing.rootElement()?.name == "jsplugins" {
            document = existing
        } else {
            document = XMLDocument(rootElement: XMLElement(name: "jsplugins"))
            document.version = "1.0"
            document.characterEncoding = "UTF-8"
        }
        guard let root = document.rootElement() else { return }

        for child in (root.children ?? []).reversed() where isOurEntry(child) {
            root.removeChild(at: child.index)
        }

        if registered {
            let entry = XMLElement(name: "jsplugin")
            for (attributeName, value) in [
                ("name", name),
                // 启用键固定写死实测值 enable_dev：本机 WPS 只认该取值加载插件，
                // 不做旧键（true）兼容处理。
                ("enable", "enable_dev"),
                ("url", "file://"),
                ("type", "wpp"),
                ("version", version)
            ] {
                guard let attribute = XMLNode.attribute(withName: attributeName, stringValue: value) as? XMLNode else {
                    continue
                }
                entry.addAttribute(attribute)
            }
            root.addChild(entry)
        }

        try document.xmlData(options: [.nodePrettyPrint]).write(to: publishURL)
    }

    private static func isOurEntry(_ node: XMLNode) -> Bool {
        guard let element = node as? XMLElement,
              element.name == "jsplugin" || element.name == "jspluginonline" else {
            return false
        }
        return element.attribute(forName: "name")?.stringValue == name
    }

    // MARK: - 加载项资源

    /// 脚本入口：WPS 启动时在加载项目录自动创建 `index.html`，内容固定为
    /// `<script src='js/main.js'>`，因此本文件会被安装到加载项的 `js/main.js`。
    /// 开发者不提供页面文件，因此不会产生任何可见 UI / 黑块。
    /// 页面加载即建立 WebSocket 长连接并注册演示事件，全程事件驱动、无轮询。
    /// 缩略图导出目录由脚本运行时用 FileSystem.tmpdir() 解析（不再
    /// 由 Swift 侧注入，见上方导出目录迁移说明）。
    private static let mainJSTemplate = #"""
(function () {
    "use strict";

    // MacHelper 本机 WebSocket 服务；端口与 SlideshowAnnotationAddin.helperPort 一致。
    var WS_URL = "ws://127.0.0.1:47613/slideshow";
    // 缩略图导出目录：固定为 <FileSystem.tmpdir()>/XiaoyuMacHelper-SlideshowAddin-
    // WorkDir/SlideExport/，运行时解析。实测（DiagTest v6/v7）：tmpdir() 位于
    // WPS 容器 Data/tmp，该区域内 unlinkSync 删除任何时刻可用（jsaddons 插件
    // 目录下删除永远静默失败）；目录名固定，便于跨场次清扫残留。
    var EXPORT_WORK_DIR = "XiaoyuMacHelper-SlideshowAddin-WorkDir/SlideExport";
    var EXPORT_BASE = "";   // 带尾部 / 的实际导出基路径，ensureExportBase() 解析后缓存
    // 回执 base64 分块大小（32KB）：r6 的 128KB、r8 的 64KB 单帧均断链，
    // r7 的 16KB 稳但帧数多。r9 折中取 32KB（32768，含 JSON 包装后单帧
    // 约 33KB，稳低于 WS 16-bit 长度场上限 65535）。连接日志带此值作指纹。
    var EXPORT_CHUNK_SIZE = 32768;
    var HEARTBEAT_INTERVAL = 3000;
    var MAX_RECONNECT_MS = 10000;

    var ws = null;
    var showing = false;
    var lastWindow = null;      // 最近一次事件回调携带的放映窗口（放映期间主动查询不可靠）
    var lastPostedPage = 0;
    var lastPostedTotal = 0;
    var registerAttempts = 0;
    var reconnectAttempts = 0;
    var heartbeatTimer = null;

    // ---------- 连接 ----------

    function connect() {
        try {
            ws = new WebSocket(WS_URL);
        } catch (e) {
            scheduleReconnect();
            return;
        }
        ws.onopen = function () {
            reconnectAttempts = 0;
            // 连接断开期间放映可能仍在进行：重连成功后补发 begin 自愈，
            // 让 MacHelper 重新叠加批注层（事件驱动，非轮询）。
            if (showing && lastWindow) {
                reportBegin(lastWindow);
            }
        };
        ws.onmessage = function (event) {
            handleCommand(String(event.data));
        };
        ws.onclose = function () {
            ws = null;
            stopHeartbeat();
            scheduleReconnect();
        };
        ws.onerror = function () {
            try { ws.close(); } catch (e) { }
        };
    }

    function scheduleReconnect() {
        var delay = Math.min(1000 * Math.pow(2, reconnectAttempts), MAX_RECONNECT_MS);
        reconnectAttempts += 1;
        setTimeout(connect, delay);
    }

    // ---------- 上行 ----------

    function send(payload) {
        if (!ws || ws.readyState !== 1) { return; }
        try {
            ws.send(JSON.stringify(payload));
        } catch (e) { }
    }

    function jlog(msg) {
        send({ type: "log", msg: String(msg) });
    }

    // 当前页码/总页数：优先用事件回调传入的放映窗口。
    function slideIndex(Wn) {
        try {
            var index = Wn.View.Slide.SlideIndex;
            return index > 0 ? index : 0;
        } catch (e) {
            return 0;
        }
    }

    function slideCount(Wn) {
        try {
            var count = Wn.Presentation.Slides.Count;
            return count > 0 ? count : 0;
        } catch (e) {
            return 0;
        }
    }

    function reportBegin(Wn) {
        lastWindow = Wn;
        showing = true;
        var page = slideIndex(Wn);
        var total = slideCount(Wn);
        lastPostedPage = page;
        lastPostedTotal = total;
        var payload = { type: "begin", page: page || 1, total: total, x: 0, y: 0, w: 0, h: 0 };
        try {
            // SlideShowWindow 的 Left/Top/Width/Height：主屏左上原点、pt 单位。
            payload.x = Wn.Left;
            payload.y = Wn.Top;
            payload.w = Wn.Width;
            payload.h = Wn.Height;
        } catch (e) { }
        send(payload);
        startHeartbeat();
    }

    function reportPage(Wn) {
        if (!Wn) { return; }
        var page = slideIndex(Wn);
        var total = slideCount(Wn);
        if (page > 0 && (page !== lastPostedPage || total !== lastPostedTotal)) {
            lastPostedPage = page;
            lastPostedTotal = total;
            send({ type: "page", page: page, total: total });
        }
    }

    // ---------- 演示事件（事件回调首个参数即放映窗口） ----------

    function onBegin(Wn) {
        reportBegin(Wn);
        // 放映开始清空导出目录与内存缓存（两处清理时机之一）：上一场残留的
        // 同页码 PNG/缓存直传必然串图，必须在开场全部作废。
        resetExportedPageCache();
        if (ensureExportBase()) {
            clearExportDirectory("放映开始");
        }
    }

    function onEnd() {
        if (!showing) { return; }
        showing = false;
        stopHeartbeat();
        lastPostedPage = 0;
        lastPostedTotal = 0;
        // 放映结束清空导出目录与内存缓存（两处清理时机之二）。
        resetExportedPageCache();
        if (EXPORT_BASE) {
            clearExportDirectory("放映结束");
        }
        send({ type: "end" });
    }

    function onPageEvent(Wn) {
        reportPage(Wn);
    }

    // ---------- 下行命令 ----------

    function handleCommand(text) {
        var command;
        try {
            command = JSON.parse(text);
        } catch (e) {
            jlog("命令 JSON 解析失败: " + String(text).slice(0, 200));
            return;
        }
        var type = command.type;
        if (type === "next") {
            invokeView("next");
        } else if (type === "previous") {
            invokeView("previous");
        } else if (type === "goto") {
            invokeView("goto", command.page);
        } else if (type === "exit") {
            invokeView("exit");
        } else if (type === "export") {
            exportPages(command.pages || []);
        } else {
            jlog("未知命令类型: " + type);
        }
    }

    // 按需导出：主程序请求指定页（页码预览懒加载，按当前页邻域交错下发）。
    // 逐页串行 + 20ms 间隔，避免阻塞事件循环影响放映交互；每页处理后立即
    // 回报（流式到位、边到边显示）。Slide.Export 用默认尺寸参数：导出图跟随
    // 文稿真实比例，不传宽高。
    // 导出文件按页码命名（slide_<page>.png），整个放映会话内一页只导一次：
    // 目录里已存在的页直接读回回传（主程序预览关闭重开时不重复导出）。
    // 导出成功后用 FileSystem.readAsBinaryString 读回 PNG 字节，自研 toBase64
    // 编码后经 WebSocket 私有端口直传——不用 btoa（WPS 读回的二进制串含
    // charCode > 255 的字符，btoa 会抛 Latin1 范围异常），主程序不读文件。
    // 页图 base64 会话内内存缓存（FIFO 上限 128 页）：主程序滚回/重开预览
    // 重复请求时免 Exists 判定与文件读取，命中即直传。
    var exportedPageCache = {};
    var exportedPageCacheOrder = [];
    var EXPORTED_PAGE_CACHE_LIMIT = 128;
    // 清空页缓存：放映开始/结束各调一次（与磁盘目录清理同步）。缓存跨场次
    // 复用会让新一场"内存缓存命中"直传上一场的旧图（DiagTest 实锤的串图 bug）。
    function resetExportedPageCache() {
        exportedPageCache = {};
        exportedPageCacheOrder = [];
    }
    function cacheExportedPage(page, data) {
        if (exportedPageCache[page]) { return; }
        exportedPageCache[page] = data;
        exportedPageCacheOrder.push(page);
        while (exportedPageCacheOrder.length > EXPORTED_PAGE_CACHE_LIMIT) {
            var oldest = exportedPageCacheOrder.shift();
            delete exportedPageCache[oldest];
        }
    }
    function exportPages(pages) {
        if (!showing || !lastWindow) {
            jlog("收到 export 但未在放映状态");
            return;
        }
        // 导出目录未就绪（tmpdir 不可用等）：整批失败回执，主程序可提示重试。
        if (!ensureExportBase()) {
            jlog("导出目录不可用，export 全部失败回执");
            for (var k = 0; k < pages.length; k++) {
                send({ type: "exported", page: pages[k], ok: false, seq: 0, total: 1, data: "" });
            }
            return;
        }
        if (typeof wps === "undefined" || !wps.FileSystem || typeof wps.FileSystem.Exists !== "function") {
            jlog("wps.FileSystem.Exists 不可用(typeof=" + (typeof wps !== "undefined" ? typeof wps.FileSystem : "no wps") + ")，无法按页判重");
        }
        var run = function (i) {
            if (i >= pages.length) { return; }
            var page = pages[i];
            var data = exportedPageCache[page] || "";
            if (!data) {
                var path = EXPORT_BASE + "slide_" + page + ".png";
                try {
                    if (!wps.FileSystem.Exists(path)) {
                        lastWindow.Presentation.Slides.Item(page).Export(path, "PNG");
                    }
                    var bin = wps.FileSystem.readAsBinaryString(path);
                    if (bin && typeof bin === "string" && bin.length > 0) {
                        data = toBase64(bin);
                        cacheExportedPage(page, data);
                    } else {
                        jlog("第 " + page + " 页读回失败(typeof=" + typeof bin + ")");
                    }
                } catch (e) {
                    jlog("导出/读取第 " + page + " 页失败: " + (e && e.message));
                }
            }
            if (data !== "") {
                sendExported(page, data);
            } else {
                send({ type: "exported", page: page, ok: false, seq: 0, total: 1, data: "" });
            }
            setTimeout(function () { run(i + 1); }, 20);
        };
        run(0);
    }

    // 回执分块发送：实测 WPS 的 WebSocket 发 0.9MB、128KB 单帧均直接断链。
    // 始终按 EXPORT_CHUNK_SIZE 切块走 seq/total 协议（哪怕只有 1 片也报
    // total=1），主程序统一按分片重组，不再有单块直传旁路。逐帧异步发送
    // （setTimeout 0 间隔，让引擎每帧落盘）。
    function sendExported(page, data) {
        var total = Math.ceil(data.length / EXPORT_CHUNK_SIZE);
        var seq = 0;
        var step = function () {
            if (seq >= total) { return; }
            send({
                type: "exported", page: page, ok: true,
                seq: seq, total: total,
                data: data.substr(seq * EXPORT_CHUNK_SIZE, EXPORT_CHUNK_SIZE)
            });
            seq += 1;
            setTimeout(step, 0);
        };
        step();
    }

    // 自研 base64（RFC 4648）：WPS 的 readAsBinaryString 返回串可能含 charCode
    // > 255 的字符，逐字符 charCodeAt & 0xff 还原字节（社区验证的 WPS 二进制
    // 串还原方式），再查表编码。分块拼接（每块约 32K 输入字符，3 的倍数保证
    // 块内分组完整），避免百万字符级 PNG 一次性字符串累加的内存与性能问题。
    function toBase64(bin) {
        var table = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
        var out = [];
        var length = bin.length;
        var i = 0;
        while (i < length) {
            var chunkEnd = Math.min(i + 32760, length);
            var part = "";
            while (i < chunkEnd) {
                var b0 = bin.charCodeAt(i) & 0xff;
                var b1 = i + 1 < length ? bin.charCodeAt(i + 1) & 0xff : 0;
                var b2 = i + 2 < length ? bin.charCodeAt(i + 2) & 0xff : 0;
                part += table[b0 >> 2]
                    + table[((b0 & 3) << 4) | (b1 >> 4)]
                    + (i + 1 < length ? table[((b1 & 15) << 2) | (b2 >> 6)] : "=")
                    + (i + 2 < length ? table[b2 & 63] : "=");
                i += 3;
            }
            out.push(part);
        }
        return out.join("");
    }

    // 解析导出目录基路径并确保目录存在（首场放映前目录尚不存在）：
    // tmpdir() 实测返回容器 Data/tmp（无尾部 /），逐级建两层固定目录。
    // 成功后缓存到 EXPORT_BASE，失败返回空串（调用方放弃导出并回执失败）。
    function ensureExportBase() {
        if (EXPORT_BASE) { return EXPORT_BASE; }
        try {
            if (typeof wps === "undefined" || !wps.FileSystem || typeof wps.FileSystem.tmpdir !== "function") {
                jlog("FileSystem.tmpdir 不可用，导出目录无法解析");
                return "";
            }
            var tmp = String(wps.FileSystem.tmpdir()).replace(/\/+$/, "");
            var workDir = tmp + "/XiaoyuMacHelper-SlideshowAddin-WorkDir";
            var slideDir = workDir + "/SlideExport";
            if (!wps.FileSystem.Exists(workDir)) { wps.FileSystem.Mkdir(workDir); }
            if (!wps.FileSystem.Exists(slideDir)) { wps.FileSystem.Mkdir(slideDir); }
            if (!wps.FileSystem.Exists(slideDir)) {
                jlog("导出目录创建失败: " + slideDir);
                return "";
            }
            EXPORT_BASE = slideDir + "/";
            return EXPORT_BASE;
        } catch (e) {
            jlog("导出目录解析失败: " + (e && e.message));
            return "";
        }
    }

    // 清空导出目录（插件自己执行，主程序不碰该目录）。目录固定保留，只在
    // 放映开始/结束各清一次（调用方传 reason 标识）。实测（DiagTest v6/v7）：
    // tmp 区域逐文件 unlinkSync 返回 true 且 Exists 复验通过；jsaddons 目录下
    // 删除永远静默失败，故不再有目录级回退。逐文件接返回值 + Exists 复验，
    // 失败明细（含文件名）落日志。
    function clearExportDirectory(reason) {
        var dir = EXPORT_BASE.replace(/\/+$/, "");
        var cleared = 0;
        var failed = [];
        try {
            var entries = wps.FileSystem.readdirSync(dir);
            for (var i = 0; entries && i < entries.length; i++) {
                var name = typeof entries[i] === "string" ? entries[i] : (entries[i].name || "");
                if (!name) { continue; }
                var path = dir + "/" + name;
                var ok = false;
                try { ok = wps.FileSystem.unlinkSync(path) === true; } catch (e2) { }
                if (ok && wps.FileSystem.Exists(path)) { ok = false; }
                if (ok) {
                    cleared += 1;
                } else {
                    failed.push(name);
                }
            }
        } catch (e) {
            jlog(reason + "清空导出目录: 列目录失败(目录可能不存在): " + (e && e.message));
            return;
        }
        if (failed.length) {
            jlog(reason + "清空导出目录: 删除 " + cleared + " 项, 失败 " + failed.length + " 项: " + failed.join(","));
        }
    }

    // 放映命令统一走事件回调缓存的放映窗口（放映期间 Application.SlideShowWindow 不可靠）。
    function invokeView(action, argument) {
        if (!showing || !lastWindow) {
            jlog("收到命令 " + action + " 但当前未在放映状态");
            return;
        }
        try {
            var view = lastWindow.View;
            if (action === "next") {
                view.Next();
            } else if (action === "previous") {
                view.Previous();
            } else if (action === "goto") {
                view.GotoSlide(argument);
            } else if (action === "exit") {
                view.Exit();
            }
            // 命令成功执行后，翻页事件（OnNext/OnPrevious）会触发页码上报；
            // goto 跳转可能不触发，主动同步一次（事件若随后到达会自动去重）。
            if (action !== "exit") {
                setTimeout(function () { reportPage(lastWindow); }, 120);
            }
        } catch (e) {
            jlog("命令 " + action + " 执行失败: " + (e && e.message));
        }
    }

    // 放映中保活心跳：MacHelper 侧超时收起依赖它；连接断开也会通知 MacHelper。
    // 间隔 3s：MacHelper 的 8s 超时约覆盖两拍，兼顾低上行频率与健壮性。
    function startHeartbeat() {
        stopHeartbeat();
        heartbeatTimer = setInterval(function () {
            if (showing) {
                send({ type: "heartbeat" });
            }
        }, HEARTBEAT_INTERVAL);
    }

    function stopHeartbeat() {
        if (heartbeatTimer) {
            clearInterval(heartbeatTimer);
            heartbeatTimer = null;
        }
    }

    // ---------- 事件注册 ----------

    function register() {
        try {
            var api = wps.ApiEvent;
            if (!api || typeof api.AddApiEventListener !== "function") {
                throw new Error("wps.ApiEvent.AddApiEventListener 不可用");
            }
            api.AddApiEventListener("SlideShowBegin", onBegin);
            api.AddApiEventListener("SlideShowEnd", onEnd);
            api.AddApiEventListener("SlideShowNextSlide", onPageEvent);
            api.AddApiEventListener("SlideShowOnNext", onPageEvent);
            api.AddApiEventListener("SlideShowOnPrevious", onPageEvent);
        } catch (e) {
            // wps 桥对象尚未就绪时延迟重试（最多约 30 秒）。
            if (++registerAttempts < 30) {
                setTimeout(register, 1000);
            } else {
                jlog("演示事件注册失败: " + (e && e.message));
            }
        }
    }

    register();
    connect();
})();
"""#

    /// 极简功能区定义：本加载项纯后台运行，不添加任何可见 UI。
    private static let ribbonXML = #"""
<?xml version="1.0" encoding="UTF-8"?>
<customUI>
    <ribbon startFromScratch="false">
    </ribbon>
</customUI>
"""#
}
