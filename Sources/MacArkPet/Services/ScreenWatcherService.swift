// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 MacArkPet contributors

import AppKit
import ApplicationServices
import Combine

// MARK: - 屏幕上下文信息

struct ScreenContext: Equatable {
    /// 前台 app 名称（本地化名称）
    let appName: String
    /// 前台 app bundle ID
    let bundleID: String
    /// 前台窗口标题（如果可通过 AX API 获取）
    let windowTitle: String
    /// 匹配到的情境（如 "coding", "watching_video"）
    let category: String
    /// 是否为纯浏览（无特定匹配时）
    let isBrowsing: Bool
    /// 当前时段
    let dayPhase: DayPhase
    /// 距离上次用户操作（键盘/鼠标）的秒数
    let idleSeconds: TimeInterval

    enum DayPhase: String {
        case dawn = "dawn"
        case morning = "morning"
        case noon = "noon"
        case afternoon = "afternoon"
        case evening = "evening"
        case night = "night"
        case lateNight = "lateNight"

        var label: String {
            switch self {
            case .dawn: return "清晨"
            case .morning: return "上午"
            case .noon: return "中午"
            case .afternoon: return "下午"
            case .evening: return "傍晚"
            case .night: return "夜晚"
            case .lateNight: return "深夜"
            }
        }
    }

    var isDeepNight: Bool {
        dayPhase == .lateNight
    }

    var isIdleLong: Bool {
        idleSeconds > 300  // 5 分钟无操作
    }

    /// 人类可读的上下文摘要（用于调试/显示）
    var summary: String {
        "[\(dayPhase.label)] \(appName) — \(category) — \"\(windowTitle)\""
    }
}

// MARK: - 屏幕观察器

@MainActor
final class ScreenWatcherService {
    static let shared = ScreenWatcherService()

    // MARK: - 可观察状态

    @Published private(set) var currentContext: ScreenContext?

    /// 上下文变化时发布（用于联动 DialogueEngine）
    let contextDidChange = PassthroughSubject<ScreenContext, Never>()

    // MARK: - 内部状态

    private var timer: DispatchSourceTimer?
    private var lastContext: ScreenContext?
    private var lastWindowTitleCheck = Date.distantPast
    private var keyboardEventTap: CFMachPort?
    private var mouseEventTap: CFMachPort?
    private var lastInputEvent = Date()
    private var keywordMap: [String: String] = [:]   // 小写关键词 → category
    private var bundleMap: [String: String] = [:]    // bundle ID → category
    private var isActive = false

    // MARK: - 配置路径

    static let configDir: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MacArkPet", isDirectory: true)
            .appendingPathComponent("Config", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    static let configURL = configDir.appendingPathComponent("ScreenTriggers.toml")
    static let bundledConfigURL = Bundle.main.resourceURL?.appendingPathComponent("ScreenTriggers.toml")
        ?? URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Resources/ScreenTriggers.toml")

    private init() {}

    // MARK: - 生命周期

    func start() {
        guard !isActive else { return }
        isActive = true

        loadConfig()
        copyConfigIfNeeded()
        installInputMonitor()
        startPolling()
    }

    func stop() {
        guard isActive else { return }
        isActive = false
        timer?.cancel()
        timer = nil
        if let tap = keyboardEventTap {
            CFMachPortInvalidate(tap)
        }
        if let tap = mouseEventTap {
            CFMachPortInvalidate(tap)
        }
    }

    // MARK: - 配置加载

    func loadConfig() {
        // 尝试用户配置 → 捆绑配置
        let urls = [Self.configURL, Self.bundledConfigURL]
        for url in urls {
            guard FileManager.default.fileExists(atPath: url.path),
                  let content = try? String(contentsOf: url, encoding: .utf8),
                  let parsed = parseTOML(content) else {
                continue
            }
            applyConfig(parsed)
            NSLog("[ScreenWatcher] Loaded config from \(url.path)")
            return
        }
        NSLog("[ScreenWatcher] No config found, using defaults")
    }

    // MARK: - 轮询

    private func startPolling() {
        timer?.cancel()
        let source = DispatchSource.makeTimerSource(queue: .main)
        source.schedule(deadline: .now() + 1.0, repeating: 3.0, leeway: .milliseconds(500))
        source.setEventHandler { [weak self] in
            self?.poll()
        }
        timer = source
        source.resume()
        // 立即进行一次
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.poll()
        }
    }

