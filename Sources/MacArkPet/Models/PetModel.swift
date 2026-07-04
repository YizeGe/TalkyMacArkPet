// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 MacArkPet contributors

import AppKit
import Combine

final class PetModel: ObservableObject {
    enum Mood {
        case idle
        case happy
        case resting
        case sleepy
        case special
        case attacking
        case victory
    }

    enum DayPhase: String, CaseIterable {
        case dawn = "dawn"      // 5-8
        case morning = "morning"  // 8-12
        case noon = "noon"      // 12-14
        case afternoon = "afternoon" // 14-18
        case evening = "evening"   // 18-21
        case night = "night"     // 21-0
        case lateNight = "lateNight" // 0-5

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

    @Published var mood: Mood = .idle
    @Published var isDragging = false
    @Published var isClickThrough = false
    @Published var isAlwaysOnTop = true
    @Published var facingLeft = false
    @Published var animationPhase: CGFloat = 0
    @Published var displayName = "MacArkPet"
    @Published var characterId: String = ""
    @Published var dialogueText: String = ""
    @Published var isSpeaking: Bool = false

    // 🖥️ 屏幕感知对话
    @Published var lastScreenContext: ScreenContext?
    @Published var lastDialogueSituation: String = ""
    @Published var imageURL: URL?
    @Published var atlasURL: URL?
    @Published var skeletonURL: URL?
    @Published var renderScale: CGFloat = 1.0
    @Published var renderScaleControlsWindow = false
    @Published var visualAspectRatio: CGFloat?
    @Published var visualCropRect: CGRect?
    @Published var visualCropKind: String?

    // 📍 停靠模式
    enum StayMode: String, CaseIterable {
        case sitHere = "sitHere"
        case lieHere = "lieHere"

        var displayName: String {
            switch self {
            case .sitHere: return "坐在这里"
            case .lieHere: return "躺在这里"
            }
        }
    }

    @Published var stayMode: StayMode? = nil

    func stayHere(mode: StayMode) {
        stayMode = mode
        switch mode {
        case .sitHere:
            mood = .resting
        case .lieHere:
            mood = .sleepy
        }
        velocity = .zero
    }

    func resumeWalking() {
        stayMode = nil
        velocity = CGVector(dx: 42, dy: 0)
        resumeWalkingAt = .distantPast
        nextMoodChange = Date().addingTimeInterval(TimeInterval.random(in: 6...12))
        mood = .idle
    }

    // 🐾 Companion stats
    @Published var affection: Int = 0     // 0-100, 提升解锁新台词
    @Published var stamina: Double = 100.0 // 0-100, 精力
    @Published var moodLevel: Double = 100.0 // 0-100, 心情
    @Published var coins: Int = 0         // 金币
    
    // CP 系统状态（不持久化，每次重启重置）
    var lastCPTrigger: [String: Date] = [:]
    @Published var lastInteractionDate: Date?
    @Published var dailyStreak: Int = 0   // 连续登录天数
    private let statsStore = PetStatsStore()

    // 🗺️ Desktop awareness
    @Published var dockProximity: CGFloat = 0  // 0=远离 dock, 1=在 dock 附近
    @Published var nearScreenEdge = false

    // 📱 App detection
    @Published var currentApp: String = ""
    @Published var currentAppCategory: String = ""
    private var lastAppNotified: String = ""

    // ⏱️ Screen time tracking
    private var continuousWorkTimer: TimeInterval = 0
    private var lastScreenTimeAlert: Date = Date()
    private var lastAppAlert: Date = Date.distantPast

    var velocity = CGVector(dx: 42, dy: 0)
    var nextMoodChange = Date().addingTimeInterval(8)
    var lastTick = Date()
    var lastDragEventAt = Date.distantPast
    var resumeWalkingAt = Date.distantPast
    private var lastPokeAt = Date.distantPast

