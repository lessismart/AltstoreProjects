import Foundation

enum PhotoAnnotationError: LocalizedError, Sendable {
    case invalidJSON
    case missingObjectsArray

    var errorDescription: String? {
        switch self {
        case .invalidJSON:
            return "The AI response did not contain valid object location JSON."
        case .missingObjectsArray:
            return "The AI response did not return an objects list."
        }
    }
}

final class PhotoAnnotationStore: Sendable {
    static let prompt = """
        Locate the distinct visible objects in this single photo. Return ONLY JSON {"objects":[{"label":"object name","box_2d":[100,200,500,700],"uncertain":true}]}. Each box_2d is [ymin,xmin,ymax,xmax], normalized from 0 to 1000 relative to the FULL image. Use tight boxes around visible objects, short specific labels, and uncertain=true when identification or location is ambiguous. Do not invent hidden objects or provide boxes for the whole storage box unless it is itself an object of interest. Return an empty objects array if no objects can be located. Up to 40 objects.
        """

    static let maxSidecarBytes = 100_000
    static let maxRawEntries = 80
    static let maxAcceptedObjects = 40

    private let fileStore: PhotoFileStore

    init(fileStore: PhotoFileStore) {
        self.fileStore = fileStore
    }

    static func parse(text: String) throws -> [DetectedObject] {
        let jsonObject = try AiJsonParser.extractJSONObject(from: text)
        return try normalize(jsonObject: jsonObject)
    }

    static func normalize(jsonObject: [String: Any]) throws -> [DetectedObject] {
        guard let rawObjects = jsonObject["objects"] as? [Any] else {
            throw PhotoAnnotationError.missingObjectsArray
        }

        var accepted: [DetectedObject] = []
        for entry in rawObjects.prefix(maxRawEntries) {
            if accepted.count >= maxAcceptedObjects { break }
            guard let dict = entry as? [String: Any],
                  let rawLabel = dict["label"] as? String else {
                continue
            }
            let label = rawLabel.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !label.isEmpty, label.count <= 120 else { continue }
            guard let rawBox = dict["box_2d"] as? [Any], rawBox.count == 4 else { continue }

            var coords: [Double] = []
            coords.reserveCapacity(4)
            var valid = true
            for element in rawBox {
                guard let num = element as? NSNumber,
                      CFGetTypeID(num) != CFBooleanGetTypeID() else {
                    valid = false
                    break
                }
                let value = num.doubleValue
                guard value.isFinite, value >= 0, value <= 1000 else {
                    valid = false
                    break
                }
                coords.append(value)
            }
            guard valid,
                  coords.count == 4,
                  coords[0] < coords[2],
                  coords[1] < coords[3] else {
                continue
            }

            let uncertain: Bool
            if let boolVal = dict["uncertain"] as? Bool {
                uncertain = boolVal
            } else {
                uncertain = true
            }

            accepted.append(DetectedObject(label: label, box2d: coords, uncertain: uncertain))
        }
        return accepted
    }

    private func sidecarURL(forSha256 hash: String) -> URL {
        fileStore.overlaysDirectory.appendingPathComponent("\(hash).json")
    }

    func load(forPhotoAt photoURL: URL) -> PhotoOverlayMetadata? {
        guard let hash = try? PhotoFileStore.sha256Hex(ofFileAt: photoURL) else { return nil }
        let url = sidecarURL(forSha256: hash)
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let fileSize = attrs[.size] as? NSNumber,
              fileSize.intValue <= Self.maxSidecarBytes,
              let data = try? Data(contentsOf: url),
              data.count <= Self.maxSidecarBytes,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let storedHash = obj["imageSha256"] as? String,
              storedHash == hash,
              let objects = try? Self.normalize(jsonObject: obj) else {
            return nil
        }
        let provider = (obj["provider"] as? String) ?? "offline"
        let model = (obj["model"] as? String) ?? ""
        let created = (obj["created"] as? NSNumber)?.int64Value ?? 0
        return PhotoOverlayMetadata(
            objects: objects,
            imageSha256: hash,
            provider: provider,
            model: model,
            created: created
        )
    }

    @discardableResult
    func save(
        objects: [DetectedObject],
        forPhotoAt photoURL: URL,
        provider: String,
        model: String
    ) throws -> PhotoOverlayMetadata {
        let hash = try PhotoFileStore.sha256Hex(ofFileAt: photoURL)
        let rawPayload: [String: Any] = [
            "objects": objects.map { [
                "label": $0.label,
                "box_2d": $0.box2d,
                "uncertain": $0.uncertain
            ] }
        ]
        let normalized = try Self.normalize(jsonObject: rawPayload)
        let created = Int64(Date().timeIntervalSince1970 * 1000)
        let metadata = PhotoOverlayMetadata(
            objects: normalized,
            imageSha256: hash,
            provider: provider,
            model: model,
            created: created
        )
        let encoder = JSONEncoder()
        let encoded = try encoder.encode(metadata)
        try encoded.write(to: sidecarURL(forSha256: hash), options: .atomic)
        return metadata
    }

    func restore(_ metadata: PhotoOverlayMetadata, forPhotoAt photoURL: URL) throws {
        let hash = try PhotoFileStore.sha256Hex(ofFileAt: photoURL)
        guard hash == metadata.imageSha256 else { return }
        _ = try save(
            objects: metadata.objects,
            forPhotoAt: photoURL,
            provider: metadata.provider,
            model: metadata.model
        )
    }
}
