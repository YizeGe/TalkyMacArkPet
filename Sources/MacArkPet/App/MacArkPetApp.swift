// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 MacArkPet contributors

import AppKit

@MainActor
final class MacArkPetApp: NSObject, NSApplicationDelegate {
    static let shared = MacArkPetApp()
    let store = ArkModelStore()
    var petControllers: [PetWindowController] = []
    var isClickThrough = false
    var isAlwaysOnTop = true
    var isVoiceEnabled = true
    private var launcherController: LauncherWindowController?
    private var statusItem: NSStatusItem?
    private var languageObserver: NSObjectProtocol?
    private var appObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSLog("MacArkPet applicationDidFinishLaunching")
        NSApp.setActivationPolicy(.regular)

        CharacterVoiceService.shared.load()

        // 🖥️ 屏幕监控服务（配置驱动，无AI）
        ScreenWatcherService.shared.start()

        // 💬 对话引擎加载
        DialogueEngine.shared.load()
        DialogueEngine.shared.loadProfiles()

        // 🕸️ 启动配置管理 Web 服务器
        ConfigWebServer.shared.start()

        store.load()
        launcherController = LauncherWindowController(
            store: store,
            onLaunch: { [weak self] item in
                self?.launchPet(model: item)
            },
            onScaleChange: { [weak self] item, scale in
                self?.updatePetScale(model: item, scale: scale)
            }
        )
        launcherController?.show()
        NSApp.activate(ignoringOtherApps: true)

