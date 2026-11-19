import Foundation

struct BoxRecord: Identifiable, Hashable, Codable, Sendable {
    var id: Int64
    var code: String
    var name: String
    var location: String
    var notes: String
    var updated: Int64
}

struct ItemRecord: Identifiable, Hashable, Codable, Sendable {
    var id: Int64
    var boxId: Int64
    var name: String
    var category: String
    var quantity: Int
    var notes: String
    var source: String

    enum CodingKeys: String, CodingKey {
        case id
        case boxId = "box_id"
        case name
        case category
        case quantity
        case notes
        case source
    }
}

struct PhotoRecord: Identifiable, Hashable, Codable, Sendable {
    var id: Int64
    var boxId: Int64
    var filename: String

    enum CodingKeys: String, CodingKey {
        case id
        case boxId = "box_id"
        case filename
    }
}

struct BoxSummary: Identifiable, Hashable, Sendable {
    var id: Int64 { box.id }
    let box: BoxRecord
    let itemTypeCount: Int
    let photoCount: Int
    let items: [ItemRecord]
}

struct DetectedObject: Identifiable, Hashable, Codable, Sendable {
    var id: UUID
    var label: String
    /// [ymin, xmin, ymax, xmax] normalized 0...1000 over the complete image.
    var box2d: [Double]
    var uncertain: Bool

    enum CodingKeys: String, CodingKey {
        case label
        case box2d = "box_2d"
        case uncertain
    }

    init(id: UUID = UUID(), label: String, box2d: [Double], uncertain: Bool) {
        self.id = id
        self.label = label
        self.box2d = box2d
        self.uncertain = uncertain
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = UUID()
        self.label = try container.decode(String.self, forKey: .label)
        self.box2d = try container.decode([Double].self, forKey: .box2d)
        self.uncertain = try container.decodeIfPresent(Bool.self, forKey: .uncertain) ?? true
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(label, forKey: .label)
        try container.encode(box2d, forKey: .box2d)
        try container.encode(uncertain, forKey: .uncertain)
    }
}

struct PhotoOverlayMetadata: Hashable, Codable, Sendable {
    var objects: [DetectedObject]
    var imageSha256: String
    var provider: String
    var model: String
    var created: Int64
}

struct SuggestedItem: Identifiable, Hashable, Codable, Sendable {
    var id: UUID
    var name: String
    var category: String
    var quantity: Int
    var uncertain: Bool
    var selected: Bool

    enum CodingKeys: String, CodingKey {
        case name
        case category
        case quantity
        case uncertain
    }

    init(
        id: UUID = UUID(),
        name: String,
        category: String = "",
        quantity: Int = 1,
        uncertain: Bool = true,
        selected: Bool = true
    ) {
        self.id = id
        self.name = name
        self.category = category
        self.quantity = quantity
        self.uncertain = uncertain
        self.selected = selected
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = UUID()
        self.name = try container.decode(String.self, forKey: .name)
        self.category = try container.decodeIfPresent(String.self, forKey: .category) ?? ""
        self.quantity = try container.decodeIfPresent(Int.self, forKey: .quantity) ?? 1
        self.uncertain = try container.decodeIfPresent(Bool.self, forKey: .uncertain) ?? true
        self.selected = true
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encode(category, forKey: .category)
        try container.encode(quantity, forKey: .quantity)
        try container.encode(uncertain, forKey: .uncertain)
    }
}

struct BackupPhotoEntry: Hashable, Codable, Sendable {
    var id: Int64
    var boxId: Int64
    var filename: String
    var jpegBase64: String
    var detections: PhotoOverlayMetadata?

    enum CodingKeys: String, CodingKey {
        case id
        case boxId = "box_id"
        case filename
        case jpegBase64
        case detections
    }
}

struct InventorySnapshot: Hashable, Codable, Sendable {
    static let expectedFormat = "box-finder-android-v1"
    var format: String
    var boxes: [BoxRecord]
    var items: [ItemRecord]
    var photos: [BackupPhotoEntry]
}