    // 🎯 战斗相关
    var modelType: String = "Operator"   // "Operator" 或 "Enemy"
    var targetWindowFrame: CGRect?
    var combatWindowID: Int?
    var attackCooldownUntil = Date()
    var isInCombat = false
    private var visualCropRectsByKind: [String: CGRect] = [:]
    var lastStateSave = Date()

    static let statsDir: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MacArkPet", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    var hasSpineAssets: Bool {
        atlasURL != nil && skeletonURL != nil && imageURL != nil
    }

    func poke() {
        let now = Date()
        guard now.timeIntervalSince(lastPokeAt) > 0.9 else { return }
        lastPokeAt = now
        mood = .happy
        velocity = CGVector(dx: 0, dy: 0)
        nextMoodChange = Date().addingTimeInterval(5)

        // 🐾 Affection up!
        let bonus = checkDailyBonus()
        affection = min(100, affection + 2 + bonus)
        
        // 🐾 每点一次加 1 个金币
        coins += 1

        speak(kind: "interact")
    }

    private func checkDailyBonus() -> Int {
        let today = Calendar.current.startOfDay(for: Date())
        guard let last = lastInteractionDate else {
            lastInteractionDate = Date()
            dailyStreak = 1
            return 10  // 首次互动 10 倍好感
        }
        let lastDay = Calendar.current.startOfDay(for: last)
        let daysDiff = Calendar.current.dateComponents([.day], from: lastDay, to: today).day ?? 0

        if daysDiff >= 1 {
            dailyStreak += 1
            if daysDiff > 1 {
                // 断签重置
                dailyStreak = 1
            }
            lastInteractionDate = Date()
            return 5 + min(dailyStreak, 5)  // 连续签到 Bonus
        }
        return 0
    }

    func rest() {
        mood = .resting
        velocity = CGVector(dx: 0, dy: 0)
        nextMoodChange = Date().addingTimeInterval(10)
        speak(kind: "rest")
    }

    func specialAction() {
        mood = .special
        velocity = CGVector(dx: 0, dy: 0)
        nextMoodChange = Date().addingTimeInterval(22)
        speak(kind: "special")
    }

    @discardableResult
    func feed() -> Bool {
        guard coins >= 30 else {
            speak(text: "博士，金币不足呢 (需要30金币)")
            return false
        }
        coins -= 30
        stamina = min(100, stamina + 30)
        moodLevel = min(100, moodLevel + 20)
        affection = min(100, affection + 1)
        if mood == .sleepy {
            mood = .idle
            nextMoodChange = Date().addingTimeInterval(TimeInterval.random(in: 8...14))
        }
        mood = .happy
        velocity = CGVector(dx: 0, dy: 0)
        nextMoodChange = Date().addingTimeInterval(4)
        speak(kind: "feed")
        return true
    }

    var statusText: String {
        "\(displayName)\n❤️ 好感度: \(affection)/100\n⚡ 精力: \(Int(stamina))/100\n✨ 心情: \(Int(moodLevel))/100\n💰 金币: \(coins)"
    }

    func sleep() {
        mood = .sleepy
        velocity = CGVector(dx: 0, dy: 0)
        nextMoodChange = Date().addingTimeInterval(12)
        speak(kind: "sleep")
    }

    func finishOneShotAction(kind: String) {
        let shouldFinish = (kind == "interact" && mood == .happy)
            || (kind == "special" && mood == .special)
        guard shouldFinish else {
            return
        }

        velocity = CGVector(dx: 0, dy: 0)
        resumeWalkingAt = Date().addingTimeInterval(2.0)
        nextMoodChange = Date().addingTimeInterval(TimeInterval.random(in: 8...14))
        mood = .idle
    }

    func animationKind() -> String {
        switch mood {
        case .sleepy:
            return "sleep"
        case .resting:
            return "rest"
        case .special, .victory:
            return "special"
        case .attacking:
            return "attacking"
        case .happy:
            return "interact"
        case .idle:
            return abs(velocity.dx) > 4 ? "move" : "idle"
        }
    }

