// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 MacArkPet contributors

import Foundation

/// 向 aichach (茶茶AI) 上报当前桌宠角色。
/// 通过 UserDefaults 配置 URL 和管理员密钥。
final class PetReporter {
    static let shared = PetReporter()

    private enum ConfigKey {
        static let serverURL = "petReporterServerURL"
        static let adminKey = "petReporterAdminKey"
        static let enabled = "petReporterEnabled"
    }

    /// 服务器地址，如 "http://localhost:8000"
    var serverURL: String {
        get { UserDefaults.standard.string(forKey: ConfigKey.serverURL) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: ConfigKey.serverURL) }
    }

    /// 管理员密钥
    var adminKey: String {
        get { UserDefaults.standard.string(forKey: ConfigKey.adminKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: ConfigKey.adminKey) }
    }

    /// 是否启用上报
    var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: ConfigKey.enabled) }
        set { UserDefaults.standard.set(newValue, forKey: ConfigKey.enabled) }
    }

    private init() {}

    /// 上报当前角色到服务器
    /// - Parameters:
    ///   - characterId: 角色 ID (如 "002_amiya")
    ///   - characterName: 角色显示名 (如 "阿米娅")
    func report(characterId: String, characterName: String) {
        guard isEnabled,
              !serverURL.isEmpty,
              !adminKey.isEmpty,
              !characterId.isEmpty else { return }

        let urlString = serverURL.hasSuffix("/")
            ? "\(serverURL)api/pet/current_character"
            : "\(serverURL)/api/pet/current_character"

        guard let url = URL(string: urlString) else {
            print("[PetReporter] 无效的服务器 URL: \(serverURL)")
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: String] = [
            "character_id": characterId,
            "character_name": characterName,
            "admin_key": adminKey,
        ]

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        } catch {
            print("[PetReporter] JSON 编码失败: \(error)")
            return
        }

        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                print("[PetReporter] 上报失败: \(error.localizedDescription)")
                return
            }

            if let httpResponse = response as? HTTPURLResponse {
                if httpResponse.statusCode == 200 {
                    print("[PetReporter] 上报成功: \(characterId) (\(characterName))")
                } else {
                    let body = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                    print("[PetReporter] 上报返回 \(httpResponse.statusCode): \(body)")
                }
            }
        }

        task.resume()
    }
}
