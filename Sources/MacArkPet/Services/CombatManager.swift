// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 MacArkPet contributors

import AppKit

/// 战斗管理器：管理干员和敌人的配对、接近、攻击、震动
final class CombatManager {
    static let shared = CombatManager()

    // MARK: - 战斗单元

    struct Combatant {
        let type: CombatantType
        weak var window: PetWindow?
        weak var model: PetModel?
        let combatID: String

        var windowFrame: CGRect? {
            window?.frame
        }
    }

    enum CombatantType {
        case `operator`
        case enemy
    }

    enum CombatState {
        case idle            // 未配对
        case patrolling      // 巡逻中
        case alerted         // 发现敌人
        case approaching     // 正在接近
        case attacking       // 正在攻击
        case victory         // 胜利
        case defeat          // 败退
    }

    struct CombatPair {
        let id: String
        let operatorCombatID: String
        let enemyCombatID: String
        var state: CombatState = .idle
        var attackTimer = 0
        var approachedAt = Date.distantPast
        var shakeCount = 0
    }

    // MARK: - 状态

    private var operators: [Combatant] = []
    private var enemies: [Combatant] = []
    private var pairs: [CombatPair] = []
    private var tickTimer: DispatchSourceTimer?
    private var isRunning = false

    private init() {}

    // MARK: - 注册

    func registerOperator(window: PetWindow, model: PetModel) {
        let cid = "op_\(model.characterId)_\(operators.count)"
        let combatant = Combatant(type: .operator, window: window, model: model, combatID: cid)
        operators.append(combatant)
        model.combatWindowID = cid.hashValue
        NSLog("[⚔️Combat] 注册干员: \(model.displayName) (\(cid)) | 干员数: \(operators.count) 敌人数: \(enemies.count)")
        tryAutoPair()
    }

    func registerEnemy(window: PetWindow, model: PetModel) {
        let cid = "enemy_\(model.characterId)_\(enemies.count)"
        let combatant = Combatant(type: .enemy, window: window, model: model, combatID: cid)
        enemies.append(combatant)
        model.combatWindowID = cid.hashValue
        NSLog("[⚔️Combat] 注册敌人: \(model.displayName) (\(cid)) | 干员数: \(operators.count) 敌人数: \(enemies.count)")
        tryAutoPair()
    }

    func unregister(combatID: String) {
        operators.removeAll { $0.combatID == combatID }
        enemies.removeAll { $0.combatID == combatID }
        pairs.removeAll { $0.operatorCombatID == combatID || $0.enemyCombatID == combatID }
        if pairs.isEmpty { stop() }
    }

    func unregister(model: PetModel) {
        operators.removeAll { $0.model === model || $0.window == nil || $0.model == nil }
        enemies.removeAll { $0.model === model || $0.window == nil || $0.model == nil }
        pairs.removeAll { pair in
            operators.allSatisfy { $0.combatID != pair.operatorCombatID }
            || enemies.allSatisfy { $0.combatID != pair.enemyCombatID }
        }
        if pairs.isEmpty { stop() }
    }

    func unregisterAll() {
        operators.removeAll()
        enemies.removeAll()
        pairs.removeAll()
        stop()
    }

    /// 清理已释放的窗口引用
    func cleanUpStale() {
        operators.removeAll { $0.window == nil || $0.model == nil }
        enemies.removeAll { $0.window == nil || $0.model == nil }
        pairs.removeAll { pair in
            operators.allSatisfy { $0.combatID != pair.operatorCombatID }
            || enemies.allSatisfy { $0.combatID != pair.enemyCombatID }
        }
        if pairs.isEmpty && !operators.isEmpty && !enemies.isEmpty {
            tryAutoPair()
        }
        if pairs.isEmpty { stop() }
    }

    // MARK: - 自动配对

    private func tryAutoPair() {
        guard !operators.isEmpty, !enemies.isEmpty else {
            NSLog("[⚔️Combat] 自动配对失败: 干员=\(operators.count) 敌人=\(enemies.count) — 等待另一半")
            return
        }

        // 过滤掉已经配对的
        let pairedOpIDs = Set(pairs.map { $0.operatorCombatID })
        let pairedEnemyIDs = Set(pairs.map { $0.enemyCombatID })

        for op in operators where !pairedOpIDs.contains(op.combatID) {
            for enemy in enemies where !pairedEnemyIDs.contains(enemy.combatID) {
                let pair = CombatPair(
                    id: "pair_\(op.combatID)_vs_\(enemy.combatID)",
                    operatorCombatID: op.combatID,
                    enemyCombatID: enemy.combatID,
                    state: .idle
                )
                pairs.append(pair)
                op.model?.targetWindowFrame = enemy.windowFrame
                NSLog("[⚔️Combat] 配对成功! \(op.model?.displayName ?? "?") → \(enemy.model?.displayName ?? "?")")
                startCombat(pairID: pair.id)
                return
            }
        }
    }

