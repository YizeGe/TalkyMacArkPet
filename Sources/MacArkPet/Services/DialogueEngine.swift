// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 MacArkPet contributors

import AppKit
import Combine

// MARK: - 对话情境

/// 由 ScreenContext + 角色状态综合决定的情境
enum DialogueSituation: String, CaseIterable, Codable {
    // ---- 屏幕内容感知 ----
    case coding           // 编码/开发
    case developing       // IDE/编辑器
    case watching_video   // 看视频
    case social           // 社交平台
    case chatting         // 聊天工具
    case reading_news     // 读新闻
    case shopping         // 购物
    case gaming           // 玩游戏
    case working          // 办公/生产力
    case email            // 看邮件
    case designing        // 设计/画图
    case writing          // 写作
    case ai_chat          // 和 AI 对话
    case studying         // 学习/研究
    case browsing         // 一般浏览
    case devops           // 运维/部署

    // ---- 行为感知 ----
    case deep_night       // 深夜
    case idle_long        // 久坐/长时间不动
    case work_overload    // 连续工作过久
    case app_switching    // 频繁切换应用

    // ---- 互动 ----
    case interact
    case rest
    case sleep
    case special
    case feed
    case low_battery
    case long_screen_time

    // ---- 每日/首次 ----
    case daily

    // ---- 🍅 番茄钟 ----
    case pomodoro_start       // 开始专注
    case pomodoro_halfway     // 专注过半鼓励
    case pomodoro_break       // 休息时间
    case pomodoro_resume      // 休息结束继续
    case pomodoro_complete    // 完成一轮

    // ---- 💕 好感度里程碑 ----
    case affection_milestone_25
    case affection_milestone_50
    case affection_milestone_75
    case affection_milestone_100

    // ---- 🎄 节日/生日 ----
    case birthday             // 角色生日
    case holiday_new_year
    case holiday_spring_festival
    case holiday_lantern_festival
    case holiday_valentines
    case holiday_labor_day
    case holiday_dragon_boat
    case holiday_mid_autumn
    case holiday_national_day
    case holiday_christmas

    // ---- 📊 每日总结/日记 ----
    case daily_summary
    case daily_diary

    // ---- 带好感度前缀 ----
    var affectionVariants: [DialogueSituation] {
        switch self {
        case .interact, .rest, .sleep, .special, .feed, .low_battery:
            return [self]
        case .coding, .watching_video, .social, .chatting, .gaming, .working:
            return [self]
        default:
            return [self]
        }
    }
}

// MARK: - 台词条目

struct DialogueEntry: Codable {
    /// 触发情境 (JSON 中可能没有，因为它是作为 Dictionary 的 Key)
    let situation: String?
    /// 台词列表
    let lines: [String]
    /// 好感度门槛（0 = 通用）
    let minAffection: Int?
    /// 触发后冷却时间（秒）
    let cooldown: Int?
}

// MARK: - 角色台词语料库

struct CharacterDialogueSet: Codable {
    let characterID: String
    let name: String
    /// 按情境分组的台词
    let entries: [DialogueEntry]
}

// MARK: - 对话引擎

@MainActor
final class DialogueEngine {
    static let shared = DialogueEngine()

    // MARK: - 运行时状态

    private var dialogueDB: [String: [String: [DialogueEntry]]] = [:] // characterID → [situation → [entries]]
    private var cooldowns: [String: [String: Date]] = [:]  // characterID → [situation → cooldown until]
    private var recentJokes: [String: [String: Set<String>]] = [:] // characterID → [situation → said lines]

    private var profileDB: [String: CharacterProfile] = [:]
    private var screenSub: AnyCancellable?

    private init() {}

    // MARK: - 加载

    func load() {
        dialogueDB.removeAll()
        recentJokes.removeAll()

        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let userURL = appSupport.appendingPathComponent("MacArkPet/Dialogues.json")

        // 优先从 Application Support 加载用户的自定义修改，如果不存在再退回 Bundle/Resources
        let candidateURLs: [URL] = [
            userURL,
            Bundle.main.resourceURL?.appendingPathComponent("Dialogues.json"),
            URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Resources/Dialogues.json")
        ].compactMap { $0 }

        for url in candidateURLs {
            guard FileManager.default.fileExists(atPath: url.path),
                  let data = try? Data(contentsOf: url),
                  let db = try? JSONDecoder().decode([String: [String: [DialogueEntry]]].self, from: data) else {
                continue
            }
            dialogueDB = db
            NSLog("[DialogueEngine] Loaded \(db.count) character dialogue sets")
            return
        }

        NSLog("[DialogueEngine] No dialogue data found")
        dialogueDB = [:]
    }