        installStatusItem()
        languageObserver = NotificationCenter.default.addObserver(
            forName: .appLanguageDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.launcherController?.updateTitle()
                self?.refreshMenus()
            }
        }

        // 📱 监听前台 App 切换，通知所有桌宠
        appObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self else { return }
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  let appName = app.localizedName else { return }

            MainActor.assumeIsolated {
                guard !self.petControllers.isEmpty else { return }
                let category = self.categorizeApp(app, name: appName)
                for ctrl in self.petControllers {
                    ctrl.model.onAppChanged(appName: appName, category: category)
                }
                // 🖥️ ScreenWatcher 也会处理，这里保留旧逻辑做兼容
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        for ctrl in petControllers {
            ctrl.model.saveStats()
        }
        ConfigWebServer.shared.stop()
        ScreenWatcherService.shared.stop()
        if let languageObserver {
            NotificationCenter.default.removeObserver(languageObserver)
        }
        if let appObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(appObserver)
        }
    }

    // MARK: - 📱 App 分类逻辑（同原有）

    private func categorizeApp(_ app: NSRunningApplication, name: String) -> String {
        guard let bundleId = app.bundleIdentifier?.lowercased() else {
            return "other"
        }

        // 编程 / 开发工具
        if bundleId.hasPrefix("com.apple.dt") ||
           bundleId.contains("xcode") ||
           bundleId.contains("vscode") ||
           bundleId.contains("visual-studio") ||
           bundleId.contains("jetbrains") ||
           bundleId.contains("sublime") ||
           bundleId.contains("atom") ||
           bundleId.contains("terminal") ||
           bundleId.contains("iterm") ||
           bundleId.contains("warp") ||
           bundleId.contains("cursor") ||
           bundleId.hasPrefix("io.github") ||
           bundleId.contains("github") ||
           name.lowercased().contains("code") ||
           name.lowercased().contains("terminal") {
            return "coding"
        }

        // 社交 / 聊天
        if bundleId.contains("wechat") ||
           bundleId.contains("dingtalk") ||
           bundleId.contains("lark") ||
           bundleId.contains("feishu") ||
           bundleId.contains("tencent") ||
           bundleId.contains("qq") ||
           bundleId.contains("telegram") ||
           bundleId.contains("discord") ||
           bundleId.contains("slack") ||
           bundleId.contains("whatsapp") ||
           bundleId.contains("signal") ||
           bundleId.contains("twitter") ||
           bundleId.contains("x.") ||
           bundleId.contains("weibo") ||
           bundleId.contains("bilibili") ||
           bundleId.contains("skype") ||
           bundleId.contains("zoom") ||
           bundleId.contains("notion") ||
           bundleId.contains("messages") ||
           bundleId == "com.apple.iChat" ||
           bundleId == "com.apple.mobilenotes" {
            return "social"
        }

        // 游戏
        let gameBundleIds = ["com.epicgames", "com.valve", "com.activision", "com.ubi", "com.ea",
                             "net.riot", "com.blizzard", "com.steam", "com.battle",
                             "com.mojang", "com.rocket", "com.roblox",
                             "com.gaijin", "unity.", "com.unity3d"]
        let gameNames = ["league of legends", "genshin impact", "honkai", "star rail", "wuthering",
                         "minecraft", "stardew valley", "terraria", "elden ring",
                         "cyberpunk", "baldur's gate", "dota", "counter-strike",
                         "overwatch", "apex", "fortnite", "valorant", "arknights",
                         "原神", "崩坏", "星穹铁道", "绝区零",
                         "英雄联盟", "王者荣耀"]
        if gameBundleIds.contains(where: { bundleId.hasPrefix($0) }) ||
           gameNames.contains(where: { name.lowercased().contains($0) }) {
            return "game"
        }

        // 办公
        if bundleId.hasPrefix("com.microsoft.") ||
           bundleId.hasPrefix("com.apple.iwork") ||
           bundleId.contains("numbers") ||
           bundleId.contains("pages") ||
           bundleId.contains("keynote") ||
           bundleId.contains("wps") ||
           bundleId.contains("google.docs") ||
           bundleId.contains("google.sheets") ||
           bundleId.contains("google.slides") ||
           bundleId.contains("omnigraffle") ||
           bundleId.contains("bear.app") ||
           bundleId == "com.apple.Preview" ||
           bundleId == "com.apple.finder" {
            return "work"
        }

        return "other"
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        launcherController?.show()
        return true
    }

    // MARK: - AP 菜单栏

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.title = "AP"
        item.button?.toolTip = "MacArkPet"
        item.menu = makeMenu()
        statusItem = item
    }

    private func makeMenu() -> NSMenu {
        let language = AppLanguage.current
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(NSMenuItem(title: L10n.menuOpenLauncher(language), action: #selector(showLauncher), keyEquivalent: "o"))
        menu.addItem(.separator())

        // ── 正在运行的桌宠 ──
        if petControllers.isEmpty {
            let emptyItem = NSMenuItem(title: L10n.menuNoPets(language), action: nil, keyEquivalent: "")
            emptyItem.isEnabled = false
            menu.addItem(emptyItem)
        } else {
            for (index, ctrl) in petControllers.enumerated() {
                let title = "\(ctrl.model.displayName)"
                let petItem = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                petItem.submenu = makePetSubmenu(controllerIndex: index, language: language)
                menu.addItem(petItem)
            }

            menu.addItem(.separator())

            // ── 全部操作 ──
            menu.addItem(NSMenuItem(title: L10n.menuPoke(language), action: #selector(pokeAll), keyEquivalent: "p"))
            menu.addItem(NSMenuItem(title: L10n.menuSpecialAction(language), action: #selector(specialActionAll), keyEquivalent: "e"))
            menu.addItem(NSMenuItem(title: L10n.menuRest(language), action: #selector(restAll), keyEquivalent: "a"))
            menu.addItem(NSMenuItem(title: L10n.menuSleep(language), action: #selector(sleepAll), keyEquivalent: "s"))
            menu.addItem(NSMenuItem(title: L10n.menuFeed(language), action: #selector(feedAll), keyEquivalent: "f"))
            menu.addItem(.separator())

            // 📍 全部停靠 / 取消
            if petControllers.contains(where: { $0.model.stayMode != nil }) {
                menu.addItem(NSMenuItem(title: "🚶 全部恢复行走", action: #selector(resumeWalkingAll), keyEquivalent: ""))
            } else {
                let sitAllItem = NSMenuItem(title: "🪑 全部坐在这里", action: #selector(stayHereAll), keyEquivalent: "")
                sitAllItem.representedObject = PetModel.StayMode.sitHere
                menu.addItem(sitAllItem)

                let lieAllItem = NSMenuItem(title: "🛏️ 全部躺在这里", action: #selector(stayHereAll), keyEquivalent: "")
                lieAllItem.representedObject = PetModel.StayMode.lieHere
                menu.addItem(lieAllItem)
            }
            menu.addItem(.separator())
            menu.addItem(NSMenuItem(title: L10n.menuAllPetsStatus(language), action: #selector(showAllStatus), keyEquivalent: ""))

            menu.addItem(.separator())

            let clickThrough = NSMenuItem(title: L10n.menuClickThrough(language), action: #selector(toggleClickThrough), keyEquivalent: "t")
            clickThrough.state = isClickThrough ? .on : .off
            menu.addItem(clickThrough)

            let topmost = NSMenuItem(title: L10n.menuAlwaysOnTop(language), action: #selector(toggleAlwaysOnTop), keyEquivalent: "")
            topmost.state = isAlwaysOnTop ? .on : .off
            menu.addItem(topmost)

            let voiceItem = NSMenuItem(title: "🔊 语音开关", action: #selector(toggleVoice), keyEquivalent: "v")
            voiceItem.state = isVoiceEnabled ? .on : .off
            menu.addItem(voiceItem)

            menu.addItem(NSMenuItem(title: L10n.menuResetPosition(language), action: #selector(resetAllPositions), keyEquivalent: "r"))
            menu.addItem(.separator())
        }

        menu.addItem(languageMenuItem(language: language))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: L10n.menuQuit(language), action: #selector(quit), keyEquivalent: "q"))

        for item in menu.items {
            item.target = self
        }
        return menu
    }

    private func makePetSubmenu(controllerIndex: Int, language: AppLanguage) -> NSMenu {
        let submenu = NSMenu(title: petControllers[controllerIndex].model.displayName)

        let pokeItem = NSMenuItem(title: L10n.menuPoke(language), action: #selector(pokePet(_:)), keyEquivalent: "")
        pokeItem.representedObject = controllerIndex
        submenu.addItem(pokeItem)

        let specialItem = NSMenuItem(title: L10n.menuSpecialAction(language), action: #selector(specialActionPet(_:)), keyEquivalent: "")
        specialItem.representedObject = controllerIndex
        submenu.addItem(specialItem)

        let restItem = NSMenuItem(title: L10n.menuRest(language), action: #selector(restPet(_:)), keyEquivalent: "")
        restItem.representedObject = controllerIndex
        submenu.addItem(restItem)

        let sleepItem = NSMenuItem(title: L10n.menuSleep(language), action: #selector(sleepPet(_:)), keyEquivalent: "")
        sleepItem.representedObject = controllerIndex
        submenu.addItem(sleepItem)

        let feedItem = NSMenuItem(title: L10n.menuFeed(language), action: #selector(feedPet(_:)), keyEquivalent: "")
        feedItem.representedObject = controllerIndex
        submenu.addItem(feedItem)

        submenu.addItem(.separator())

        // 📍 CP 小剧场手动触发
        if petControllers.count > 1 {
            let cpTheaterMenu = NSMenu(title: "💭 触发互动小剧场")
            let cpTheaterItem = NSMenuItem(title: "💭 触发互动小剧场...", action: nil, keyEquivalent: "")
            cpTheaterItem.submenu = cpTheaterMenu
            
            for (index, otherCtrl) in petControllers.enumerated() {
                if index == controllerIndex { continue }
                let item = NSMenuItem(title: "与 \(otherCtrl.model.displayName)", action: #selector(triggerManualCPTheater(_:)), keyEquivalent: "")
                item.representedObject = ManualCPPayload(initiatorIndex: controllerIndex, targetIndex: index)
                cpTheaterMenu.addItem(item)
            }
            submenu.addItem(cpTheaterItem)
            submenu.addItem(.separator())
        }

        // 📍 停靠菜单
        let model = petControllers[controllerIndex].model
        if model.stayMode != nil {
            let resumeItem = NSMenuItem(title: "🚶 恢复行走", action: #selector(resumeWalkingPet(_:)), keyEquivalent: "")
            resumeItem.representedObject = controllerIndex
            submenu.addItem(resumeItem)
        } else {
            let sitItem = NSMenuItem(title: "🪑 坐在这里", action: #selector(stayHerePet(_:)), keyEquivalent: "")
            sitItem.representedObject = StayMenuPayload(controllerIndex: controllerIndex, mode: .sitHere)
            submenu.addItem(sitItem)

            let lieItem = NSMenuItem(title: "🛏️ 躺在这里", action: #selector(stayHerePet(_:)), keyEquivalent: "")
            lieItem.representedObject = StayMenuPayload(controllerIndex: controllerIndex, mode: .lieHere)
            submenu.addItem(lieItem)
        }

        submenu.addItem(.separator())

        let voiceItem = NSMenuItem(title: "🔊 角色语音", action: #selector(toggleCharacterVoice(_:)), keyEquivalent: "")
        voiceItem.representedObject = controllerIndex
        voiceItem.state = isCharacterVoiceEnabled(controllerIndex) ? .on : .off
        submenu.addItem(voiceItem)

        submenu.addItem(.separator())

        let statusItem = NSMenuItem(title: L10n.menuPetStatusDetail(language), action: #selector(showPetStatus(_:)), keyEquivalent: "")
        statusItem.representedObject = controllerIndex
        submenu.addItem(statusItem)

        submenu.addItem(.separator())

        let closeItem = NSMenuItem(title: L10n.menuClosePet(language), action: #selector(closePet(_:)), keyEquivalent: "")
        closeItem.representedObject = controllerIndex
        submenu.addItem(closeItem)

        for item in submenu.items {
            item.target = self
        }
        return submenu
    }

    private func languageMenuItem(language: AppLanguage) -> NSMenuItem {
        let root = NSMenuItem(title: L10n.language(language), action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: L10n.language(language))
        let preferred = AppLanguage.preferred

        for option in AppLanguage.allCases {
            let item = NSMenuItem(title: option.pickerTitle(current: language), action: #selector(setLanguage), keyEquivalent: "")
            item.target = self
            item.representedObject = option.rawValue
            item.state = option == preferred ? .on : .off
            submenu.addItem(item)
        }

        root.submenu = submenu
        return root
    }

    // MARK: - 📍 单个桌宠停靠操作

    /// 携带 (controllerIndex, stayMode) 的菜单载荷
    private struct StayMenuPayload {
        let controllerIndex: Int
        let mode: PetModel.StayMode
    }

    private struct ManualCPPayload {
        let initiatorIndex: Int
        let targetIndex: Int
    }

    @objc private func stayHerePet(_ sender: NSMenuItem) {
        guard let payload = sender.representedObject as? StayMenuPayload,
              let ctrl = pet(at: payload.controllerIndex) else { return }
        ctrl.model.stayHere(mode: payload.mode)
        refreshMenus()
    }

    @objc private func triggerManualCPTheater(_ sender: NSMenuItem) {
        guard let payload = sender.representedObject as? ManualCPPayload,
              petControllers.indices.contains(payload.initiatorIndex),
              petControllers.indices.contains(payload.targetIndex) else { return }

        let initiator = petControllers[payload.initiatorIndex].model
        let target = petControllers[payload.targetIndex].model
        
        CompanionEngine.shared.triggerManualConversation(initiator: initiator, target: target)
    }

    @objc private func resumeWalkingPet(_ sender: NSMenuItem) {
        guard let index = sender.representedObject as? Int,
              let ctrl = pet(at: index) else { return }
        ctrl.model.resumeWalking()
        refreshMenus()
    }

    @objc private func stayHereAll(_ sender: NSMenuItem) {
        guard let mode = sender.representedObject as? PetModel.StayMode else { return }
        for ctrl in petControllers {
            ctrl.model.stayHere(mode: mode)
        }
        refreshMenus()
    }

    @objc private func resumeWalkingAll() {
        for ctrl in petControllers {
            ctrl.model.resumeWalking()
        }
        refreshMenus()
    }

    // MARK: - 单个桌宠操作

    private func pet(at index: Int) -> PetWindowController? {
        guard index >= 0, index < petControllers.count else { return nil }
        return petControllers[index]
    }

    @objc private func pokePet(_ sender: NSMenuItem) {
        guard let index = sender.representedObject as? Int, let ctrl = pet(at: index) else { return }
        ctrl.model.poke()
    }

    @objc private func specialActionPet(_ sender: NSMenuItem) {
        guard let index = sender.representedObject as? Int, let ctrl = pet(at: index) else { return }
        ctrl.model.specialAction()
    }

    @objc private func restPet(_ sender: NSMenuItem) {
        guard let index = sender.representedObject as? Int, let ctrl = pet(at: index) else { return }
        ctrl.model.rest()
    }

    @objc private func sleepPet(_ sender: NSMenuItem) {
        guard let index = sender.representedObject as? Int, let ctrl = pet(at: index) else { return }
        ctrl.model.sleep()
    }

    @objc private func feedPet(_ sender: NSMenuItem) {
        guard let index = sender.representedObject as? Int, let ctrl = pet(at: index) else { return }
        ctrl.model.feed()
    }

    @objc private func showPetStatus(_ sender: NSMenuItem) {
        guard let index = sender.representedObject as? Int, let ctrl = pet(at: index) else { return }
        let alert = NSAlert()
        alert.messageText = ctrl.model.statusText
        alert.addButton(withTitle: "收到")
        alert.runModal()
    }

    @objc private func closePet(_ sender: NSMenuItem) {
        guard let index = sender.representedObject as? Int,
              index >= 0, index < petControllers.count else { return }
        let ctrl = petControllers[index]
        ctrl.close()
        petControllers.remove(at: index)

        // ✨ 宠物全部关闭了，重置全局状态
        if petControllers.isEmpty {
            isClickThrough = false
            isAlwaysOnTop = true
        }

        refreshMenus()
        CombatManager.shared.cleanUpStale()
    }

    // MARK: - 全部桌宠操作

    @objc private func pokeAll() {
        for ctrl in petControllers {
            ctrl.model.poke()
        }
    }

    @objc private func specialActionAll() {
        for ctrl in petControllers {
            ctrl.model.specialAction()
        }
    }

    @objc private func restAll() {
        for ctrl in petControllers {
            ctrl.model.rest()
        }
    }

    @objc private func sleepAll() {
        for ctrl in petControllers {
            ctrl.model.sleep()
        }
    }

    @objc private func feedAll() {
        for ctrl in petControllers {
            ctrl.model.feed()
        }
    }

    @objc private func showAllStatus() {
        guard !petControllers.isEmpty else { return }
        let language = AppLanguage.current

        var lines: [String] = []
        for ctrl in petControllers {
            let m = ctrl.model
            lines.append("\(L10n.statusPetName(language)): \(m.displayName)")
            lines.append("❤️ \(L10n.statusAffection(language)): \(m.affection)/100")
            lines.append("⚡ \(L10n.statusEnergy(language)): \(Int(m.stamina))/100")
            lines.append("✨ 心情: \(Int(m.moodLevel))/100")
            lines.append("💰 金币: \(m.coins)")
            lines.append("🔥 \(L10n.statusStreak(language)): \(m.dailyStreak)\(L10n.statusDays(language))")
            lines.append("")
        }

        let alert = NSAlert()
        alert.messageText = L10n.menuAllPetsStatus(language)
        alert.informativeText = lines.dropLast().joined(separator: "\n")  // drop trailing empty line
        alert.addButton(withTitle: "收到")
        alert.runModal()
    }

    @objc private func showLauncher() {
        launcherController?.show()
    }

    @objc private func toggleClickThrough(_ sender: NSMenuItem) {
        isClickThrough.toggle()
        for ctrl in petControllers {
            ctrl.setClickThrough(isClickThrough)
        }
        refreshMenus()
    }

    @objc private func toggleAlwaysOnTop(_ sender: NSMenuItem) {
        isAlwaysOnTop.toggle()
        for ctrl in petControllers {
            ctrl.setAlwaysOnTop(isAlwaysOnTop)
        }
        refreshMenus()
    }

    @objc private func toggleVoice(_ sender: NSMenuItem) {
        isVoiceEnabled.toggle()
        CharacterVoiceService.isEnabled = isVoiceEnabled
        refreshMenus()
    }

    @objc private func toggleCharacterVoice(_ sender: NSMenuItem) {
        guard let index = sender.representedObject as? Int, index < petControllers.count else { return }
        let ctrl = petControllers[index]
        let cid = ctrl.model.characterId
        if CharacterVoiceService.enabledCharacters == nil {
            // First time: init with all currently-voiced characters, then remove this one
            CharacterVoiceService.enabledCharacters = Set(petControllers.map { $0.model.characterId })
        }
        if CharacterVoiceService.enabledCharacters?.contains(cid) == true {
            CharacterVoiceService.enabledCharacters?.remove(cid)
        } else {
            CharacterVoiceService.enabledCharacters?.insert(cid)
        }
        refreshMenus()
    }

    private func isCharacterVoiceEnabled(_ index: Int) -> Bool {
        guard index < petControllers.count else { return false }
        let cid = petControllers[index].model.characterId
        guard let allowed = CharacterVoiceService.enabledCharacters else { return true }
        return allowed.contains(cid)
    }

    @objc private func resetAllPositions() {
        for ctrl in petControllers {
            ctrl.resetPosition()
        }
    }

    @objc private func setLanguage(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String else { return }
        AppLanguage.setPreferredRawValue(rawValue)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    // MARK: - 启动 / 更新

    /// 从 WebUI 或其他模块启动桌宠 — internal 访问级别供 ConfigWebServer 调用
    func launchPet(model item: ArkModelItem) {
        let controller = PetWindowController(model: PetModel())
        controller.setContextMenu(makeMenu())
        controller.launch(
            model: item,
            renderScale: CGFloat(store.scale(for: item)),
            speed: CGFloat(store.petSpeed)
        )

        // 将新窗口初始位置错开，避免多个宠物堆叠
        if !petControllers.isEmpty {
            let offset = CGFloat(petControllers.count * 48)
            var origin = controller.window.frame.origin
            origin.x += offset
            origin.y -= offset
            controller.window.setFrameOrigin(origin)
        }

        petControllers.append(controller)
        store.status = item.hasSpineAssets ? .launchedFull(item.title) : .launchedPet(item.title)
        refreshMenus()
    }

    private func updatePetScale(model item: ArkModelItem, scale: Double) {
        // 更新所有匹配的正在运行的桌宠
        for ctrl in petControllers where ctrl.model.characterId == item.voiceCharacterID || ctrl.model.displayName == item.title {
            ctrl.updateRenderScale(CGFloat(scale))
        }
    }

    func refreshMenus() {
        statusItem?.menu = makeMenu()
        for ctrl in petControllers {
            ctrl.setContextMenu(makeMenu())
        }
    }
}
