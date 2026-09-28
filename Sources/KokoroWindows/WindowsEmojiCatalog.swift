import Foundation

/// The exact emoji-data snapshot shipped by the macOS swift-emoji 0.1.1 dependency.
/// This local decoder avoids that package's Darwin-only NSRegularExpression initializer.
enum WindowsEmojiCatalog {
    struct Entry: Decodable {
        struct Variation: Decodable { let unified: String }
        let name: String
        let unified: String
        let shortName: String
        let shortNames: [String]
        let category: String
        let sortOrder: Int
        let skinVariations: [String: Variation]?

        var character: String { WindowsEmojiCatalog.character(unified: unified) }
    }

    static let all: [Entry] = {
        guard let url = Bundle.module.url(forResource: "emoji", withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return ((try? decoder.decode([Entry].self, from: data)) ?? []).sorted { $0.sortOrder < $1.sortOrder }
    }()

    private static let aliases: [String: Entry] = {
        var result: [String: Entry] = [:]
        for entry in all {
            result[entry.shortName] = entry
            for alias in entry.shortNames { result[alias] = entry }
        }
        return result
    }()

    static func character(fromShortCode shortCode: String) -> String? {
        let parts = shortCode.split(separator: ":").map(String.init)
        guard let alias = parts.first, let entry = aliases[alias] else { return nil }
        guard parts.count > 1 else { return entry.character }
        let skinTone: String?
        switch parts[1] {
        case "skin-tone-2": skinTone = "1F3FB"
        case "skin-tone-3": skinTone = "1F3FC"
        case "skin-tone-4": skinTone = "1F3FD"
        case "skin-tone-5": skinTone = "1F3FE"
        case "skin-tone-6": skinTone = "1F3FF"
        default: skinTone = nil
        }
        guard let skinTone, let variation = entry.skinVariations?[skinTone] else { return entry.character }
        return character(unified: variation.unified)
    }

    private static func character(unified: String) -> String {
        let scalars = unified.split(separator: "-").compactMap { UInt32($0, radix: 16) }.compactMap(Unicode.Scalar.init)
        return String(String.UnicodeScalarView(scalars))
    }
}
