import SwiftUI

enum Theme {
    static let bg = Color(red: 8 / 255, green: 16 / 255, blue: 29 / 255)
    static let surface = Color(red: 17 / 255, green: 28 / 255, blue: 47 / 255)
    static let surfaceAlt = Color(red: 23 / 255, green: 38 / 255, blue: 62 / 255)
    static let border = Color(red: 35 / 255, green: 55 / 255, blue: 90 / 255)
    static let teal = Color(red: 45 / 255, green: 212 / 255, blue: 191 / 255)
    static let sky = Color(red: 56 / 255, green: 189 / 255, blue: 248 / 255)
    static let green = Color(red: 52 / 255, green: 211 / 255, blue: 153 / 255)
    static let amber = Color(red: 245 / 255, green: 158 / 255, blue: 11 / 255)
    static let rose = Color(red: 251 / 255, green: 113 / 255, blue: 133 / 255)
    static let text = Color(red: 238 / 255, green: 244 / 255, blue: 255 / 255)
    static let muted = Color(red: 152 / 255, green: 171 / 255, blue: 201 / 255)
}

struct ControlCard<Content: View>: View {
    let title: String?
    let accent: Color
    @ViewBuilder let content: Content

    init(_ title: String? = nil, accent: Color = Theme.teal, @ViewBuilder content: () -> Content) {
        self.title = title
        self.accent = accent
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let title {
                HStack(spacing: 8) {
                    Circle()
                        .fill(self.accent)
                        .frame(width: 8, height: 8)
                    Text(title)
                        .font(.headline)
                        .foregroundStyle(Theme.text)
                }
            }
            self.content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface)
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Theme.border, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

struct StatusChip: View {
    let text: String
    let color: Color

    var body: some View {
        Text(self.text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(self.color)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(self.color.opacity(0.14))
            .overlay(Capsule().stroke(self.color.opacity(0.4), lineWidth: 1))
            .clipShape(Capsule())
    }
}