    private func poll() {
        // 1. 获取前台应用
        guard let app = NSWorkspace.shared.frontmostApplication,
              let bundleID = app.bundleIdentifier,
              let appName = app.localizedName else {
            return
        }

        // 2. 获取窗口标题 (每 3 秒检查一次)
        let now = Date()
        var windowTitle = ""
        if now.timeIntervalSince(lastWindowTitleCheck) > 2.0 {
            windowTitle = getWindowTitle(for: app)
            lastWindowTitleCheck = now
        }

        // 3. 匹配情境
        let category = matchCategory(appName: appName, bundleID: bundleID, windowTitle: windowTitle)

        // 4. 时段
        let dayPhase = currentDayPhase()

        // 5. 闲置时间
        let idleSeconds = now.timeIntervalSince(lastInputEvent)

        // 6. 构建 context
        let context = ScreenContext(
            appName: appName,
            bundleID: bundleID,
            windowTitle: windowTitle,
            category: category,
            isBrowsing: (category == "browsing" || category == "other"),
            dayPhase: dayPhase,
            idleSeconds: idleSeconds
        )

        // 7. 若发生变化，发布通知
        if context != lastContext {
            lastContext = context
            currentContext = context
            contextDidChange.send(context)
        }
    }

    // MARK: - 辅助功能权限 → 窗口标题

    private func getWindowTitle(for app: NSRunningApplication) -> String {
        guard app.isActive else { return "" }

        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        var focusedWindow: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(axApp, "kAXFocusedWindowAttribute" as CFString, &focusedWindow)

        guard result == .success, let axWindow = focusedWindow as! AXUIElement? else {
            return ""
        }

        var title: CFTypeRef?
        let titleResult = AXUIElementCopyAttributeValue(axWindow, "kAXTitleAttribute" as CFString, &title)

        guard titleResult == .success, let titleStr = title as? String, !titleStr.isEmpty else {
            return ""
        }

        return titleStr
    }

    // MARK: - 情境匹配引擎

    private func matchCategory(appName: String, bundleID: String, windowTitle: String) -> String {
        let lowerApp = appName.lowercased()
        let lowerBundle = bundleID.lowercased()
        let lowerTitle = windowTitle.lowercased()

        // 1. Bundle ID 精确匹配
        if let category = bundleMap[lowerBundle] {
            return category
        }

        // 2. Bundle ID 部分匹配
        for (key, category) in bundleMap {
            if lowerBundle.contains(key) || key.contains(lowerBundle) {
                return category
            }
        }

        // 3. 窗口标题关键词匹配
        for (keyword, category) in keywordMap {
            if lowerTitle.contains(keyword) || lowerApp.contains(keyword) {
                return category
            }
        }

        // 4. App 名称关键词匹配
        let appCategories: [(String, [String])] = [
            ("ai_chat", ["chatgpt", "claude", "deepseek", "kimi", "通义", "豆包", "gemini"]),
            ("gaming", ["steam", "battle.net", "epic games"]),
            ("developing", ["xcode", "code", "terminal", "vim"]),
            ("social", ["wechat", "微信", "qq", "dingtalk", "slack", "discord"]),
            ("working", ["notion", "word", "excel", "powerpoint", "preview", "finder"]),
            ("email", ["outlook", "mail", "thunderbird"]),
            ("writing", ["ulysses", "typora", "bear", "obsidian"]),
            ("designing", ["figma", "sketch", "photoshop", "illustrator", "affinity"]),
        ]

        for (category, keywords) in appCategories {
            if keywords.contains(where: { lowerBundle.contains($0) || lowerApp.contains($0) }) {
                return category
            }
        }

        // 5. 归类为浏览
        let browsers = ["safari", "chrome", "firefox", "edge", "opera", "arc", "brave", "vivaldi"]
        if browsers.contains(where: { lowerBundle.contains($0) }) {
            return "browsing"
        }

        return "other"
    }

