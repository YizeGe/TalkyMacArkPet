// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 MacArkPet contributors

import Foundation

// MARK: - DeepSeek API 服务

enum DeepSeekError: Error, LocalizedError {
    case notConfigured
    case networkError(Error)
    case parseError
    case emptyResponse

    var errorDescription: String? {
        switch self {
        case .notConfigured: return "DeepSeek API Key 未配置"
        case .networkError(let e): return "网络错误: \(e.localizedDescription)"
        case .parseError: return "响应解析失败"
        case .emptyResponse: return "空响应"
        }
    }
}

@MainActor
final class DeepSeekService {
    static let shared = DeepSeekService()
    private init() {}

    private var aiConfigURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/macarkpet/ai.json")
    }

    private func getAIConfig() -> [String: Any]? {
        guard let data = try? Data(contentsOf: aiConfigURL) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    var apiKey: String {
        getAIConfig()?["api_key"] as? String ?? ""
    }

    var baseURL: String {
        let base = getAIConfig()?["api_base"] as? String ?? ""
        return base.isEmpty ? "https://api.deepseek.com/v1/chat/completions" : base
    }

    var modelName: String {
        let model = getAIConfig()?["model"] as? String ?? ""
        return model.isEmpty ? "deepseek-chat" : model
    }

    var isConfigured: Bool { !apiKey.isEmpty }

    // MARK: - 日记生成

    func generateDiary(
        characterProfile: CharacterProfile,
        activity: DailyActivity
    ) async throws -> String {
        let activityText = ActivityTracker.shared.todaySummaryText()
        let prompt = """
        你是「\(characterProfile.name)」，来自游戏《明日方舟》。
        性格：\(characterProfile.personality)
        说话风格：\(characterProfile.speechStyle)
        对博士的态度：\(characterProfile.attitudeTowardsDoctor)

        你是博士桌面上的桌宠伙伴，今天观察到博士的活动：
        \(activityText)

        请以你的口吻写一段简短的日记（50-100字），记录你对今天的观察和感受。
        要求：
        - 直接说话，不要用括号描述动作
        - 符合角色性格和说话风格
        - 可以对博士的行为做出评价或关心
        - 只输出日记内容，不要加标题或前缀
        """
        return try await callAPI(prompt: prompt)
    }

    // MARK: - 每日总结

    func generateSummary(
        characterProfile: CharacterProfile,
        activity: DailyActivity
    ) async throws -> String {
        let activityText = ActivityTracker.shared.todaySummaryText()
        let prompt = """
        你是「\(characterProfile.name)」，来自游戏《明日方舟》。
        说话风格：\(characterProfile.speechStyle)

        总结博士今天的一天（用你的语气，40-80字）：
        \(activityText)

        要求：简短、有温度、像朋友之间说话。直接说话，不加标题。
        """
        return try await callAPI(prompt: prompt, maxTokens: 150)
    }

    // MARK: - 好感度里程碑对话

    func generateMilestoneDialogue(
        characterProfile: CharacterProfile,
        milestone: Int
    ) async throws -> String {
        let milestoneDesc: String
        switch milestone {
        case 25: milestoneDesc = "初步信任，开始熟悉"
        case 50: milestoneDesc = "建立了深厚的友谊"
        case 75: milestoneDesc = "非常亲密，特殊的存在"
        case 100: milestoneDesc = "最高好感度，无条件信任"
        default: milestoneDesc = "好感度提升"
        }

        let prompt = """
        你是「\(characterProfile.name)」，来自游戏《明日方舟》。
        性格：\(characterProfile.personality)
        说话风格：\(characterProfile.speechStyle)
        对博士的态度：\(characterProfile.attitudeTowardsDoctor)

        你对博士的好感度达到了 \(milestone)/100（\(milestoneDesc)）。
        请以你的口吻说一句符合这个好感度阶段的话（30-60字）。
        要求：直接说话，不加标题，符合角色性格。
        """
        return try await callAPI(prompt: prompt, maxTokens: 100)
    }

    // MARK: - 节日对话

    func generateHolidayDialogue(
        characterProfile: CharacterProfile,
        holiday: String,
        holidayName: String
    ) async throws -> String {
        let prompt = """
        你是「\(characterProfile.name)」，来自游戏《明日方舟》。
        说话风格：\(characterProfile.speechStyle)
        对博士的态度：\(characterProfile.attitudeTowardsDoctor)

        今天是\(holidayName)。请以你的口吻对博士说一句节日祝福或感想（30-60字）。
        要求：直接说话，不加标题，符合角色性格。
        """
        return try await callAPI(prompt: prompt, maxTokens: 100)
    }

    // MARK: - API 调用

    private func callAPI(prompt: String, maxTokens: Int = 200) async throws -> String {
        guard isConfigured else { throw DeepSeekError.notConfigured }

        guard let url = URL(string: baseURL) else {
            throw DeepSeekError.parseError
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 30

        let body: [String: Any] = [
            "model": modelName,
            "messages": [
                ["role": "user", "content": prompt]
            ],
            "temperature": 0.8,
            "max_tokens": maxTokens
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        NSLog("[DeepSeek] 🚀 Calling API (model=\(modelName), tokens=\(maxTokens))")

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            NSLog("[DeepSeek] ❌ Network error: \(error)")
            throw DeepSeekError.networkError(error)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw DeepSeekError.parseError
        }

        if httpResponse.statusCode != 200 {
            let body = String(data: data, encoding: .utf8) ?? "unknown"
            NSLog("[DeepSeek] ❌ HTTP \(httpResponse.statusCode): \(body.prefix(200))")
            throw DeepSeekError.parseError
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let first = choices.first,
              let message = first["message"] as? [String: Any],
              let content = message["content"] as? String else {
            NSLog("[DeepSeek] ❌ Failed to parse response")
            throw DeepSeekError.parseError
        }

        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw DeepSeekError.emptyResponse
        }

        NSLog("[DeepSeek] ✅ Got response: \(trimmed.prefix(50))...")
        return trimmed
    }
}
