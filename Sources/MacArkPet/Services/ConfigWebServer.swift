// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 MacArkPet contributors

import AppKit
import Network
import Combine

/// 内嵌 HTTP 服务器，提供配置管理 Web 界面
/// 访问地址：http://localhost:19191
@MainActor
final class ConfigWebServer {
    static let shared = ConfigWebServer()
    static let port: UInt16 = 19191

    private var listener: NWListener?
    private var isRunning = false
    private var webContent: [String: Data] = [:]  // path → cached response

    private init() {}

    /// 启动服务器（非阻塞）
    func start() {
        guard !isRunning else { return }

        loadWebContent()

        do {
            let params = NWParameters.tcp
            let port = NWEndpoint.Port(rawValue: Self.port)!
            listener = try NWListener(using: params, on: port)

            listener?.stateUpdateHandler = { [weak self] state in
                MainActor.assumeIsolated {
                    switch state {
                    case .ready:
                        self?.isRunning = true
                        NSLog("[ConfigWebServer] 启动成功 → http://localhost:\(Self.port)")
                    case .failed(let error):
                        NSLog("[ConfigWebServer] 启动失败: \(error)")
                    default:
                        break
                    }
                }
            }

            listener?.newConnectionHandler = { [weak self] connection in
                MainActor.assumeIsolated {
                    self?.handleConnection(connection)
                }
            }

            listener?.start(queue: .main)
        } catch {
            NSLog("[ConfigWebServer] 创建失败: \(error)")
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        isRunning = false
        webContent.removeAll()
    }

    // MARK: - 请求处理

    private func handleConnection(_ connection: NWConnection) {
        connection.stateUpdateHandler = { [weak self] state in
            if state == .ready {
                DispatchQueue.main.async {
                    Self.receiveAll(connection, buffer: Data())
                }
            }
        }
        connection.start(queue: .main)
    }

    /// 持续读取直到收到完整 HTTP 请求
    private static func receiveAll(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, _, error in
            guard let data = data else {
                connection.cancel()
                return
            }
            var accumulated = buffer
            accumulated.append(data)

            guard let raw = String(data: accumulated, encoding: .utf8) else {
                connection.cancel()
                return
            }

            // 检查是否收到了完整请求
            let headerEnd = raw.range(of: "\r\n\r\n")
            if let headerRange = headerEnd {
                // 有 Content-Length? 检查 body 是否完整
                let headerSection = raw[raw.startIndex..<headerRange.lowerBound]
                let bodyStart = headerRange.upperBound
                let bodyStr = raw[bodyStart...]

                if let clLine = headerSection.components(separatedBy: "\r\n").first(where: { $0.lowercased().hasPrefix("content-length:") }),
                   let clValue = Int(clLine.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)) {
                    // 有 Content-Length，检查 body 长度
                    if bodyStr.utf8.count < clValue {
                        // body 还没到齐，继续读
                        Self.receiveAll(connection, buffer: accumulated)
                        return
                    }
                }
                // body 完整了，处理请求
                Self.handleRequest(raw, connection: connection)
            } else {
                // 还没收到 header 结尾，继续读
                Self.receiveAll(connection, buffer: accumulated)
            }
        }
    }

    private static func handleRequest(_ request: String, connection: NWConnection) {
        let lines = request.components(separatedBy: "\r\n")
        guard let firstLine = lines.first, firstLine.hasPrefix("GET") || firstLine.hasPrefix("PUT") || firstLine.hasPrefix("POST") else {
            sendResponse(connection, status: 400, body: "Bad Request")
            return
        }

        let parts = firstLine.components(separatedBy: " ")
        guard parts.count >= 2 else {
            sendResponse(connection, status: 400, body: "Bad Request")
            return
        }

        let method = parts[0]
        var path = parts[1]
        // 去掉 query string（?t=xxx），否则影响路由匹配
        if let queryStart = path.firstIndex(of: "?") {
            path = String(path[..<queryStart])
        }

        switch (method, path) {
        case ("GET", "/"):
            sendHTML(connection, path: "/index.html")
        case ("GET", "/api/context/stream"):
            handleContextStream(connection)
        case ("GET", "/api/pets/available"):
            handleAvailablePets(connection)
        case ("GET", "/api/ai-config"):
            handleGetAIConfig(connection)
        case ("GET", _) where path.hasPrefix("/api/"):
            handleAPI(connection, path: path)
        case ("GET", _):
            sendHTML(connection, path: path)
        case ("PUT", "/api/config"):
            handlePutConfig(connection, request: request)
        case ("POST", "/api/config/import"):
            handleImportConfig(connection, request: request)
        case ("POST", "/api/config/clear"):
            handleClearCategory(connection, request: request)
        case ("POST", "/api/config/copy"):
            handleCopyCategory(connection, request: request)
        case ("POST", "/api/agent/generate"):
            handleAgentGenerate(connection, request: request)
        case ("POST", "/api/agent/save"):
            handleAgentSave(connection, request: request)
        case ("POST", "/api/test/trigger"):
            sendJSON(connection, body: #"{"success": true}"#)
        case ("POST", "/api/pets/command"):
            handlePetCommand(connection, request: request)
        case ("POST", "/api/pets/launch"):
            handlePetLaunch(connection, request: request)
        case ("PUT", "/api/settings"):
            handlePutSettings(connection, request: request)
        case ("POST", "/api/history"):
            handleSaveHistory(connection, request: request)
        case ("POST", "/api/profiles/save"):
            handleSaveProfile(connection, request: request)
        case ("POST", "/api/profiles/delete"):
            handleDeleteProfile(connection, request: request)
        case ("POST", "/api/profiles/create"):
            handleCreateProfile(connection, request: request)
        case ("POST", "/api/profiles/save-dialogues"):
            handleSaveDialogues(connection, request: request)
        case ("PUT", "/api/ai-config"):
            handlePutAIConfig(connection, request: request)
        default:
            sendResponse(connection, status: 404, body: "Not Found")
        }
    }

    // MARK: - API 处理

    private static func handleAPI(_ connection: NWConnection, path: String) {
        switch path {
        case "/api/config":
            // 返回当前 ScreenTriggers.toml 内容 + 解析后的分类
            let tomlContent = readConfigFile() ?? "未找到配置文件"
            let parsed = parseConfigPreview()
            let json = """
            {"toml": \(jsonEscape(tomlContent)), "parsed": \(parsed)}
            """
            sendJSON(connection, body: json)

        case "/api/profiles":
            // 返回角色列表和简要信息
            let profiles = listProfiles()
            sendJSON(connection, body: profiles)

        case "/api/profiles/detail":
            // 返回完整角色详情（含台词）
            let details = listDetailedProfiles()
            sendJSON(connection, body: details)

        case "/api/context":
            // 返回当前屏幕上下文
            let context = getCurrentContext()
            sendJSON(connection, body: context)

        case "/api/pets":
            // 返回当前运行的桌宠列表
            let pets = listActivePets()
            sendJSON(connection, body: pets)

        case "/api/settings":
            // 返回全局设置
            let settings = getSettings()
            sendJSON(connection, body: settings)

        case "/api/status":
            // 服务器状态
            let status = """
            {"status": "running", "port": \(Self.port)}
            """
            sendJSON(connection, body: status)

        case "/api/config/export":
            handleExportConfig(connection)

        case "/api/history":
            handleGetHistory(connection)

        case "/api/audit":
            // 角色数据审查
            let report = runDataAudit()
            sendJSON(connection, body: report)
            
        case "/api/test/trigger":
            // 手动触发测试（返回成功即可，前端本地模拟）
            sendJSON(connection, body: #"{"success": true}"#)

        default:
            sendResponse(connection, status: 404, body: "Unknown API")
        }
    }

    private static func handlePutConfig(_ connection: NWConnection, request: String) {
        // 从 PUT 请求体提取 TOML 内容
        if let bodyRange = request.range(of: "\r\n\r\n") {
            let body = String(request[bodyRange.upperBound...])
            let configDir = ScreenWatcherService.configDir
            let configURL = ScreenWatcherService.configURL

            try? FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)

            do {
                try body.write(to: configURL, atomically: true, encoding: .utf8)
                // 重新加载配置
                ScreenWatcherService.shared.loadConfig()
                sendJSON(connection, body: #"{"success": true}"#)
            } catch {
                sendJSON(connection, body: #"{"success": false, "error": "# + jsonEscape(error.localizedDescription) + #"}"#)
            }
        } else {
            sendJSON(connection, body: #"{"success": false, "error": "No body"}"#)
        }
    }

    // MARK: - Phase 1: 批量操作 API

    /// 导出配置为 TOML 下载
    private static func handleExportConfig(_ connection: NWConnection) {
        guard let content = readConfigFile() else {
            sendJSON(connection, body: #"{"success": false, "error": "No config"}"#)
            return
        }
        let escaped = jsonEscape(content)
        sendJSON(connection, body: #"{"success": true, "toml": "# + escaped + #"}"#)
    }

    /// 导入 TOML 配置
    private static func handleImportConfig(_ connection: NWConnection, request: String) {
        guard let bodyRange = request.range(of: "\r\n\r\n") else {
            sendJSON(connection, body: #"{"success": false, "error": "No body"}"#)
            return
        }
        let body = String(request[bodyRange.upperBound...])
        // 验证基本 TOML 格式
        let valid = body.contains("[") && body.contains("]")
        guard valid else {
            sendJSON(connection, body: #"{"success": false, "error": "Invalid TOML format"}"#)
            return
        }
        let configDir = ScreenWatcherService.configDir
        let configURL = ScreenWatcherService.configURL
        try? FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        do {
            try body.write(to: configURL, atomically: true, encoding: .utf8)
            ScreenWatcherService.shared.loadConfig()
            sendJSON(connection, body: #"{"success": true}"#)
        } catch {
            sendJSON(connection, body: #"{"success": false, "error": "# + jsonEscape(error.localizedDescription) + #"}"#)
        }
    }

    /// 清空指定分类
    private static func handleClearCategory(_ connection: NWConnection, request: String) {
        guard let bodyRange = request.range(of: "\r\n\r\n") else {
            sendJSON(connection, body: #"{"success": false, "error": "No body"}"#)
            return
        }
        let body = String(request[bodyRange.upperBound...])
        guard let data = body.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let category = json["category"] as? String else {
            sendJSON(connection, body: #"{"success": false, "error": "Bad request"}"#)
            return
        }
        guard let content = readConfigFile() else {
            sendJSON(connection, body: #"{"success": false, "error": "No config file"}"#)
            return
        }
        // 从 content 中移除该分类的所有行
        var newLines: [String] = []
        var inTargetSection = false
        var removedCount = 0
        for line in content.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "[website_categories.\(category)]" {
                inTargetSection = true
                continue
            }
            if inTargetSection {
                if trimmed.hasPrefix("[") {
                    inTargetSection = false
                    newLines.append(line)
                    removedCount += 1
                } else if !trimmed.isEmpty {
                    removedCount += 1
                    continue
                } else {
                    // 空行在分类内也跳过
                    removedCount += 1
                    continue
                }
            } else {
                newLines.append(line)
            }
        }
        let newContent = newLines.joined(separator: "\n")
        let configURL = ScreenWatcherService.configURL
        do {
            try newContent.write(to: configURL, atomically: true, encoding: .utf8)
            ScreenWatcherService.shared.loadConfig()
            sendJSON(connection, body: #"{"success": true, "removedCount": "# + String(removedCount) + #"}"#)
        } catch {
            sendJSON(connection, body: #"{"success": false, "error": "# + jsonEscape(error.localizedDescription) + #"}"#)
        }
    }

    /// 复制关键词到另一个分类
    private static func handleCopyCategory(_ connection: NWConnection, request: String) {
        guard let bodyRange = request.range(of: "\r\n\r\n") else {
            sendJSON(connection, body: #"{"success": false, "error": "No body"}"#)
            return
        }
        let body = String(request[bodyRange.upperBound...])
        guard let data = body.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let from = json["from"] as? String,
              let to = json["to"] as? String else {
            sendJSON(connection, body: #"{"success": false, "error": "Bad request"}"#)
            return
        }
        guard let content = readConfigFile() else {
            sendJSON(connection, body: #"{"success": false, "error": "No config file"}"#)
            return
        }
        var lines = content.components(separatedBy: .newlines)
        var fromLines: [String] = []
        var inFrom = false, inTo = false
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "[website_categories.\(from)]" { inFrom = true; continue }
            if trimmed == "[website_categories.\(to)]" { inTo = true; continue }
            if inFrom {
                if trimmed.hasPrefix("[") { inFrom = false }
                else if !trimmed.isEmpty && !trimmed.hasPrefix("#") { fromLines.append(line) }
            }
            if inTo {
                if trimmed.hasPrefix("[") { inTo = false }
            }
        }
        // 追加到目标分类后
        var insertIndex = -1
        for i in 0..<lines.count {
            let trimmed = lines[i].trimmingCharacters(in: .whitespaces)
            if trimmed == "[website_categories.\(to)]" {
                insertIndex = i + 1
                // 跳过已有的内容行
                var j = i + 1
                while j < lines.count {
                    let t = lines[j].trimmingCharacters(in: .whitespaces)
                    if t.hasPrefix("[") || t.isEmpty { break }
                    j += 1
                }
                insertIndex = j
                break
            }
        }
        if insertIndex < 0 {
            sendJSON(connection, body: #"{"success": false, "error": "Target category not found"}"#)
            return
        }
        // 去重：只复制不重复的
        let existing = Set(lines.filter { l in
            let t = l.trimmingCharacters(in: .whitespaces)
            var found = false
            inTo = true
            // simpler: just check if we're past the target section
            return false
        })
        // 简化实现：直接追加
        var insertLines: [String] = []
        for fl in fromLines {
            let key = fl.components(separatedBy: "=").first?.trimmingCharacters(in: .whitespaces) ?? ""
            if !lines.contains(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix(key + "=") }) {
                insertLines.append(fl)
            }
        }
        guard !insertLines.isEmpty else {
            sendJSON(connection, body: #"{"success": true, "copiedCount": 0, "message": "All keywords already exist in target"}"#)
            return
        }
        lines.insert(contentsOf: insertLines, at: insertIndex)
        let newContent = lines.joined(separator: "\n")
        let configURL = ScreenWatcherService.configURL
        do {
            try newContent.write(to: configURL, atomically: true, encoding: .utf8)
            ScreenWatcherService.shared.loadConfig()
            sendJSON(connection, body: #"{"success": true, "copiedCount": "# + String(insertLines.count) + #"}"#)
        } catch {
            sendJSON(connection, body: #"{"success": false, "error": "# + jsonEscape(error.localizedDescription) + #"}"#)
        }
    }

    // MARK: - Phase 3: 历史记录持久化

    private static let historyFileURL: URL = {
        let dir = ScreenWatcherService.configDir
        return dir.appendingPathComponent("trigger_history.json")
    }()

    private static func handleGetHistory(_ connection: NWConnection) {
        if let data = try? Data(contentsOf: historyFileURL),
           let str = String(data: data, encoding: .utf8) {
            sendJSON(connection, body: #"{"success": true, "history": #(str)}"#)
        } else {
            sendJSON(connection, body: #"{"success": true, "history": []}"#)
        }
    }

    private static func handleSaveHistory(_ connection: NWConnection, request: String) {
        guard let bodyRange = request.range(of: "\r\n\r\n") else {
            sendJSON(connection, body: #"{"success": false, "error": "No body"}"#)
            return
        }
        let body = String(request[bodyRange.upperBound...])
        do {
            try FileManager.default.createDirectory(at: ScreenWatcherService.configDir, withIntermediateDirectories: true)
            try body.write(to: historyFileURL, atomically: true, encoding: .utf8)
            sendJSON(connection, body: #"{"success": true}"#)
        } catch {
            sendJSON(connection, body: #"{"success": false, "error": "# + jsonEscape(error.localizedDescription) + #"}"#)
        }
    }

    // MARK: - Phase 2: 角色设定编辑

    private static let profileOverridesURL: URL = {
        let dir = ScreenWatcherService.configDir
        return dir.appendingPathComponent("ProfileOverrides.json")
    }()

    private static func handleSaveProfile(_ connection: NWConnection, request: String) {
        guard let bodyRange = request.range(of: "\r\n\r\n") else {
            sendJSON(connection, body: #"{"success": false, "error": "No body"}"#)
            return
        }
        let body = String(request[bodyRange.upperBound...])
        guard let data = body.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let charId = json["characterId"] as? String,
              let fields = json["fields"] as? [String: Any] else {
            sendJSON(connection, body: #"{"success": false, "error": "Bad request"}"#)
            return
        }
        do {
            try FileManager.default.createDirectory(at: ScreenWatcherService.configDir, withIntermediateDirectories: true)
            // 读取现有 overrides 或创建新文件
            var overrides: [String: Any] = [:]
            if let existingData = try? Data(contentsOf: profileOverridesURL),
               let existing = try? JSONSerialization.jsonObject(with: existingData) as? [String: Any] {
                overrides = existing
            }
            // 合并该角色的字段
            if var charOverrides = overrides[charId] as? [String: Any] {
                for (k, v) in fields { charOverrides[k] = v }
                overrides[charId] = charOverrides
            } else {
                overrides[charId] = fields
            }
            let newData = try JSONSerialization.data(withJSONObject: overrides, options: [.prettyPrinted, .sortedKeys])
            try newData.write(to: profileOverridesURL)
            sendJSON(connection, body: #"{"success": true}"#)
        } catch {
            sendJSON(connection, body: #"{"success": false, "error": "# + jsonEscape(error.localizedDescription) + #"}"#)
        }
    }

  

    private static var profilesURLForRead: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let userURL = appSupport.appendingPathComponent("MacArkPet/CharacterProfiles.json")
        if FileManager.default.fileExists(atPath: userURL.path) { return userURL }
        return Bundle.main.resourceURL!.appendingPathComponent("CharacterProfiles.json")
    }

    private static var dialoguesURLForRead: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let userURL = appSupport.appendingPathComponent("MacArkPet/Dialogues.json")
        if FileManager.default.fileExists(atPath: userURL.path) { return userURL }
        return Bundle.main.resourceURL!.appendingPathComponent("Dialogues.json")
    }

    private static var profilesURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("MacArkPet")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("CharacterProfiles.json")
    }

    private static var dialoguesURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("MacArkPet")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("Dialogues.json")
    }

    /// POST /api/profiles/delete — 删除角色及其台词
    private static func handleDeleteProfile(_ connection: NWConnection, request: String) {
        guard let bodyRange = request.range(of: "\r\n\r\n") else {
            sendJSON(connection, body: #"{"success": false, "error": "No body"}"#)
            return
        }
        let body = String(request[bodyRange.upperBound...])
        guard let data = body.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let charId = json["characterId"] as? String else {
            sendJSON(connection, body: #"{"success": false, "error": "Bad request"}"#)
            return
        }
        do {
            // 从 CharacterProfiles.json 删除
            var profiles: [String: Any] = [:]
            if let d = try? Data(contentsOf: profilesURL),
               let p = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
                profiles = p
            }
            let existed = profiles[charId] != nil
            profiles.removeValue(forKey: charId)
            let profData = try JSONSerialization.data(withJSONObject: profiles, options: [.prettyPrinted, .sortedKeys])
            try profData.write(to: profilesURL)

            // 从 Dialogues.json 删除
            var dialogues: [String: Any] = [:]
            if let d = try? Data(contentsOf: dialoguesURL),
               let dg = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
                dialogues = dg
            }
            dialogues.removeValue(forKey: charId)
            let dgData = try JSONSerialization.data(withJSONObject: dialogues, options: [.prettyPrinted, .sortedKeys])
            try dgData.write(to: dialoguesURL)

            // 清理 ProfileOverrides.json 中的缓存
            if let od = try? Data(contentsOf: profileOverridesURL),
               var overrides = try? JSONSerialization.jsonObject(with: od) as? [String: Any] {
                overrides.removeValue(forKey: charId)
                if let od2 = try? JSONSerialization.data(withJSONObject: overrides, options: [.prettyPrinted, .sortedKeys]) {
                    try? od2.write(to: profileOverridesURL)
                }
            }

            sendJSON(connection, body: #"{"success": true, "deleted": "# + (existed ? "true" : "false") + #"}"#)
        } catch {
            sendJSON(connection, body: #"{"success": false, "error": "# + jsonEscape(error.localizedDescription) + #"}"#)
        }
    }

    /// POST /api/profiles/create — 新建角色
    private static func handleCreateProfile(_ connection: NWConnection, request: String) {
        guard let bodyRange = request.range(of: "\r\n\r\n") else {
            sendJSON(connection, body: #"{"success": false, "error": "No body"}"#)
            return
        }
        let body = String(request[bodyRange.upperBound...])
        guard let data = body.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let charId = json["characterId"] as? String, !charId.isEmpty else {
            sendJSON(connection, body: #"{"success": false, "error": "Bad request: need characterId"}"#)
            return
        }
        do {
            var profiles: [String: Any] = [:]
            if let d = try? Data(contentsOf: profilesURL),
               let p = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
                profiles = p
            }
            if profiles[charId] != nil {
                sendJSON(connection, body: #"{"success": false, "error": "角色已存在"}"#)
                return
            }
            let profile: [String: Any] = [
                "id": charId,
                "name": json["name"] as? String ?? charId,
                "subtitle": json["subtitle"] as? String ?? "",
                "race": json["race"] as? String ?? "",
                "origin": json["origin"] as? String ?? "",
                "classLabel": json["classLabel"] as? String ?? "",
                "faction": json["faction"] as? String ?? "",
                "personality": json["personality"] as? String ?? "",
                "speechStyle": json["speechStyle"] as? String ?? "",
                "attitudeTowardsDoctor": json["attitudeTowardsDoctor"] as? String ?? "",
                "backgroundSummary": json["backgroundSummary"] as? String ?? "",
                "signatureLines": json["signatureLines"] as? [String] ?? [],
                "screenAttitude": json["screenAttitude"] as? [String: String] ?? [:],
                "birthday": json["birthday"] as? String ?? "",
                "height": json["height"] as? String ?? ""
            ]
            profiles[charId] = profile
            let outData = try JSONSerialization.data(withJSONObject: profiles, options: [.prettyPrinted, .sortedKeys])
            try outData.write(to: profilesURL)
            sendJSON(connection, body: #"{"success": true}"#)
        } catch {
            sendJSON(connection, body: #"{"success": false, "error": "# + jsonEscape(error.localizedDescription) + #"}"#)
        }
    }

    /// POST /api/profiles/save-dialogues — 保存角色台词
    private static func handleSaveDialogues(_ connection: NWConnection, request: String) {
        guard let bodyRange = request.range(of: "\r\n\r\n") else {
            sendJSON(connection, body: #"{"success": false, "error": "No body"}"#)
            return
        }
        let body = String(request[bodyRange.upperBound...])
        guard let data = body.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let charId = json["characterId"] as? String, !charId.isEmpty,
              let dg = json["dialogues"] as? [String: Any] else {
            sendJSON(connection, body: #"{"success": false, "error": "Bad request"}"#)
            return
        }
        do {
            var allDg: [String: Any] = [:]
            if let d = try? Data(contentsOf: dialoguesURL),
               let existing = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
                allDg = existing
            }
            allDg[charId] = dg
            let outData = try JSONSerialization.data(withJSONObject: allDg, options: [.prettyPrinted, .sortedKeys])
            try outData.write(to: dialoguesURL)
            
            // 重新加载 DialogueEngine 以确保桌面悬浮桌宠立即获得最新台词
            DialogueEngine.shared.load()
            DialogueEngine.shared.loadProfiles()
            
            sendJSON(connection, body: #"{"success": true}"#)
        } catch {
            sendJSON(connection, body: #"{"success": false, "error": "# + jsonEscape(error.localizedDescription) + #"}"#)
        }
    }

    // MARK: - 响应发送

    private static func buildHTTPResponse(status: Int, statusText: String, mime: String, body: Data) -> Data {
        let headers = "HTTP/1.1 \(status) \(statusText)\r\n" +
                      "Content-Type: \(mime)\r\n" +
                      "Content-Length: \(body.count)\r\n" +
                      "Cache-Control: no-store, no-cache, must-revalidate, max-age=0\r\n" +
                      "Access-Control-Allow-Origin: *\r\n" +
                      "Connection: close\r\n\r\n"
        var response = headers.data(using: .utf8) ?? Data()
        response.append(body)
        return response
    }

    private static func sendResponse(_ connection: NWConnection, status: Int, body: String, mime: String = "text/plain; charset=utf-8") {
        let statusText = status == 200 ? "OK" : (status == 400 ? "Bad Request" : "Not Found")
        let bodyData = body.data(using: .utf8) ?? Data()
        let response = buildHTTPResponse(status: status, statusText: statusText, mime: mime, body: bodyData)
        connection.send(content: response, completion: .contentProcessed({ _ in
            connection.cancel()
        }))
    }

    private static func sendJSON(_ connection: NWConnection, body: String) {
        sendResponse(connection, status: 200, body: body, mime: "application/json; charset=utf-8")
    }

    private static func sendHTML(_ connection: NWConnection, path: String) {
        let path = path == "/" ? "/index.html" : path
        if let data = Self.shared.webContent[path] {
            let mime = mimeType(for: path)
            let response = buildHTTPResponse(status: 200, statusText: "OK", mime: mime, body: data)
            connection.send(content: response, completion: .contentProcessed({ _ in
                connection.cancel()
            }))
        } else {
            sendResponse(connection, status: 404, body: "Not Found: \(path)")
        }
    }

    // MARK: - 工具方法

    private static func mimeType(for path: String) -> String {
        if path.hasSuffix(".html") { return "text/html" }
        if path.hasSuffix(".css")  { return "text/css" }
        if path.hasSuffix(".js")   { return "application/javascript" }
        if path.hasSuffix(".png")  { return "image/png" }
        if path.hasSuffix(".svg")  { return "image/svg+xml" }
        if path.hasSuffix(".ico")  { return "image/x-icon" }
        return "text/plain"
    }

    private static func jsonEscape(_ s: String) -> String {
        let escaped = s
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\t", with: "\\t")
        return "\"\(escaped)\""
    }

    /// 读取配置文件（跳过空文件）
    private static func readConfigFile() -> String? {
        // 优先读用户配置
        if FileManager.default.fileExists(atPath: ScreenWatcherService.configURL.path) {
            if let content = try? String(contentsOf: ScreenWatcherService.configURL, encoding: .utf8),
               !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return content
            }
        }
        // 兜底读 bundled 配置
        if let bundledURL = resourceDir()?.appendingPathComponent("ScreenTriggers.toml"),
           FileManager.default.fileExists(atPath: bundledURL.path) {
            return try? String(contentsOf: bundledURL, encoding: .utf8)
        }
        return nil
    }

    /// 解析配置预览
    private static func parseConfigPreview() -> String {
        guard let content = readConfigFile() else { return "{}" }
        // 返回结构：{ "分类名": [{"key": "...", "values": ["...", "..."]}, ...] }
        var categories: [String: [[String: Any]]] = [:]
        var currentCategory: String?

        for line in content.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") && trimmed.hasSuffix("]") {
                let inner = String(trimmed.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
                if inner.hasPrefix("website_categories.") {
                    currentCategory = String(inner.dropFirst("website_categories.".count))
                    categories[currentCategory!] = []
                } else {
                    currentCategory = nil
                }
                continue
            }
            guard let cat = currentCategory else { continue }
            if let eqRange = trimmed.range(of: "=") {
                let key = String(trimmed[..<eqRange.lowerBound]).trimmingCharacters(in: .whitespaces)
                guard !key.isEmpty, !key.hasPrefix("#") else { continue }
                // 解析 values 数组：["val1", "val2"]
                let valStr = String(trimmed[eqRange.upperBound...]).trimmingCharacters(in: .whitespaces)
                var values: [String] = []
                // 简单解析方括号内的引号字符串
                var working = valStr
                if working.hasPrefix("[") { working = String(working.dropFirst()) }
                if working.hasSuffix("]") { working = String(working.dropLast()) }
                // 按逗号分割，提取每个引号内的内容
                for rawVal in working.components(separatedBy: ",") {
                    let v = rawVal.trimmingCharacters(in: .whitespaces)
                        .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                    if !v.isEmpty {
                        values.append(v)
                    }
                }
                categories[cat, default: []].append(["key": key, "values": values])
            }
        }

        if let data = try? JSONSerialization.data(withJSONObject: categories, options: [.sortedKeys]),
           let str = String(data: data, encoding: .utf8) {
            return str
        }
        return "{}"
    }

    /// 列出角色简介
    /// 获取资源目录
    private static func resourceDir() -> URL? {
        return Bundle.main.resourceURL
    }

    private static func listProfiles() -> String {
        var result: [[String: Any]] = []
        let _ = DialogueEngine.shared
        
        let profileURL = profilesURLForRead
        guard let data = try? Data(contentsOf: profileURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return "[]"
        }
        for (id, profile) in json {
            if let dict = profile as? [String: Any] {
                result.append([
                    "id": id,
                    "name": dict["name"] as? String ?? id,
                    "subtitle": dict["subtitle"] as? String ?? "",
                    "classLabel": dict["classLabel"] as? String ?? "",
                    "faction": dict["faction"] as? String ?? "",
                    "race": dict["race"] as? String ?? "",
                    "personality": (dict["personality"] as? String ?? "").prefix(80)
                ])
            }
        }

        if let data = try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]),
           let str = String(data: data, encoding: .utf8) {
            return str
        }
        return "[]"
    }

    /// 返回完整角色详情（含台词数据）
    private static func listDetailedProfiles() -> String {
        let profileURL = profilesURLForRead
        guard let profileData = try? Data(contentsOf: profileURL),
              let profiles = try? JSONSerialization.jsonObject(with: profileData) as? [String: Any] else {
            return "[]"
        }

        // 读取台词数据
        var dialogues: [String: Any] = [:]
        if let dialogData = try? Data(contentsOf: dialoguesURLForRead),
           let json = try? JSONSerialization.jsonObject(with: dialogData) as? [String: Any] {
            dialogues = json
        }

        var result: [[String: Any]] = []
        for (id, profile) in profiles {
            guard var dict = profile as? [String: Any] else { continue }
            dict["id"] = id
            // 合并该角色的台词
            if let lines = dialogues[id] {
                dict["dialogues"] = lines
            } else {
                dict["dialogues"] = []
            }
            result.append(dict)
        }

        if let data = try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]),
           let str = String(data: data, encoding: .utf8) {
            return str
        }
        return "[]"
    }

    // MARK: - 🖥️ 桌宠管理 API

    /// 返回当前活跃的桌宠列表
    private static func listActivePets() -> String {
        let app = MacArkPetApp.shared
        var result: [[String: Any]] = []
        for (i, ctrl) in app.petControllers.enumerated() {
            let m = ctrl.model
            result.append([
                "id": i,
                "name": m.displayName,
                "characterId": m.characterId,
                "mood": "\(m.mood)",
                "affection": m.affection,
                "stamina": m.stamina,
                "moodLevel": m.moodLevel,
                "coins": m.coins,
                "dailyStreak": m.dailyStreak,
                "isClickThrough": m.isClickThrough,
                "isAlwaysOnTop": m.isAlwaysOnTop,
                "isSpeaking": m.isSpeaking,
                "dialogueText": m.dialogueText
            ])
        }
        if let data = try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]),
           let str = String(data: data, encoding: .utf8) {
            return str
        }
        return "[]"
    }

    /// 处理桌宠命令
    private static func handlePetCommand(_ connection: NWConnection, request: String) {
        guard let bodyRange = request.range(of: "\r\n\r\n") else {
            sendJSON(connection, body: #"{"success": false, "error": "No body"}"#)
            return
        }
        let body = String(request[bodyRange.upperBound...])
        guard let data = body.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let command = json["command"] as? String else {
            sendJSON(connection, body: #"{"success": false, "error": "Bad request"}"#)
            return
        }

        let app = MacArkPetApp.shared
        let petId = json["id"] as? Int
        var success = false

        if let pid = petId, pid >= 0, pid < app.petControllers.count {
            let ctrl = app.petControllers[pid]
            switch command {
            case "poke": ctrl.model.poke(); success = true
            case "special": ctrl.model.specialAction(); success = true
            case "rest": ctrl.model.rest(); success = true
            case "sleep": ctrl.model.sleep(); success = true
            case "feed", "buy_food":
                success = ctrl.model.feed()
                if !success {
                    sendJSON(connection, body: #"{"success": false, "error": "金币不足"}"#)
                    return
                }
            case "resetPosition": ctrl.resetPosition(); success = true
            case "close":
                ctrl.close()
                app.petControllers.remove(at: pid)
                if app.petControllers.isEmpty {
                    app.isClickThrough = false
                    app.isAlwaysOnTop = true
                }
                app.refreshMenus()
                success = true
            default: break
            }
        } else if command == "clickthrough" || command == "ontop" {
            let enabled = json["enabled"] as? Bool ?? false
            if command == "clickthrough" {
                app.isClickThrough = enabled
                for ctrl in app.petControllers { ctrl.setClickThrough(enabled) }
            } else {
                app.isAlwaysOnTop = enabled
                for ctrl in app.petControllers { ctrl.setAlwaysOnTop(enabled) }
            }
            success = true
        }

        app.refreshMenus()
        sendJSON(connection, body: success ? #"{"success": true}"# : #"{"success": false, "error": "Invalid command/pet"}"#)
    }

    /// 返回全局设置
    private static func getSettings() -> String {
        let app = MacArkPetApp.shared
        let dict: [String: Any] = [
            "isClickThrough": app.isClickThrough,
            "isAlwaysOnTop": app.isAlwaysOnTop,
            "isVoiceEnabled": app.isVoiceEnabled
        ]
        if let data = try? JSONSerialization.data(withJSONObject: dict),
           let str = String(data: data, encoding: .utf8) {
            return str
        }
        return "{}"
    }

    /// GET /api/pets/available — 列出可启动的已安装角色
    private static func handleAvailablePets(_ connection: NWConnection) {
        let app = MacArkPetApp.shared
        let store = app.store
        let installed = store.models.filter { $0.isInstalled }
        var result: [[String: Any]] = []
        for item in installed {
            result.append([
                "id": item.id,
                "title": item.title,
                "type": item.type,
                "hasSpine": item.hasSpineAssets
            ])
        }
        if let data = try? JSONSerialization.data(withJSONObject: result),
           let str = String(data: data, encoding: .utf8) {
            sendJSON(connection, body: str)
        } else {
            sendJSON(connection, body: "[]")
        }
    }

    /// POST /api/pets/launch — 启动指定角色的桌宠
    private static func handlePetLaunch(_ connection: NWConnection, request: String) {
        guard let bodyRange = request.range(of: "\r\n\r\n") else {
            sendJSON(connection, body: #"{"success": false, "error": "No body"}"#)
            return
        }
        let body = String(request[bodyRange.upperBound...])
        guard let data = body.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let modelId = json["modelId"] as? String else {
            sendJSON(connection, body: #"{"success": false, "error": "Bad request"}"#)
            return
        }

        let app = MacArkPetApp.shared
        let store = app.store
        guard let item = store.models.first(where: { $0.id == modelId && $0.isInstalled }) else {
            sendJSON(connection, body: #"{"success": false, "error": "Model not found or not installed"}"#)
            return
        }

        if item.hasSpineAssets {
            app.launchPet(model: item)
            sendJSON(connection, body: #"{"success": true}"#)
        } else {
            sendJSON(connection, body: #"{"success": false, "error": "Missing Spine assets"}"#)
        }
    }

    /// 处理全局设置更新
    private static func handlePutSettings(_ connection: NWConnection, request: String) {
        guard let bodyRange = request.range(of: "\r\n\r\n") else {
            sendJSON(connection, body: #"{"success": false, "error": "No body"}"#)
            return
        }
        let body = String(request[bodyRange.upperBound...])
        guard let data = body.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            sendJSON(connection, body: #"{"success": false, "error": "Bad JSON"}"#)
            return
        }

        let app = MacArkPetApp.shared

        if let v = json["isVoiceEnabled"] as? Bool {
            app.isVoiceEnabled = v
            CharacterVoiceService.isEnabled = v
        }
        if let v = json["isClickThrough"] as? Bool {
            app.isClickThrough = v
            for ctrl in app.petControllers { ctrl.setClickThrough(v) }
        }
        if let v = json["isAlwaysOnTop"] as? Bool {
            app.isAlwaysOnTop = v
            for ctrl in app.petControllers { ctrl.setAlwaysOnTop(v) }
        }

        app.refreshMenus()
        sendJSON(connection, body: #"{"success": true}"#)
    }

    // MARK: - 🤖 AI 配置管理

    private static let aiConfigURL: URL = {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".config/macarkpet/ai.json")
    }()

    /// GET /api/ai-config — 获取 AI 配置（不暴露完整 API key）
    private static func handleGetAIConfig(_ connection: NWConnection) {
        var result: [String: Any] = [
            "configured": false,
            "api_key_masked": "",
            "api_base": "",
            "model": ""
        ]
        if let data = try? Data(contentsOf: aiConfigURL),
           let config = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            result["configured"] = true
            let key = config["api_key"] as? String ?? ""
            result["api_key_masked"] = key.isEmpty ? "" : String(key.prefix(8)) + "..." + String(key.suffix(4))
            result["api_base"] = config["api_base"] as? String ?? ""
            result["model"] = config["model"] as? String ?? ""
        }
        if let data = try? JSONSerialization.data(withJSONObject: result),
           let str = String(data: data, encoding: .utf8) {
            sendJSON(connection, body: str)
        } else {
            sendJSON(connection, body: #"{"configured": false}"#)
        }
    }

    /// PUT /api/ai-config — 保存 AI 配置
    private static func handlePutAIConfig(_ connection: NWConnection, request: String) {
        guard let bodyRange = request.range(of: "\r\n\r\n") else {
            sendJSON(connection, body: #"{"success": false, "error": "No body"}"#)
            return
        }
        let body = String(request[bodyRange.upperBound...])
        guard let data = body.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            sendJSON(connection, body: #"{"success": false, "error": "Bad JSON"}"#)
            return
        }

        // 合并到现有配置
        var config: [String: Any] = [:]
        if let existingData = try? Data(contentsOf: aiConfigURL),
           let existing = try? JSONSerialization.jsonObject(with: existingData) as? [String: Any] {
            config = existing
        }
        if let v = json["api_key"] as? String, !v.isEmpty { config["api_key"] = v }
        if let v = json["api_base"] as? String, !v.isEmpty { config["api_base"] = v }
        if let v = json["model"] as? String, !v.isEmpty { config["model"] = v }

        do {
            try FileManager.default.createDirectory(at: aiConfigURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let outData = try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys])
            try outData.write(to: aiConfigURL)
            sendJSON(connection, body: #"{"success": true}"#)
        } catch {
            sendJSON(connection, body: #"{"success": false, "error": "# + jsonEscape(error.localizedDescription) + #"}"#)
        }
    }

    // MARK: - 📋 角色数据审查

    private static func runDataAudit() -> String {
        guard let baseDir = resourceDir() else { return #"{"error": "no resource dir"}"# }

        let profileURL = baseDir.appendingPathComponent("CharacterProfiles.json")
        let dialogURL = baseDir.appendingPathComponent("Dialogues.json")

        guard let pd = try? Data(contentsOf: profileURL),
              let profiles = try? JSONSerialization.jsonObject(with: pd) as? [String: Any],
              let dd = try? Data(contentsOf: dialogURL),
              let dialogs = try? JSONSerialization.jsonObject(with: dd) as? [String: Any] else {
            return #"{"error": "cannot read data files"}"#
        }

        var errors: [[String: Any]] = []
        var warnings: [[String: Any]] = []
        var infos: [[String: Any]] = []

        let screenSits = ["coding","gaming","social","video","lateNight","idleLong","readingNews","shopping","aiChat"]

        for (id, profile) in profiles.sorted(by: { $0.key < $1.key }) {
            guard let d = profile as? [String: Any] else { continue }
            let name = d["name"] as? String ?? id

            // 跨文件检查
            if dialogs[id] == nil {
                errors.append([
                    "type": "missing_dialogues",
                    "id": id, "name": name,
                    "message": "\(name) 有角色资料但 Dialogues.json 中完全缺失台词"
                ])
            }

            // 必需字段
            let requiredFields = ["name","subtitle","race","origin","classLabel","faction","personality","speechStyle","attitudeTowardsDoctor","backgroundSummary","signatureLines","screenAttitude","birthday","height"]
            for field in requiredFields {
                if d[field] == nil {
                    errors.append(["type": "missing_field", "id": id, "name": name, "field": field, "message": "\(name): 缺少 '\(field)'"])
                }
            }

            // screenAttitude 子字段
            if let att = d["screenAttitude"] as? [String: Any] {
                for sit in screenSits {
                    if att[sit] == nil {
                        warnings.append(["type": "missing_sit", "id": id, "name": name, "situation": sit, "message": "\(name): screenAttitude 缺少 '\(sit)'"])
                    } else if let s = att[sit] as? String, s.trimmingCharacters(in: .whitespaces).isEmpty {
                        errors.append(["type": "empty_sit", "id": id, "name": name, "situation": sit, "message": "\(name): screenAttitude.\(sit) 为空"])
                    } else if let s = att[sit] as? String, s.count < 10 {
                        warnings.append(["type": "short_sit", "id": id, "name": name, "situation": sit, "detail": att[sit] as? String ?? "", "message": "\(name): screenAttitude.\(sit) 内容过短 (\(s.count)字)"])
                    }
                }
            }

            // 字段长度检查
            let lengthChecks: [(String, String, Int)] = [("personality","性格描述",30),("speechStyle","语言风格",10),("attitudeTowardsDoctor","对博士态度",10),("backgroundSummary","背景故事",50)]
            for (field, label, minLen) in lengthChecks {
                if let s = d[field] as? String, s.count < minLen {
                    warnings.append(["type": "short_field", "id": id, "name": name, "field": field, "detail": s, "message": "\(name): \(label) 过短 (\(s.count)字 < \(minLen)字)"])
                }
            }

            // 截断检查
            for field in ["personality","speechStyle","backgroundSummary","attitudeTowardsDoctor"] {
                if let s = d[field] as? String, s.hasSuffix("...") || s.hasSuffix("…") {
                    warnings.append(["type": "truncated", "id": id, "name": name, "field": field, "message": "\(name): \(field) 可能被截断"])
                }
            }

            // signatureLines
            if let sigs = d["signatureLines"] as? [String] {
                for sig in sigs where sig.count < 5 {
                    warnings.append(["type": "short_sig", "id": id, "name": name, "detail": sig, "message": "\(name): 经典台词过短 \(sig)"])
                }
            }
        }

        // 对话检查
        for (id, dialog) in dialogs {
            guard let situations = dialog as? [String: Any] else { continue }
            let name = (profiles[id] as? [String: Any])?["name"] as? String ?? id
            for (sit, entries) in situations {
                guard let entryList = entries as? [[String: Any]] else { continue }
                for entry in entryList {
                    if let lines = entry["lines"] as? [String] {
                        for line in lines where line.count < 3 {
                            warnings.append(["type": "short_line", "id": id, "name": name, "situation": sit, "detail": line, "message": "\(name): 对话 \(sit) 中台词过短 \(line)"])
                        }
                    }
                }
            }
        }

        let result: [String: Any] = [
            "errors": errors,
            "warnings": warnings,
            "infos": infos,
            "totalProfiles": profiles.count,
            "totalDialogs": dialogs.count,
            "errorCount": errors.count,
            "warningCount": warnings.count
        ]

        if let data = try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]),
           let str = String(data: data, encoding: .utf8) {
            return str
        }
        return #"{"error": "serialization failed"}"#
    }

    /// 获取当前屏幕上下文
    private static func getCurrentContext() -> String {
        guard let context = ScreenWatcherService.shared.currentContext else {
            return #"{"available": false, "message": "等待首次检测..."}"#
        }

        let dict: [String: Any] = [
            "available": true,
            "appName": context.appName,
            "bundleID": context.bundleID,
            "windowTitle": context.windowTitle,
            "category": context.category,
            "dayPhase": context.dayPhase.rawValue,
            "isDeepNight": context.isDeepNight,
            "isIdleLong": context.isIdleLong,
            "summary": context.summary
        ]

        if let data = try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys]),
           let str = String(data: data, encoding: .utf8) {
            return str
        }
        return #"{"available": false}"#
    }

    // MARK: - 加载 Web 内容


    // MARK: - 🔌 SSE 实时推送

    /// GET /api/context/stream — SSE 实时推送屏幕上下文变化
    /// 替代前端 3 秒轮询，连接保持打开，上下文变化时自动推送
    private static func handleContextStream(_ connection: NWConnection) {
        // 发送 SSE 响应头
        let headers = "HTTP/1.1 200 OK\r\n"
            + "Content-Type: text/event-stream\r\n"
            + "Cache-Control: no-cache\r\n"
            + "Connection: keep-alive\r\n"
            + "Access-Control-Allow-Origin: *\r\n"
            + "\r\n"

        guard let headerData = headers.data(using: .utf8) else {
            connection.cancel()
            return
        }
        connection.send(content: headerData, completion: .contentProcessed({ _ in }))

        // 订阅上下文变化
        let watcher = ScreenWatcherService.shared
        var cancellable: AnyCancellable?

        // 先发送当前状态
        if let firstContext = watcher.currentContext {
            let dict: [String: Any] = [
                "available": true,
                "appName": firstContext.appName,
                "bundleID": firstContext.bundleID,
                "windowTitle": firstContext.windowTitle,
                "category": firstContext.category,
                "dayPhase": firstContext.dayPhase.rawValue,
                "isDeepNight": firstContext.isDeepNight,
                "isIdleLong": firstContext.isIdleLong,
                "summary": firstContext.summary
            ]
            if let firstData = try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys]),
               let firstStr = String(data: firstData, encoding: .utf8) {
                let event = "data: \(firstStr)\n\n"
                if let eventData = event.data(using: .utf8) {
                    connection.send(content: eventData, completion: .contentProcessed({ _ in }))
                }
            }
        }

        // 订阅后续变化
        cancellable = watcher.contextDidChange
            .receive(on: RunLoop.main)
            .sink { context in
                let dict: [String: Any] = [
                    "available": true,
                    "appName": context.appName,
                    "bundleID": context.bundleID,
                    "windowTitle": context.windowTitle,
                    "category": context.category,
                    "dayPhase": context.dayPhase.rawValue,
                    "isDeepNight": context.isDeepNight,
                    "isIdleLong": context.isIdleLong,
                    "summary": context.summary
                ]
                if let data = try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys]),
                   let str = String(data: data, encoding: .utf8) {
                    let event = "data: \(str)\n\n"
                    if let eventData = event.data(using: .utf8) {
                        connection.send(content: eventData, completion: .contentProcessed({ _ in }))
                    }
                }
            }

        // 连接断开时清理
        connection.stateUpdateHandler = { state in
            if case .failed = state {
                cancellable?.cancel()
            }
            if case .cancelled = state {
                cancellable?.cancel()
            }
        }
        // 保持连接不 cancel — SSE 就是长期连接
    }

    /// 从 bundle 加载 web 界面文件
    private func loadWebContent() {
        guard let resourceDir = Bundle.main.resourceURL?.appendingPathComponent("web-editor") else { return }

        let files = ["/index.html", "/style.css", "/app.js"]
        for file in files {
            let fileURL = resourceDir.appendingPathComponent(String(file.dropFirst()))
            if let data = try? Data(contentsOf: fileURL) {
                webContent[file] = data
            }
        }
    }

    // MARK: - 智能体 API

    /// POST /api/agent/generate — 调用 Python 智能体生成角色数据
    private static func handleAgentGenerate(_ connection: NWConnection, request: String) {
        guard let bodyRange = request.range(of: "\r\n\r\n") else {
            sendJSON(connection, body: #"{"success": false, "error": "No body"}"#)
            return
        }
        let body = String(request[bodyRange.upperBound...])
        guard let data = body.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let name = json["name"] as? String, !name.isEmpty else {
            sendJSON(connection, body: #"{"success": false, "error": "Missing name"}"#)
            return
        }

        // 获取资源目录
        guard let resDir = resourceDir() else {
            sendJSON(connection, body: #"{"success": false, "error": "Resource dir not found"}"#)
            return
        }
        let agentPath = resDir.appendingPathComponent("agent/character_agent.py").path
        let profilesPath = resDir.appendingPathComponent("CharacterProfiles.json").path
        let dialoguesPath = resDir.appendingPathComponent("Dialogues.json").path

        let useAI = json["use_ai"] as? Bool ?? true

        let process = Process()
        var env = ProcessInfo.processInfo.environment
        let customPath = "/opt/homebrew/bin:/usr/local/bin"
        if let existingPath = env["PATH"] {
            env["PATH"] = customPath + ":" + existingPath
        } else {
            env["PATH"] = customPath
        }
        process.environment = env
        
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        var args = ["python3", agentPath]
        if !useAI {
            args.append("--no-ai")
        }
        args.append(name)
        process.arguments = args

        let pipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = pipe
        process.standardError = errPipe

        do {
            try process.run()
            process.waitUntilExit()

            let outputData = pipe.fileHandleForReading.readDataToEndOfFile()
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            let outputStr = String(data: outputData, encoding: .utf8) ?? ""
            let errStr = String(data: errData, encoding: .utf8) ?? ""

            // 解析 JSON（取第一段 JSON 对象，跳过结尾日志行）
            if let jsonStart = outputStr.firstIndex(of: "{"),
               let jsonEnd = outputStr.lastIndex(of: "}") {
                let jsonStr = String(outputStr[jsonStart...jsonEnd])
                sendJSON(connection, body: jsonStr)
            } else {
                let fullOutput = (outputStr + "\n" + errStr).trimmingCharacters(in: .whitespacesAndNewlines)
                let msg = fullOutput.replacingOccurrences(of: "\\", with: "\\\\")
                                    .replacingOccurrences(of: "\"", with: "\\\"")
                                    .replacingOccurrences(of: "\n", with: "\\n")
                                    .replacingOccurrences(of: "\r", with: "")
                let finalMsg = msg.isEmpty ? "Unknown Python execution error" : msg
                sendJSON(connection, body: #"{"success": false, "error": "\#(finalMsg)"}"#)
            }
        } catch {
            sendJSON(connection, body: #"{"success": false, "error": "Process error"}"#)
        }
    }

    /// POST /api/agent/save — 保存确认的角色数据
    private static func handleAgentSave(_ connection: NWConnection, request: String) {
        guard let bodyRange = request.range(of: "\r\n\r\n") else {
            sendJSON(connection, body: #"{"success": false, "error": "No body"}"#)
            return
        }
        let body = String(request[bodyRange.upperBound...])
        guard let data = body.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let profile = json["profile"] as? [String: Any],
              let dialogues = json["dialogues"] as? [String: Any] else {
            sendJSON(connection, body: #"{"success": false, "error": "Invalid data"}"#)
            return
        }

        guard let resDir = resourceDir() else {
            sendJSON(connection, body: #"{"success": false, "error": "Resource dir not found"}"#)
            return
        }

        let profilesPath = resDir.appendingPathComponent("CharacterProfiles.json")
        let dialoguesPath = resDir.appendingPathComponent("Dialogues.json")
        var results: [String: Any] = [:]

        // 保存 profile
        if var existing = try? JSONSerialization.jsonObject(with: Data(contentsOf: profilesPath)) as? [String: Any] {
            if let id = profile["id"] as? String {
                existing[id] = profile
                if let outData = try? JSONSerialization.data(withJSONObject: existing, options: [.prettyPrinted, .sortedKeys]) {
                    try? outData.write(to: profilesPath)
                    results["profile_saved"] = true
                }
            }
        }

        // 保存 dialogues
        if var existing = try? JSONSerialization.jsonObject(with: Data(contentsOf: dialoguesPath)) as? [String: Any] {
            if let id = dialogues["char_id"] as? String {
                existing[id] = dialogues["dialogues"]
            } else if let pId = profile["id"] as? String {
                existing[pId] = dialogues["dialogues"] ?? dialogues
            }
            if let outData = try? JSONSerialization.data(withJSONObject: existing, options: [.prettyPrinted, .sortedKeys]) {
                try? outData.write(to: dialoguesPath)
                results["dialogues_saved"] = true
            }
        }

        // 重新加载 DialogueEngine 以确保桌面悬浮桌宠立即获得最新台词
        DialogueEngine.shared.load()
        DialogueEngine.shared.loadProfiles()

        let ok = (results["profile_saved"] as? Bool == true) || (results["dialogues_saved"] as? Bool == true)
        let resp: String
        if ok {
            resp = #"{"success": true, "message": "已保存"}"#
        } else {
            resp = #"{"success": false, "error": "File error"}"#
        }
        sendJSON(connection, body: resp)
    }
}