    // MARK: - 时段判断

    private func currentDayPhase() -> ScreenContext.DayPhase {
        let hour = Calendar.current.component(.hour, from: Date())
        switch hour {
        case 5..<8:    return .dawn
        case 8..<12:   return .morning
        case 12..<14:  return .noon
        case 14..<18:  return .afternoon
        case 18..<21:  return .evening
        case 21..<24:  return .night
        default:       return .lateNight
        }
    }

    // MARK: - 输入事件监控

    private func installInputMonitor() {
        // 通过 IOHID 或 CGEvent 追踪最后一次输入事件
        Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self else { return }

            // 检查系统 idle 时间
            let idle = CGEventSource.secondsSinceLastEventType(
                .combinedSessionState,
                eventType: .keyDown
            )
            let mouseIdle = CGEventSource.secondsSinceLastEventType(
                .combinedSessionState,
                eventType: .leftMouseDown
            )
            let minIdle = min(idle, mouseIdle)

            if minIdle < 2.0 {
                self.lastInputEvent = Date()
            }
        }
    }

    // MARK: - 配置复制

    private func copyConfigIfNeeded() {
        let userURL = Self.configURL
        guard !FileManager.default.fileExists(atPath: userURL.path) else { return }

        let bundledURL = Self.bundledConfigURL
        guard FileManager.default.fileExists(atPath: bundledURL.path) else { return }

        try? FileManager.default.copyItem(at: bundledURL, to: userURL)
    }

    // MARK: - TOML 解析（简化版）

    private func parseTOML(_ content: String) -> [String: [(keyword: String, category: String)]]? {
        var result: [String: [(String, String)]] = [:]
        var currentCategory: String?

        for line in content.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // 跳过注释和空行
            if trimmed.isEmpty || trimmed.hasPrefix("#") {
                continue
            }

            // 检查区块头 [website_categories.xxx]
            if trimmed.hasPrefix("[") && trimmed.hasSuffix("]") {
                let inner = String(trimmed.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
                if inner.hasPrefix("website_categories.") {
                    currentCategory = String(inner.dropFirst("website_categories.".count))
                } else {
                    currentCategory = nil
                }
                continue
            }

            guard let category = currentCategory else { continue }

            // 解析 "keyword = ["value1", "value2", ...]"
            if let eqRange = trimmed.range(of: "=") {
                let keyPart = String(trimmed[..<eqRange.lowerBound]).trimmingCharacters(in: .whitespaces)
                let valuePart = String(trimmed[eqRange.upperBound...]).trimmingCharacters(in: .whitespaces)

                // 去掉外层 []
                if valuePart.hasPrefix("[") && valuePart.hasSuffix("]") {
                    let inner = String(valuePart.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
                    let values = parseTOMLArrayValues(inner)
                    for val in values {
                        let lowerVal = val.lowercased()
                        result[lowerVal, default: []].append((lowerVal, category))
                    }
                }
            }
        }

        return result
    }

    private func parseTOMLArrayValues(_ inner: String) -> [String] {
        var result: [String] = []
        var current = ""
        var inQuote = false

        for ch in inner {
            if ch == "\"" {
                inQuote.toggle()
            } else if ch == "," && !inQuote {
                let trimmed = current.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty {
                    result.append(trimmed)
                }
                current = ""
            } else {
                current.append(ch)
            }
        }
        let trimmed = current.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty {
            result.append(trimmed)
        }

        return result
    }

    private func applyConfig(_ parsed: [String: [(keyword: String, category: String)]]) {
        keywordMap.removeAll()
        bundleMap.removeAll()

        for (keyword, entries) in parsed {
            for (_, category) in entries {
                // 如果关键词看起来像 bundle ID（包含点号），归入 bundleMap
                if keyword.contains(".") || keyword.contains("/") {
                    bundleMap[keyword] = category
                } else {
                    keywordMap[keyword] = category
                }
            }
        }
    }
}
