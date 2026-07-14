// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 MacArkPet contributors

import Foundation
import AppKit
import Combine

// MARK: - 每日活动跟踪

struct DailyActivity: Codable {
    var date: String                          // "2026-07-13"
    var categoryDurations: [String: Int] = [:] // category -> 累计秒数
    var topApps: [String: Int] = [:]           // appName -> 累计秒数
    var totalActiveSeconds: Int = 0
    var totalIdleSeconds: Int = 0
    var firstActiveTime: String?               // "09:15"
    var lastActiveTime: String?                // "23:40"
    var pokeCount: Int = 0
    var feedCount: Int = 0
    var pomodoroSessions: Int = 0
    var diary: String?                         // AI 生成的日记
    var summary: String?                       // AI 生成的总结
}

private struct ActivityLog: Codable {
    var days: [String: DailyActivity] = [:]
}

@MainActor
final class ActivityTracker {
    static let shared = ActivityTracker()

    private(set) var today: DailyActivity
    private var log: ActivityLog = ActivityLog()
    private var lastContextChange: Date = Date()
    private var lastCategory: String = ""
    private var lastAppName: String = ""
    private var contextSub: AnyCancellable?

    private let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    private var storageURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MacArkPet", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("activity_log.json")
    }

    private init() {
        let todayStr = dateFormatter.string(from: Date())
        today = DailyActivity(date: todayStr)
        loadLog()
        if let existing = log.days[todayStr] {
            today = existing
        }
    }

    func start() {
        contextSub = ScreenWatcherService.shared.contextDidChange
            .receive(on: RunLoop.main)
            .sink { [weak self] context in
                MainActor.assumeIsolated {
                    self?.onContextChange(context)
                }
            }
        NSLog("[ActivityTracker] ✅ Started tracking")
    }

    // MARK: - 上下文变化处理

    private func onContextChange(_ context: ScreenContext) {
        let now = Date()
        checkDayRollover(now: now)

        // 计算上一个 context 的持续时间
        let elapsed = Int(now.timeIntervalSince(lastContextChange))
        if elapsed > 0 && elapsed < 3600 && !lastCategory.isEmpty {
            today.categoryDurations[lastCategory, default: 0] += elapsed
            if !lastAppName.isEmpty {
                today.topApps[lastAppName, default: 0] += elapsed
            }
            if context.idleSeconds < 300 {
                today.totalActiveSeconds += elapsed
            } else {
                today.totalIdleSeconds += elapsed
            }
        }

        // 更新时间记录
        let timeStr = timeFormatter.string(from: now)
        if today.firstActiveTime == nil {
            today.firstActiveTime = timeStr
        }
        today.lastActiveTime = timeStr

        lastContextChange = now
        lastCategory = context.category
        lastAppName = context.appName

        saveLog()
    }

    // MARK: - 互动计数

    func recordPoke() {
        checkDayRollover(now: Date())
        today.pokeCount += 1
    }

    func recordFeed() {
        checkDayRollover(now: Date())
        today.feedCount += 1
    }

    func recordPomodoroSession() {
        checkDayRollover(now: Date())
        today.pomodoroSessions += 1
    }

    // MARK: - 日记管理

    func getDiary(for date: String) -> String? {
        log.days[date]?.diary
    }

    func saveDiary(_ text: String, for date: String) {
        if log.days[date] != nil {
            log.days[date]?.diary = text
        } else {
            var activity = DailyActivity(date: date)
            activity.diary = text
            log.days[date] = activity
        }
        if date == today.date {
            today.diary = text
        }
        saveLog()
        NSLog("[ActivityTracker] 📔 Diary saved for \(date)")
    }

    func getSummary(for date: String) -> String? {
        log.days[date]?.summary
    }

    func saveSummary(_ text: String, for date: String) {
        if log.days[date] != nil {
            log.days[date]?.summary = text
        }
        if date == today.date {
            today.summary = text
        }
        saveLog()
        NSLog("[ActivityTracker] 📊 Summary saved for \(date)")
    }

    // MARK: - 人类可读总结

    func todaySummaryText() -> String {
        var lines: [String] = []

        // 按时长排序的 app 分类
        let sortedCategories = today.categoryDurations.sorted { $0.value > $1.value }
        for (category, seconds) in sortedCategories.prefix(5) {
            let label = categoryLabel(category)
            lines.append("- \(label): \(formatDuration(seconds))")
        }

        // Top apps
        let sortedApps = today.topApps.sorted { $0.value > $1.value }
        if !sortedApps.isEmpty {
            let appList = sortedApps.prefix(3).map { "\($0.key)(\(formatDuration($0.value)))" }.joined(separator: "、")
            lines.append("- 常用应用: \(appList)")
        }

        if today.pomodoroSessions > 0 {
            lines.append("- 番茄钟: 完成\(today.pomodoroSessions)轮")
        }
        lines.append("- 互动: 戳了\(today.pokeCount)次、喂食\(today.feedCount)次")

        if let first = today.firstActiveTime, let last = today.lastActiveTime {
            lines.append("- 活跃时间: \(first) ~ \(last)")
        }

        return lines.joined(separator: "\n")
    }

    func getActivity(for date: String) -> DailyActivity? {
        if date == today.date { return today }
        return log.days[date]
    }

    func recentDates(count: Int = 30) -> [String] {
        Array(log.days.keys.sorted().suffix(count))
    }

    // MARK: - 私有方法

    private func checkDayRollover(now: Date) {
        let todayStr = dateFormatter.string(from: now)
        if todayStr != today.date {
            // 保存昨天的数据
            log.days[today.date] = today
            // 开始新的一天
            today = log.days[todayStr] ?? DailyActivity(date: todayStr)
            // 清理超过 30 天的旧数据
            pruneOldDays()
            saveLog()
            NSLog("[ActivityTracker] 🌅 Day rolled over to \(todayStr)")
        }
    }

    private func pruneOldDays() {
        let sorted = log.days.keys.sorted()
        if sorted.count > 30 {
            for key in sorted.prefix(sorted.count - 30) {
                log.days.removeValue(forKey: key)
            }
        }
    }

    private func loadLog() {
        guard let data = try? Data(contentsOf: storageURL),
              let decoded = try? JSONDecoder().decode(ActivityLog.self, from: data) else {
            return
        }
        log = decoded
        NSLog("[ActivityTracker] Loaded \(log.days.count) days of activity")
    }

    private func saveLog() {
        log.days[today.date] = today
        guard let data = try? JSONEncoder().encode(log) else { return }
        try? data.write(to: storageURL, options: .atomic)
    }

    private func formatDuration(_ seconds: Int) -> String {
        if seconds < 60 { return "\(seconds)秒" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)分钟" }
        let hours = minutes / 60
        let remainMins = minutes % 60
        if remainMins == 0 { return "\(hours)小时" }
        return "\(hours)小时\(remainMins)分"  
    }

    private func categoryLabel(_ category: String) -> String {
        switch category {
        case "coding", "developing": return "写代码"
        case "watching_video": return "看视频"
        case "social": return "社交"
        case "chatting": return "聊天"
        case "reading_news": return "看新闻"
        case "shopping": return "购物"
        case "gaming": return "玩游戏"
        case "working": return "办公"
        case "email": return "邮件"
        case "designing": return "设计"
        case "writing": return "写作"
        case "ai_chat": return "AI 对话"
        case "studying": return "学习"
        case "browsing": return "浏览网页"
        default: return category
        }
    }
}
