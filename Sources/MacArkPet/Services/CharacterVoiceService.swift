// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 MacArkPet contributors

import Foundation

struct CharacterVoiceSet: Decodable {
    let name: String
    let subtitle: String
    let lines: [String: [String]]
}

typealias CharacterVoiceDatabase = [String: CharacterVoiceSet]

final class CharacterVoiceService {
    static let shared = CharacterVoiceService()
    static var isEnabled = true
    static var enabledCharacters: Set<String>? = nil // nil = all enabled, non-nil = only these IDs

    private var database: CharacterVoiceDatabase?
    private var recentLines: [String: Set<String>] = [:] // track recent lines per character to avoid repeats

    private init() {}

    func load() {
        let candidates = [
            Bundle.main.resourceURL?.appendingPathComponent("CharacterVoiceLines.json"),
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Resources/CharacterVoiceLines.json"),
            URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Resources/CharacterVoiceLines.json")
        ].compactMap { $0 }

        for url in candidates {
            guard FileManager.default.fileExists(atPath: url.path),
                  let data = try? Data(contentsOf: url),
                  let db = try? JSONDecoder().decode(CharacterVoiceDatabase.self, from: data) else {
                continue
            }
            database = db
            return
        }

        NSLog("CharacterVoiceService: no voice lines config found")
        database = [:]
    }

    func line(for characterId: String, moodKind: String) -> String? {
        guard Self.isEnabled else { return nil }
        if let allowed = Self.enabledCharacters, !allowed.contains(characterId) { return nil }
        guard let db = database else { return nil }

        let charSet = db[characterId] ?? closestMatch(in: db, for: characterId) ?? db["_default"]
        guard let charSet else { return nil }

        let isAffectionate = moodKind.hasPrefix("affection_")
        let rawKind = isAffectionate ? String(moodKind.dropFirst("affection_".count)) : moodKind
        let kind = normalizedKind(rawKind)

        // Try affection variant first (e.g. "affection_interact"), fall back to normal
        let targetKind = isAffectionate ? "affection_\(kind)" : kind
        guard let lines = charSet.lines[targetKind] ?? charSet.lines[kind], !lines.isEmpty else {
            return nil
        }

        // Pick a line, avoiding repeats within the last N picks
        var available = lines
        if let recent = recentLines[characterId] {
            available = lines.filter { !recent.contains($0) }
        }
        if available.isEmpty {
            available = lines
            recentLines[characterId] = []
        }

        let picked = available.randomElement() ?? lines[0]
        if recentLines[characterId] == nil {
            recentLines[characterId] = []
        }
        recentLines[characterId]?.insert(picked)
        if (recentLines[characterId]?.count ?? 0) > lines.count {
            recentLines[characterId]?.removeAll()
            recentLines[characterId]?.insert(picked)
        }

        return picked
    }

    // Try to find the base character from a skin variant
    // e.g. "002_amiya_winter#1" -> "002_amiya"
    private func closestMatch(in db: CharacterVoiceDatabase, for characterId: String) -> CharacterVoiceSet? {
        // Try progressive prefix matching
        let parts = characterId.split(separator: "_")
        for end in stride(from: parts.count, through: 1, by: -1) {
            let prefix = parts[0..<end].joined(separator: "_")
            if let match = db[prefix] {
                return match
            }
        }
        // Try full name
        let lowerId = characterId.lowercased()
        for (key, value) in db {
            if key.contains(lowerId) || lowerId.contains(key) || value.name == characterId {
                return value
            }
        }
        return nil
    }

    private func normalizedKind(_ kind: String) -> String {
        let isAffection = kind.hasPrefix("affection_")
        let raw = isAffection ? String(kind.dropFirst("affection_".count)) : kind

        // Map special kinds that stay as-is
        switch raw {
        case "happy", "interact", "poke":
            return isAffection ? "affection_interact" : "interact"
        case "rest", "resting", "sit":
            return isAffection ? "affection_rest" : "rest"
        case "sleep", "sleepy":
            return isAffection ? "affection_sleep" : "sleep"
        case "special":
            return isAffection ? "affection_special" : "special"
        case "feed":
            return isAffection ? "affection_feed" : "feed"
        case "low_battery", "low_bat":
            return isAffection ? "affection_low_battery" : "low_battery"
        case "long_screen_time", "long_screen":
            return "long_screen_time"
        default:
            // For unsupported cases (like "coding", "gaming"), just fallback to interact
            return "interact"
        }
    }
}
