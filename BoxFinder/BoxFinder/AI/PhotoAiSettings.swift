import Foundation

enum PhotoAiProvider: String, CaseIterable, Identifiable, Sendable {
    case offline
    case openrouter
    case gemini

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .offline: return "On this device"
        case .openrouter: return "OpenRouter"
        case .gemini: return "Google Gemini"
        }
    }

    var pickerLabel: String {
        switch self {
        case .offline: return "On this device · offline"
        case .openrouter: return "OpenRouter · online"
        case .gemini: return "Google Gemini · online"
        }
    }

    var isOnline: Bool {
        self != .offline
    }
}

enum OfflineModelSlot: String, CaseIterable, Identifiable, Sendable {
    case gemma4
    case gemma3n
    case custom

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .gemma4: return "Gemma 4 E2B"
        case .gemma3n: return "Gemma 3n E2B"
        case .custom: return "Another LiteRT-LM vision model"
        }
    }

    var filenameOnDisk: String {
        switch self {
        case .gemma4: return "gemma4.litertlm"
        case .gemma3n: return "gemma3n.litertlm"
        case .custom: return "custom-vision.litertlm"
        }
    }

    var downloadPageURL: URL {
        switch self {
        case .gemma4:
            return URL(string: "https://huggingface.co/litert-community/gemma-4-E2B-it-litert-lm")!
        case .gemma3n:
            return URL(string: "https://huggingface.co/google/gemma-3n-E2B-it-litert-lm")!
        case .custom:
            return URL(string: "https://huggingface.co/litert-community")!
        }
    }
}

final class PhotoAiSettingsStore: @unchecked Sendable {
    static let defaultOpenRouterModel = "google/gemini-2.5-flash"
    static let piPresetOpenRouterModel = "qwen/qwen3.7-flash"
    static let defaultGeminiModel = "gemini-2.5-flash"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var provider: PhotoAiProvider {
        get { PhotoAiProvider(rawValue: defaults.string(forKey: "photo_ai_provider") ?? "offline") ?? .offline }
        set { defaults.set(newValue.rawValue, forKey: "photo_ai_provider") }
    }

    var offlineModel: OfflineModelSlot {
        get { OfflineModelSlot(rawValue: defaults.string(forKey: "photo_ai_offline_model") ?? "gemma4") ?? .gemma4 }
        set { defaults.set(newValue.rawValue, forKey: "photo_ai_offline_model") }
    }

    func selectedOnlineModel(for provider: PhotoAiProvider) -> String {
        let key = "photo_ai_model_\(provider.rawValue)"
        if let saved = defaults.string(forKey: key), !saved.isEmpty {
            return saved
        }
        return provider == .gemini ? Self.defaultGeminiModel : Self.defaultOpenRouterModel
    }

    func setSelectedOnlineModel(_ model: String, for provider: PhotoAiProvider) {
        defaults.set(model, forKey: "photo_ai_model_\(provider.rawValue)")
    }

    var confirmUpload: Bool {
        get {
            if defaults.object(forKey: "photo_ai_confirm_upload") == nil { return true }
            return defaults.bool(forKey: "photo_ai_confirm_upload")
        }
        set { defaults.set(newValue, forKey: "photo_ai_confirm_upload") }
    }

    var useCPUForOffline: Bool {
        get { defaults.bool(forKey: "photo_ai_offline_cpu") }
        set { defaults.set(newValue, forKey: "photo_ai_offline_cpu") }
    }

    var showBoxesInViewer: Bool {
        get {
            if defaults.object(forKey: "photo_viewer_show_boxes") == nil { return true }
            return defaults.bool(forKey: "photo_viewer_show_boxes")
        }
        set { defaults.set(newValue, forKey: "photo_viewer_show_boxes") }
    }

    func importedFilename(for slot: OfflineModelSlot) -> String? {
        let val = defaults.string(forKey: "photo_ai_filename_\(slot.rawValue)")
        return (val?.isEmpty ?? true) ? nil : val
    }

    func setImportedFilename(_ filename: String?, for slot: OfflineModelSlot) {
        let key = "photo_ai_filename_\(slot.rawValue)"
        if let filename {
            defaults.set(filename, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }

    func lastTestedStamp(for slot: OfflineModelSlot) -> String? {
        defaults.string(forKey: "photo_ai_tested_\(slot.rawValue)")
    }

    func setLastTestedStamp(_ stamp: String?, for slot: OfflineModelSlot) {
        let key = "photo_ai_tested_\(slot.rawValue)"
        if let stamp {
            defaults.set(stamp, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }
}
