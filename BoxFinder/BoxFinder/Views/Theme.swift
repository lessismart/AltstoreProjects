import SwiftUI
import UIKit

enum BoxFinderTheme {
    static let navy = Color(red: 22.0 / 255.0, green: 40.0 / 255.0, blue: 60.0 / 255.0)
    static let accent = Color(red: 13.0 / 255.0, green: 111.0 / 255.0, blue: 120.0 / 255.0)
    static let pageBackground = Color(uiColor: .systemGroupedBackground)
    static let cardBackground = Color(uiColor: .secondarySystemGroupedBackground)
    static let secondaryFill = Color(uiColor: .tertiarySystemGroupedBackground)

    static func detectionColor(forIndex index: Int, isSelected: Bool) -> Color {
        if isSelected {
            return .yellow
        }
        let hue = ((Double(index) * 137.5 + 165.0).truncatingRemainder(dividingBy: 360.0)) / 360.0
        return Color(hue: hue, saturation: 0.80, brightness: 1.0)
    }
}
