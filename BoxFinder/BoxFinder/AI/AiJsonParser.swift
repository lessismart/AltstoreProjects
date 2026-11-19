import Foundation

enum AiJsonError: LocalizedError, Sendable {
    case invalidResponse
    case missingJSON
    case missingItemsArray
    case missingBoxCodesArray

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "The AI returned an oversized or invalid response."
        case .missingJSON:
            return "The AI did not return JSON. Try again with clearer photos or a shorter question."
        case .missingItemsArray:
            return "The AI response did not include an items list."
        case .missingBoxCodesArray:
            return "The AI response did not include a boxCodes list."
        }
    }
}

enum AiJsonParser {
    static let maxResponseCharacters = 100_000
    static let maxItems = 80
    static let maxBoxCodes = 20

    static func extractJSONObject(from text: String?) throws -> [String: Any] {
        guard let text, text.count <= maxResponseCharacters else {
            throw AiJsonError.invalidResponse
        }
        guard let start = text.firstIndex(of: "{"),
              let end = text.lastIndex(of: "}"),
              start <= end else {
            throw AiJsonError.missingJSON
        }
        let slice = String(text[start...end])
        guard let data = slice.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AiJsonError.missingJSON
        }
        return object
    }

    static func parseItems(from text: String) throws -> [SuggestedItem] {
        let obj = try extractJSONObject(from: text)
        guard let rawItems = obj["items"] as? [Any] else {
            throw AiJsonError.missingItemsArray
        }

        var safe: [SuggestedItem] = []
        for raw in rawItems.prefix(maxItems) {
            guard let dict = raw as? [String: Any],
                  let rawName = dict["name"] as? String else {
                continue
            }
            let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, name.count <= 120 else { continue }

            var category = ((dict["category"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if category.count > 80 {
                category = String(category.prefix(80))
            }

            let rawQty: Int
            if let num = dict["quantity"] as? NSNumber, CFGetTypeID(num) != CFBooleanGetTypeID() {
                rawQty = num.intValue
            } else {
                rawQty = 1
            }
            let quantity = max(1, min(9999, rawQty))
            let uncertain = (dict["uncertain"] as? Bool) ?? true

            safe.append(SuggestedItem(
                name: name,
                category: category,
                quantity: quantity,
                uncertain: uncertain,
                selected: true
            ))
        }
        return safe
    }

    static func parseBoxCodes(from text: String, inventory: [BoxRecord]) throws -> [BoxRecord] {
        let obj = try extractJSONObject(from: text)
        guard let rawCodes = obj["boxCodes"] as? [Any] else {
            throw AiJsonError.missingBoxCodesArray
        }

        var seen = Set<String>()
        var matches: [BoxRecord] = []
        for rawCode in rawCodes.prefix(maxBoxCodes) {
            guard let code = rawCode as? String else { continue }
            let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed).inserted else { continue }
            if let box = inventory.first(where: { $0.code == trimmed }) {
                matches.append(box)
            }
        }
        return matches
    }

    /// Deduplicates items detected across multiple photos of the same box without summing repeated quantities.
    static func mergeItemBatches(_ batches: [[SuggestedItem]]) -> [SuggestedItem] {
        var order: [String] = []
        var merged: [String: SuggestedItem] = [:]

        for batch in batches {
            for item in batch {
                let key = item.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                guard !key.isEmpty else { continue }
                if var existing = merged[key] {
                    existing.quantity = max(existing.quantity, item.quantity)
                    existing.uncertain = existing.uncertain || item.uncertain
                    if existing.category.isEmpty && !item.category.isEmpty {
                        existing.category = item.category
                    }
                    merged[key] = existing
                } else {
                    order.append(key)
                    merged[key] = item
                }
            }
        }

        var result: [SuggestedItem] = []
        for key in order {
            if result.count >= maxItems { break }
            if let item = merged[key] {
                result.append(item)
            }
        }
        return result
    }
}