    func loadProfiles() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let userURL = appSupport.appendingPathComponent("MacArkPet/CharacterProfiles.json")

        let candidateURLs: [URL] = [
            userURL,
            Bundle.main.resourceURL?.appendingPathComponent("CharacterProfiles.json"),
            URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Resources/CharacterProfiles.json")
        ].compactMap { $0 }

        for url in candidateURLs {
            guard FileManager.default.fileExists(atPath: url.path),
                  let data = try? Data(contentsOf: url),
                  let db = try? JSONDecoder().decode([String: CharacterProfile].self, from: data) else {
                continue
            }
            profileDB = db
            NSLog("[DialogueEngine] Loaded \(db.count) character profiles")
            return
        }
    }

    // MARK: - 核心 API

    /// 为指定角色获取匹配情境的台词
    func line(
        for characterID: String,
        displayName: String? = nil,
        situation: DialogueSituation,
        affection: Int = 0,
        context: ScreenContext? = nil
    ) -> String? {
        guard let charDB = dialogueDB[characterID] ?? (displayName != nil ? dialogueDB[displayName!] : nil) ?? closestMatch(for: characterID, displayName: displayName) else {
            return nil
        }

        let situationKey = situation.rawValue

        // 构建候选列表：先精确匹配，再通用匹配
        var candidates: [DialogueEntry] = []

        // 精确情境
        if let entries = charDB[situationKey] {
            candidates.append(contentsOf: entries)
        }

        // 如果是 deep_night / idle_long，也可以匹配通用触发
        if situation == .deep_night, let generic = charDB["deep_night"] {
            candidates.append(contentsOf: generic)
        }
        if situation == .idle_long, let generic = charDB["idle_long"] {
            candidates.append(contentsOf: generic)
        }
        if situation == .long_screen_time, let generic = charDB["long_screen_time"] {
            candidates.append(contentsOf: generic)
        }

        guard !candidates.isEmpty else { return nil }

        // 按好感度门槛过滤
        let eligible = candidates.filter { ($0.minAffection ?? 0) <= affection }

        // 检查冷却
        let now = Date()
        let available = eligible.filter { entry in
            guard let cooldownUntil = cooldowns[characterID]?[situationKey] else { return true }
            return now >= cooldownUntil
        }

        guard !available.isEmpty else { return nil }

        // 避免重复
        let noRepeat = available.filter { entry in
            guard let said = recentJokes[characterID]?[situationKey] else { return true }
            return !said.isSuperset(of: Set(entry.lines))
        }

        let pool = noRepeat.isEmpty ? available : noRepeat

        // 选一条
        guard let chosen = pool.randomElement(),
              let line = chosen.lines.randomElement() else {
            return nil
        }

        // 更新冷却
        if cooldowns[characterID] == nil { cooldowns[characterID] = [:] }
        cooldowns[characterID]?[situationKey] = now.addingTimeInterval(TimeInterval(chosen.cooldown ?? 60))

        // 记录已说过的台词
        if recentJokes[characterID] == nil { recentJokes[characterID] = [:] }
        if recentJokes[characterID]?[situationKey] == nil {
            recentJokes[characterID]?[situationKey] = []
        }
        recentJokes[characterID]?[situationKey]?.insert(line)
        if (recentJokes[characterID]?[situationKey]?.count ?? 0) > 20 {
            recentJokes[characterID]?[situationKey]?.removeAll()
        }

        return line
    }

    /// 根据情境/动作名称直接查询台词 (用于与 Dialogues.json 同步)
    func line(for characterID: String, displayName: String? = nil, moodKind: String, affection: Int = 0) -> String? {
        NSLog("[DialogueEngine.line] characterID=\(characterID) displayName=\(displayName ?? "nil") moodKind=\(moodKind) dbKeys=\(Array(dialogueDB.keys))")

        guard let charDB = dialogueDB[characterID] ?? (displayName != nil ? dialogueDB[displayName!] : nil) ?? closestMatch(for: characterID, displayName: displayName) else {
            NSLog("[DialogueEngine.line] ❌ No charDB match for \(characterID)/\(displayName ?? "nil")")
            return nil
        }
        NSLog("[DialogueEngine.line] ✅ Found charDB, keys=\(Array(charDB.keys))")
        guard let entries = charDB[moodKind], !entries.isEmpty else {
            NSLog("[DialogueEngine.line] ❌ No entries for moodKind=\(moodKind)")
            return nil
        }
        let eligible = entries.filter { ($0.minAffection ?? 0) <= affection }
        let pool = eligible.isEmpty ? entries : eligible
        guard let chosen = pool.randomElement(),
              let line = chosen.lines.randomElement() else {
            return nil
        }
        NSLog("[DialogueEngine.line] ✅ Picked line: \(line.prefix(40))...")
        return line
    }

    /// 从 ScreenContext 映射到 DialogueSituation
    static func situation(from context: ScreenContext) -> DialogueSituation {
        // 优先级：时间/状态 > 活动
        if context.isDeepNight { return .deep_night }
        if context.isIdleLong { return .idle_long }

        switch context.category {
        case "coding", "developing": return .coding
        case "watching_video":       return .watching_video
        case "social":               return .social
        case "chatting":             return .chatting
        case "reading_news":         return .reading_news
        case "shopping":             return .shopping
        case "gaming":               return .gaming
        case "working":              return .working
        case "email":                return .email
        case "designing":            return .designing
        case "writing":              return .writing
        case "ai_chat":              return .ai_chat
        case "studying":             return .studying
        case "browsing":             return .browsing
        default:                     return .browsing
        }
    }

    static func situationFromAppCategory(_ category: String) -> DialogueSituation {
        switch category {
        case "coding":  return .coding
        case "game":    return .gaming
        case "work":    return .working
        case "social":  return .social
        default:        return .browsing
        }
    }

    // MARK: - 角色设定查询

    func profile(for characterID: String) -> CharacterProfile? {
        profileDB[characterID] ?? profileDB.values.first { $0.matches(id: characterID) }
    }

    // MARK: - 帮助方法

    private func closestMatch(for characterID: String, displayName: String? = nil) -> [String: [DialogueEntry]]? {
        // 精确匹配
        if let exact = dialogueDB[characterID] { return exact }

        // 尝试匹配 displayName (如 "阿米娅")
        if let name = displayName, !name.isEmpty, let match = dialogueDB[name] {
            return match
        }

        // 前缀匹配（处理皮肤变体，如 "002_amiya_winter" -> "002_amiya"）
        let parts = characterID.split(separator: "_")
        for end in stride(from: parts.count, through: 1, by: -1) {
            let prefix = parts[0..<end].joined(separator: "_")
            if let match = dialogueDB[prefix] {
                return match
            }
        }

        // ID 包含匹配
        let lower = characterID.lowercased()
        for (key, value) in dialogueDB where key.contains(lower) || lower.contains(key) {
            return value
        }

        // 尝试通过 profileDB 关联查找 name/subtitle/id
        if let prof = profileDB[characterID] ?? profileDB.values.first(where: { $0.matches(id: characterID) }) {
            if let match = dialogueDB[prof.id] ?? dialogueDB[prof.name] ?? dialogueDB[prof.subtitle] {
                return match
            }
        }

        return nil
    }
}

// MARK: - 角色详细设定

struct CharacterProfile: Codable {
    let id: String
    let name: String
    let subtitle: String

    // 基础信息
    let race: String
    let origin: String
    let birthday: String
    let height: String
    let classLabel: String
    let faction: String
    let infected: Bool

    // 性格
    let personality: String              // 性格摘要
    let speechStyle: String              // 语言风格
    let attitudeTowardsDoctor: String    // 对博士态度

    // 屏幕互动相关
    let screenAttitude: ScreenAttitude

    // 背景
    let backgroundSummary: String
    let signatureLines: [String]         // 经典语录

    struct ScreenAttitude: Codable {
        let coding: String
        let gaming: String
        let social: String
        let video: String
        let lateNight: String
        let idleLong: String
        let readingNews: String
        let shopping: String
        let aiChat: String
    }

    func matches(id characterID: String) -> Bool {
        let lower = characterID.lowercased()
        return self.id == characterID || id.contains(lower) || lower.contains(id)
    }
}
