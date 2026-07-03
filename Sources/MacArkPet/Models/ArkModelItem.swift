// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 MacArkPet contributors

import Foundation

struct ArkModelItem: Identifiable, Hashable {
    let id: String
    let title: String
    let subtitle: String
    let type: String
    let skinName: String
    let tags: [String]
    let tagLabels: [String]
    let relativeDirectory: String
    let imageName: String
    let imageURL: URL?
    let atlasURL: URL?
    let skeletonURL: URL?
    let snapshotURL: URL?

    var isInstalled: Bool {
        imageURL != nil
    }

    var hasSpineAssets: Bool {
        atlasURL != nil && skeletonURL != nil
    }

    /// Extracts the base character ID for voice line lookup.
    /// e.g. "002_amiya_winter#1" → "002_amiya", "1012_skadi2_boc#4" → "1012_skadi2"
    var voiceCharacterID: String {
        // If there's no variant suffix, use the ID directly
        guard id.contains("#") || id.filter({ $0 == "_" }).count > 1 else { return id }

        // Strip trailing variant (everything after the last '#')
        let strippedHash = id
            .components(separatedBy: "#")
            .first ?? id

        // For multi-part IDs like "002_amiya_winter", return first two parts
        // For alternates like "1012_skadi2_boc", strip the skin suffix
        let parts = strippedHash.split(separator: "_")
        guard parts.count >= 2 else { return strippedHash }

        // Known base character IDs (first segment is numeric code + character name)
        // Rules: for standard format "123_name_skin", return "123_name"
        // For format "1012_skadi2_boc", return "1012_skadi2" (keep the 2 if present)
        if parts.count >= 3 {
            let secondPart = String(parts[1])
            // Check if second part is a single character name or has a digit (like skadi2, texas2)
            let thirdPart = String(parts[2])
            // If third part looks like a variant/category word, strip it
            let variantWords = ["epoque", "summer", "winter", "sale", "boc", "nian", "witch", "wild",
                                "snow", "marthe", "game", "kitchen", "striker", "whirlwind", "test",
                                "kfc", "breaker", "sweep", "ghost", "shining", "race", "unveiling",
                                "cfa", "ncg", "as", "it", "sightseer", "iter", "iteration",
                                "daily", "sale", "sanrio", "yun", "taiko", "wwf", "mh",
                                "dungeon", "avemujica", "rainbow6", "ambiencesynesthesia",
                                "shining", "casc"]
            if variantWords.contains(thirdPart.lowercased()) {
                return "\(parts[0])_\(secondPart)"
            }
        }

        return strippedHash
    }

    var searchableText: String {
        ([id, title, subtitle, type, skinName] + tags + tagLabels).joined(separator: " ").lowercased()
    }
}

struct ArkModelDataset: Decodable {
    let storageDirectory: [String: String]
    let sortTags: [String: String]?
    let data: [String: ArkModelEntry]
}

struct ArkModelEntry: Decodable {
    let assetId: String?
    let type: String
    let style: String?
    let name: String
    let appellation: String?
    let skinGroupName: String?
    let sortTags: [String]?
    let assetList: [String: AssetListValue]
}

enum AssetListValue: Decodable {
    case one(String)
    case many([String])

    var first: String? {
        switch self {
        case .one(let value):
            return value
        case .many(let values):
            return values.first
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(String.self) {
            self = .one(value)
        } else {
            self = .many(try container.decode([String].self))
        }
    }
}