    func contactInset(forWindowSize size: CGSize) -> CGFloat {
        guard hasSpineAssets else { return 0 }

        switch animationKind() {
        case "rest":
            return min(max(size.height * 0.18, 14), 46)
        case "sleep":
            if size.width > size.height * 1.25 {
                return min(max(size.height * 0.035, 3), 12)
            }
            return min(max(size.height * 0.16, 12), 42)
        default:
            return min(max(size.height * 0.015, 2), 6)
        }
    }

    func toggleSleep() {
        mood = mood == .sleepy ? .idle : .sleepy
        if mood == .sleepy {
            velocity = CGVector(dx: 0, dy: 0)
        }
        nextMoodChange = Date().addingTimeInterval(mood == .sleepy ? 12 : 6)
    }

    func resetMotion() {
        stayMode = nil
        isDragging = false
        velocity = CGVector(dx: 42, dy: 0)
        resumeWalkingAt = .distantPast
        facingLeft = false
        mood = .idle
        nextMoodChange = Date().addingTimeInterval(TimeInterval.random(in: 10...18))
        isInCombat = false
        targetWindowFrame = nil
        combatWindowID = nil
    }

    // ⚔️ 进入攻击状态
    func startAttacking() {
        mood = .attacking
        velocity = CGVector(dx: 0, dy: 0)
        isInCombat = true
        speak(kind: "attack_start")
    }

    // ⚔️ 攻击命中
    func performAttack() -> Bool {
        let now = Date()
        guard now >= attackCooldownUntil else { return false }
        attackCooldownUntil = now.addingTimeInterval(1.2)
        mood = .attacking
        speak(kind: "attack_hit")
        return true
    }

