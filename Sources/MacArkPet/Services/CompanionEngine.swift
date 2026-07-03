// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 MacArkPet contributors

import Foundation
import AppKit

struct ConversationStep {
    let speakerId: String
    let text: String
}

class ConversationSession {
    let steps: [ConversationStep]
    var currentIdx: Int = 0
    var nextTime: Date
    let initiatorId: String
    let otherId: String
    
    init(script: String, initiatorId: String, otherId: String, now: Date) {
        self.initiatorId = initiatorId
        self.otherId = otherId
        self.nextTime = now
        var parsed: [ConversationStep] = []
        let parts = script.components(separatedBy: "|")
        for part in parts {
            let p = part.trimmingCharacters(in: .whitespacesAndNewlines)
            if p.isEmpty { continue }
            if let colonIdx = p.firstIndex(of: ":") {
                let speaker = String(p[..<colonIdx]).trimmingCharacters(in: .whitespacesAndNewlines)
                let text = String(p[p.index(after: colonIdx)...]).trimmingCharacters(in: .whitespacesAndNewlines)
                let lower = speaker.lowercased()
                if lower == "self" || lower == "我" || lower == "我方" {
                    parsed.append(ConversationStep(speakerId: initiatorId, text: text))
                } else if lower == "other" || lower == "对方" || lower == "ta" {
                    parsed.append(ConversationStep(speakerId: otherId, text: text))
                } else {
                    parsed.append(ConversationStep(speakerId: speaker, text: text))
                }
            } else {
                parsed.append(ConversationStep(speakerId: initiatorId, text: p))
            }
        }
        self.steps = parsed
    }
}

/// CompanionEngine 负责管理“桌面伴侣”的核心逻辑
/// 包括：精力(stamina)、心情(moodLevel)、金币(coins)的自然流失与挂机收益、CP互动
final class CompanionEngine {
    static let shared = CompanionEngine()

    private var activeConversations: [ConversationSession] = []
    private var lastConversationUpdate: Date = Date()
    private var lastCPCheck: Date = Date()

    private init() {}

    // 每次 tick（大约每秒或每隔几秒）调用
    @MainActor
    func tick(model: PetModel, now: Date) {
        // 1. 每 60 秒结算一次精力与心情
        if now.timeIntervalSince(model.lastStateSave) > 60 {
            processMinuteUpdate(model: model, now: now)
        }
        
        // 2. CP 探测 (每 10 秒探测一次)
        if now.timeIntervalSince(lastCPCheck) > 10 {
            lastCPCheck = now
            processCPDetection(now: now)
        }
        
        // 3. 处理正在进行的对话 (限制每秒最多更新一次)
        if now.timeIntervalSince(lastConversationUpdate) > 1.0 {
            lastConversationUpdate = now
            processActiveConversations(now: now)
        }
    }

    private func processMinuteUpdate(model: PetModel, now: Date) {
        let isWorking = isProductiveApp(category: model.currentAppCategory)
        let isHangingOut = model.nearScreenEdge // 是否挂在屏幕边缘

        // 1. 精力流失/恢复逻辑
        if isWorking && isHangingOut {
            // 工作且陪伴状态下，精力不减反增（或者保持）
            model.stamina = min(100.0, model.stamina + 0.5)
            // 产出金币
            model.coins += 1
        } else if model.mood == .resting {
            model.stamina = min(100.0, model.stamina + 1.0)
        } else if model.mood == .sleepy {
            model.stamina = min(100.0, model.stamina + 2.0)
        } else {
            // 普通待机，缓慢消耗精力
            model.stamina = max(0.0, model.stamina - 1.0)
        }

        // 2. 心情自然流失
        if model.mood != .happy {
            model.moodLevel = max(0.0, model.moodLevel - 0.5)
        }

        // 3. 状态联动 (低精力自动休眠)
        if model.stamina <= 15 && model.mood == .idle {
            model.mood = .sleepy
            model.velocity = CGVector(dx: 0, dy: 0)
            model.nextMoodChange = now.addingTimeInterval(8)
            model.speak(kind: "low_battery") // 或者配置新的 low_stamina 台词
        } else if model.stamina >= 40 && model.mood == .sleepy && model.nextMoodChange < now {
            model.mood = .idle
            model.nextMoodChange = now.addingTimeInterval(TimeInterval.random(in: 8...14))
        }

        // 保存状态
        model.lastStateSave = now
        model.saveStats()
    }