    // MARK: - 战斗循环

    func start() {
        guard !isRunning, !pairs.isEmpty else {
            NSLog("[⚔️Combat] 启动失败: isRunning=\(isRunning) pairs=\(pairs.count)")
            return
        }
        isRunning = true
        NSLog("[⚔️Combat] 战斗循环已启动 (50ms tick)")

        let source = DispatchSource.makeTimerSource(queue: .main)
        source.schedule(deadline: .now(), repeating: .milliseconds(50), leeway: .milliseconds(8))
        source.setEventHandler { [weak self] in
            self?.tick()
        }
        tickTimer = source
        source.resume()
    }

    func stop() {
        isRunning = false
        tickTimer?.cancel()
        tickTimer = nil
    }

    private func startCombat(pairID: String) {
        guard let idx = pairs.firstIndex(where: { $0.id == pairID }) else { return }
        pairs[idx].state = .alerted
        NSLog("[⚔️Combat] 战斗开始! 状态=alerted, 启动战斗循环")
        if !isRunning { start() }
    }

    // MARK: - Tick

    private func tick() {
        for idx in pairs.indices {
            guard idx < pairs.count else { break }
            guard pairs[idx].state != .victory,
                  pairs[idx].state != .defeat else { continue }

            guard let op = combatant(with: pairs[idx].operatorCombatID),
                  let enemy = combatant(with: pairs[idx].enemyCombatID),
                  let opModel = op.model,
                  let enemyModel = enemy.model,
                  let opFrame = op.windowFrame,
                  let enemyFrame = enemy.windowFrame else {
                continue
            }

            switch pairs[idx].state {
            case .idle, .alerted:
                // 标记敌人位置，开始接近
                opModel.targetWindowFrame = enemyFrame
                pairs[idx].state = .approaching
                NSLog("[⚔️Combat] 状态→approaching")

            case .approaching:
                // 更新敌人位置
                opModel.targetWindowFrame = enemyFrame

                // 检测距离：当操作员窗口与敌人窗口足够近时，开始攻击
                let distance = hypot(
                    opFrame.midX - enemyFrame.midX,
                    opFrame.midY - enemyFrame.midY
                )

                if distance < 200 {
                    pairs[idx].state = .attacking
                    pairs[idx].approachedAt = Date()
                    pairs[idx].shakeCount = 0
                    opModel.startAttacking()
                    NSLog("[⚔️Combat] 状态→attacking! 距离=\(distance)")
                }

            case .attacking:
                // 持续攻击
                if opModel.performAttack() {
                    pairs[idx].attackTimer += 1
                    pairs[idx].shakeCount += 1

                    // 抖动双方窗口（递增强度）
                    let intensity = min(3 + CGFloat(pairs[idx].shakeCount) * 0.8, 12)
                    shakeWindows(op: op, enemy: enemy, intensity: intensity)

                    // 3 次攻击后胜利
                    if pairs[idx].attackTimer >= 3 {
                        let pairId = pairs[idx].id
                        pairs[idx].state = .victory
                        opModel.declareVictory()
                        enemyModel.declareDefeat()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                            guard let self, let idx = self.pairs.firstIndex(where: { $0.id == pairId }) else { return }
                            self.pairs.remove(at: idx)
                            if self.pairs.isEmpty { self.stop() }
                        }
                    }
                }

            default:
                break
            }
        }
    }

    // MARK: - 抖动特效

    private func shakeWindows(op: Combatant, enemy: Combatant, intensity: CGFloat) {
        guard let opWin = op.window, let enemyWin = enemy.window else { return }

        // 操作员抖动（向右/向左两个方向）
        shakeWindow(opWin, intensity: intensity, axis: .horizontal)
        // 敌人抖动（反向）
        shakeWindow(enemyWin, intensity: intensity * 0.8, axis: .horizontal)
    }

    private enum ShakeAxis { case horizontal, vertical, both }

    private func shakeWindow(_ window: NSWindow, intensity: CGFloat, axis: ShakeAxis) {
        let original = window.frame.origin
        let offsetX: CGFloat, offsetY: CGFloat

        switch axis {
        case .horizontal:
            offsetX = CGFloat.random(in: -intensity...intensity)
            offsetY = 0
        case .vertical:
            offsetX = 0
            offsetY = CGFloat.random(in: -intensity...intensity)
        case .both:
            offsetX = CGFloat.random(in: -intensity...intensity)
            offsetY = CGFloat.random(in: -intensity...intensity)
        }

        // Apply offset
        window.setFrameOrigin(NSPoint(
            x: original.x + offsetX,
            y: original.y + offsetY
        ))

        // Return to original position after a short delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak window] in
            window?.setFrameOrigin(original)
        }
    }

    // MARK: - Helpers

    private func combatant(with id: String) -> Combatant? {
        operators.first(where: { $0.combatID == id })
            ?? enemies.first(where: { $0.combatID == id })
    }
}