    // 🏆 战斗胜利
    func declareVictory() {
        mood = .victory
        velocity = CGVector(dx: 0, dy: 0)
        isInCombat = false
        targetWindowFrame = nil
        combatWindowID = nil
        speak(kind: "attack_victory")
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
            self?.mood = .idle
            self?.velocity = CGVector(dx: 42, dy: 0)
        }
    }

    // ⚔️ 战斗败退
    func declareDefeat() {
        mood = .idle
        velocity = CGVector(dx: -42, dy: 0)
        isInCombat = false
        targetWindowFrame = nil
        combatWindowID = nil
        speak(kind: "attack_defeat")
    }

    func speak(text: String) {
        guard !characterId.isEmpty else { return }

        Task { @MainActor in
            self.dialogueText = text
            self.isSpeaking = true

            // 自动关闭对话框 (字数相关延迟)
            let delay = min(6.0, max(2.5, Double(text.count) * 0.15))
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.isSpeaking = false
                self?.dialogueText = ""
            }
        }
    }

    func speak(kind: String) {
        guard !characterId.isEmpty else { return }
        guard CharacterVoiceService.isEnabled else { return }
        if let allowed = CharacterVoiceService.enabledCharacters, !allowed.contains(characterId) { return }

        let affectionKind = affection >= 60 ? "affection_" + kind : kind

        Task { @MainActor in
            NSLog("[PetModel.speak] characterId=\(self.characterId) displayName=\(self.displayName) kind=\(kind) affectionKind=\(affectionKind)")

            // 1. 优先使用 DialogueEngine (用户自定义/AI生成的 Dialogues.json 数据)
            var line = DialogueEngine.shared.line(for: self.characterId, displayName: self.displayName, moodKind: affectionKind, affection: self.affection)
            var source = "DialogueEngine(affection)"
            if line == nil {
                line = DialogueEngine.shared.line(for: self.characterId, displayName: self.displayName, moodKind: kind, affection: self.affection)
                source = "DialogueEngine(normal)"
            }

            // 2. 降级使用 CharacterVoiceService (CharacterVoiceLines.json)
            if line == nil {
                line = CharacterVoiceService.shared.line(for: self.characterId, moodKind: affectionKind)
                source = "CharacterVoiceService(affection)"
            }
            if line == nil {
                line = CharacterVoiceService.shared.line(for: self.characterId, moodKind: kind)
                source = "CharacterVoiceService(normal)"
            }

            if let line {
                NSLog("[PetModel.speak] ✅ source=\(source) line=\(line.prefix(40))...")
            } else {
                NSLog("[PetModel.speak] ❌ No line found for \(self.characterId)/\(self.displayName) kind=\(kind)")
            }

            self.dialogueText = line ?? ""
            guard let validLine = line else { return }
            self.isSpeaking = true
            
            // 根据字数动态计算显示时间（每字0.15秒，最少3秒，最多7秒）
            let duration = min(max(3.0, Double(validLine.count) * 0.15), 7.0)
            
            DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
                self?.isSpeaking = false
            }
        }
    }

    // MARK: - 🖥️ 屏幕感知对话（新引擎）

    /// 由 ScreenWatcherService 调用，通过 DialogueEngine 获取情境台词
    @MainActor
    func speakForScreenContext(_ context: ScreenContext) {
        guard !characterId.isEmpty else { return }
        guard CharacterVoiceService.isEnabled else { return }
        if let allowed = CharacterVoiceService.enabledCharacters, !allowed.contains(characterId) { return }

        // 防止频繁触发
        let now = Date()
        if context == lastScreenContext,
           now.timeIntervalSince(lastScreenContextChange) < 25 {
            return
        }
        lastScreenContext = context
        lastScreenContextChange = now
        currentAppCategory = context.category

        let situation = DialogueEngine.situation(from: context)
        lastDialogueSituation = situation.rawValue

        let line = DialogueEngine.shared.line(
            for: characterId,
            displayName: displayName,
            situation: situation,
            affection: affection,
            context: context
        )

        guard let dialogue = line else { return }
        dialogueText = dialogue
        isSpeaking = true

        // 根据台词长度动态决定显示时长
        let duration = max(6.0, min(10.0, Double(dialogue.count) / 8.0))
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
            self?.isSpeaking = false
        }
    }

    private var lastScreenContextChange = Date.distantPast

    /// 重置屏幕上下文（当宠物被关闭或重置时）
    func resetScreenContext() {
        lastScreenContext = nil
        lastScreenContextChange = Date.distantPast
        lastDialogueSituation = ""
    }

    // ⏰ 每日健康检查（每 tick 执行）
    @MainActor
    func tickPet(petMinX: CGFloat, petMaxX: CGFloat, screenWidth: CGFloat) {
        let now = Date()
        
        // 交给 CompanionEngine 处理精力/心情/金币的动态变化
        CompanionEngine.shared.tick(model: self, now: now)

        // 桌面感知：检测是否停靠在屏幕边缘
        nearScreenEdge = petMinX <= 10 || petMaxX >= screenWidth - 10

        // ⏱️ 长时间屏幕使用提醒（约每30分钟提醒一次）
        if mood != .sleepy && mood != .resting {
            continuousWorkTimer += 1
            if continuousWorkTimer >= 300 {  // 300 ticks * ~6s ≈ 30min
                continuousWorkTimer = 0
                if now.timeIntervalSince(lastScreenTimeAlert) > 1200 {
                    lastScreenTimeAlert = now
                    speak(kind: "long_screen_time")
                }
            }
        } else {
            continuousWorkTimer = 0
        }
    }

    // 📱 由外部（MacArkPetApp）调用，当检测到前台 App 切换时
    func onAppChanged(appName: String, category: String) {
        guard !characterId.isEmpty else { return }
        let now = Date()
        if now.timeIntervalSince(lastAppAlert) < 30 { return }
        lastAppAlert = now

        let kind: String
        switch category {
        case "game":
            kind = "app_game"
        case "work", "productivity", "office":
            kind = "app_work"
        case "social", "chat", "messaging":
            kind = "app_social"
        case "coding", "development", "ide", "terminal":
            kind = "app_coding"
        default:
            return
        }

        let affectionKind = affection >= 60 ? "affection_" + kind : kind

        Task { @MainActor in
            var line = DialogueEngine.shared.line(for: self.characterId, displayName: self.displayName, moodKind: affectionKind, affection: self.affection)
            if line == nil {
                line = DialogueEngine.shared.line(for: self.characterId, displayName: self.displayName, moodKind: kind, affection: self.affection)
            }
            if line == nil {
                line = CharacterVoiceService.shared.line(for: self.characterId, moodKind: affectionKind)
            }
            if line == nil {
                line = CharacterVoiceService.shared.line(for: self.characterId, moodKind: kind)
            }

            if let line {
                self.speak(text: line)
            }
        }
    }

    func apply(model: ArkModelItem) {
        displayName = model.title
        characterId = model.voiceCharacterID
        modelType = (model.type == "Enemy" || model.tags.contains(where: { $0.hasPrefix("Enemy") })) ? "Enemy" : "Operator"
        imageURL = model.imageURL
        atlasURL = model.atlasURL
        skeletonURL = model.skeletonURL
        renderScaleControlsWindow = false
        visualAspectRatio = nil
        isSpeaking = false
        dialogueText = ""
        resetVisualCrop()
        resetMotion()

        // 🐾 加载该角色的持久化数据
        loadStats()

        // 🌐 向 aichach 上报当前桌宠角色
        PetReporter.shared.report(characterId: characterId, characterName: displayName)
    }

    // 保存当前角色数据到磁盘
    func saveStats() {
        statsStore.save(
            for: characterId,
            affection: affection,
            stamina: stamina,
            moodLevel: moodLevel,
            coins: coins,
            dailyStreak: dailyStreak,
            lastInteractionDate: lastInteractionDate,
            lastStateUpdate: Date()
        )
    }

    // 从磁盘加载当前角色的数据
    private func loadStats() {
        guard !characterId.isEmpty else { return }
        let data = statsStore.load(for: characterId)
        affection = data.affection
        stamina = data.stamina
        moodLevel = data.moodLevel
        coins = data.coins
        dailyStreak = data.dailyStreak
        lastInteractionDate = data.lastInteractionDate

        // 让 CompanionEngine 处理离线收益/消耗
        CompanionEngine.shared.processOfflineTime(model: self, lastUpdate: data.lastStateUpdate)
    }

    var activeVisualCropRect: CGRect? {
        guard hasSpineAssets else { return nil }
        let kind = animationKind()
        if isStandingKind(kind) {
            return standingVisualCropRect
        }
        if let crop = visualCropRectsByKind[kind] {
            if isOneShotKind(kind), let standingCrop = standingVisualCropRect {
                return crop.union(standingCrop)
            }
            return crop
        }
        return standingVisualCropRect
    }

    var activeVisualAnchorX: CGFloat? {
        guard hasSpineAssets,
              let activeCrop = activeVisualCropRect else {
            return nil
        }

        let anchorCrop = standingVisualCropRect ?? activeCrop
        let anchorX = anchorCrop.midX - activeCrop.minX
        return min(max(anchorX, 0), activeCrop.width)
    }

    func setVisualCrop(kind: String, rect: CGRect) {
        let safeRect = safeVisualCropRect(rect, kind: kind)
        let stableRect = visualCropRectsByKind[kind]?.union(safeRect) ?? safeRect
        visualCropRectsByKind[kind] = stableRect
        visualCropKind = kind
        visualCropRect = stableRect
    }

    func resetVisualCrop() {
        visualCropRectsByKind.removeAll()
        visualCropRect = nil
        visualCropKind = nil
    }

    private var standingVisualCropRect: CGRect? {
        let standingRects = ["move", "idle"].compactMap { visualCropRectsByKind[$0] }
        return union(standingRects)
    }

    private func isStandingKind(_ kind: String) -> Bool {
        kind == "move" || kind == "idle"
    }

    private func isOneShotKind(_ kind: String) -> Bool {
        kind == "interact" || kind == "special"
    }

    private func union(_ rects: [CGRect]) -> CGRect? {
        guard var result = rects.first else { return nil }
        for rect in rects.dropFirst() {
            result = result.union(rect)
        }
        return result
    }

    private func safeVisualCropRect(_ rect: CGRect, kind: String) -> CGRect {
        let topPadding: CGFloat
        let sidePadding: CGFloat
        let bottomPadding: CGFloat

        switch kind {
        case "move", "idle":
            topPadding = max(18, rect.height * 0.08)
            sidePadding = max(8, rect.width * 0.025)
            bottomPadding = max(3, rect.height * 0.015)
        case "rest", "sleep":
            topPadding = max(12, rect.height * 0.045)
            sidePadding = max(10, rect.width * 0.025)
            bottomPadding = max(3, rect.height * 0.015)
        default:
            topPadding = max(14, rect.height * 0.06)
            sidePadding = max(8, rect.width * 0.025)
            bottomPadding = max(3, rect.height * 0.015)
        }

        let left = max(0, rect.minX - sidePadding)
        let top = max(0, rect.minY - topPadding)
        let right = rect.maxX + sidePadding
        let bottom = rect.maxY + bottomPadding
        return CGRect(
            x: left.rounded(.down),
            y: top.rounded(.down),
            width: max(1, (right - left).rounded(.up)),
            height: max(1, (bottom - top).rounded(.up))
        )
    }
}