    // 处理离线时间，例如过了几个小时没开，掉一点精力和心情
    func processOfflineTime(model: PetModel, lastUpdate: Date) {
        let minutesPassed = -lastUpdate.timeIntervalSinceNow / 60
        guard minutesPassed > 0 else { return }

        // 每离线 1 小时掉 5 点精力，10 点心情
        let hoursPassed = minutesPassed / 60
        let staminaDrain = min(50.0, hoursPassed * 5.0)
        let moodDrain = min(80.0, hoursPassed * 10.0)

        model.stamina = max(0.0, model.stamina - staminaDrain)
        model.moodLevel = max(0.0, model.moodLevel - moodDrain)

        if model.stamina <= 0 {
            model.stamina = 0
            if model.mood == .idle {
                model.mood = .sleepy
            }
        }
    }

    private func isProductiveApp(category: String) -> Bool {
        return ["work", "productivity", "office", "coding", "development", "ide", "terminal"].contains(category)
    }

    // MARK: - CP System (多轮对话)

    @MainActor
    private func processCPDetection(now: Date) {
        let activePets = MacArkPetApp.shared.petControllers.map { $0.model }
        if activePets.count < 2 { return }

        // 遍历所有角色，寻找匹配的 CP 台词
        for model in activePets {
            for other in activePets where other !== model {
                // 检查是否在 1 分钟 CD 内
                if let last = model.lastCPTrigger[other.characterId], now.timeIntervalSince(last) < 60 {
                    continue
                }

                // 尝试多种 CP situation key：cp_{characterId} 和 cp_{displayName}
                // 用户在 Web 编辑器中可能用显示名（如 cp_海沫）或内部ID（如 cp_4066_highmo）
                let cpKeys = Array(Set([
                    "cp_\(other.characterId)",
                    "cp_\(other.displayName)"
                ]))

                var foundScript: String? = nil
                for cpSituation in cpKeys {
                    if let script = DialogueEngine.shared.line(for: model.characterId, displayName: model.displayName, moodKind: cpSituation, affection: model.affection) {
                        foundScript = script
                        break
                    }
                }

                if let script = foundScript {
                    model.lastCPTrigger[other.characterId] = now
                    let session = ConversationSession(script: script, initiatorId: model.characterId, otherId: other.characterId, now: now)
                    activeConversations.append(session)
                    return // 每次全局检测最多发起一段对话，避免刷屏
                }
            }
        }
    }

    @MainActor
    private func processActiveConversations(now: Date) {
        var completedIndices: [Int] = []

        for (i, session) in activeConversations.enumerated() {
            if now >= session.nextTime {
                let step = session.steps[session.currentIdx]
                // 找到说话人
                if let speakerCtrl = MacArkPetApp.shared.petControllers.first(where: { $0.model.characterId == step.speakerId }) {
                    speakerCtrl.model.speak(text: step.text)
                }

                session.currentIdx += 1
                if session.currentIdx >= session.steps.count {
                    completedIndices.append(i)
                } else {
                    // 计算下一句的延迟：基础 2 秒 + 每字符 0.15 秒
                    let delay = 2.0 + Double(step.text.count) * 0.15
                    session.nextTime = now.addingTimeInterval(delay)
                }
            }
        }

        // 移除结束的对话
        for idx in completedIndices.reversed() {
            activeConversations.remove(at: idx)
        }
    }
}