// MARK: - 🐾 好感度 / 状态持久化

private struct PetStatsData: Codable {
    var affection: Int = 0
    var stamina: Double = 100.0
    var moodLevel: Double = 100.0
    var coins: Int = 0
    var dailyStreak: Int = 0
    var lastInteractionDate: Date?
    var lastStateUpdate: Date = Date()
    
    // 兼容旧存档
    var energy: Int?
    var lastEnergyDrain: Date?
}

private final class PetStatsStore {
    private var cache: [String: PetStatsData] = [:]

    private var storageURL: URL {
        PetModel.statsDir.appendingPathComponent("pet_stats.json")
    }

    func load(for characterId: String) -> PetStatsData {
        if let cached = cache[characterId] { return cached }
        guard let data = try? Data(contentsOf: storageURL),
              let all = try? JSONDecoder().decode([String: PetStatsData].self, from: data),
              var stats = all[characterId] else {
            return PetStatsData()
        }
        // 兼容旧存档
        if let oldEnergy = stats.energy {
            stats.stamina = Double(oldEnergy)
            stats.energy = nil
        }
        if let oldDrain = stats.lastEnergyDrain {
            stats.lastStateUpdate = oldDrain
            stats.lastEnergyDrain = nil
        }
        cache[characterId] = stats
        return stats
    }

    func save(for characterId: String, affection: Int, stamina: Double, moodLevel: Double, coins: Int, dailyStreak: Int,
              lastInteractionDate: Date?, lastStateUpdate: Date) {
        var all: [String: PetStatsData] = [:]
        // Load existing file to merge
        if let data = try? Data(contentsOf: storageURL),
           let existing = try? JSONDecoder().decode([String: PetStatsData].self, from: data) {
            all = existing
        }
        all[characterId] = PetStatsData(
            affection: affection,
            stamina: stamina,
            moodLevel: moodLevel,
            coins: coins,
            dailyStreak: dailyStreak,
            lastInteractionDate: lastInteractionDate,
            lastStateUpdate: lastStateUpdate
        )
        cache[characterId] = all[characterId]
        if let encoded = try? JSONEncoder().encode(all) {
            try? encoded.write(to: storageURL, options: .atomic)
        }
    }
}
