import SwiftUI

public struct RadioTheme {
    public static let bgDeep        = Color(red: 0.07, green: 0.08, blue: 0.10)
    public static let bgPanel       = Color(red: 0.10, green: 0.11, blue: 0.14)
    public static let bgCard        = Color(red: 0.13, green: 0.15, blue: 0.19)
    public static let borderSubtle  = Color(red: 0.20, green: 0.24, blue: 0.30)
    public static let borderActive  = Color(red: 0.00, green: 0.85, blue: 1.00)

    public static let vfdAmber      = Color(red: 1.00, green: 0.72, blue: 0.10)
    public static let vfdCyan       = Color(red: 0.00, green: 0.90, blue: 1.00)
    public static let vfdGreen      = Color(red: 0.00, green: 0.95, blue: 0.45)
    public static let ledRed        = Color(red: 1.00, green: 0.20, blue: 0.30)
    public static let ledYellow     = Color(red: 1.00, green: 0.80, blue: 0.00)

    public static let textBright    = Color(red: 0.95, green: 0.97, blue: 1.00)
    public static let textMuted     = Color(red: 0.60, green: 0.65, blue: 0.75)
    public static let textDim       = Color(red: 0.40, green: 0.45, blue: 0.52)
}

public struct RadioCardModifier: ViewModifier {
    public var title: String? = nil

    public func body(content: Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let title = title {
                Text(title.uppercased())
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundColor(RadioTheme.textDim)
                    .tracking(1.2)
                    .padding(.horizontal, 4)
            }
            content
                .padding(10)
                .background(RadioTheme.bgCard)
                .cornerRadius(8)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(RadioTheme.borderSubtle, lineWidth: 1)
                )
        }
    }
}

public extension View {
    func radioCard(title: String? = nil) -> some View {
        modifier(RadioCardModifier(title: title))
    }
}

public struct ModeButtonStyle: ButtonStyle {
    public var isSelected: Bool

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .semibold, design: .monospaced))
            .padding(.vertical, 6)
            .padding(.horizontal, 10)
            .background(
                isSelected ? RadioTheme.vfdCyan.opacity(0.2) : RadioTheme.bgPanel
            )
            .foregroundColor(isSelected ? RadioTheme.vfdCyan : RadioTheme.textMuted)
            .cornerRadius(5)
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .stroke(isSelected ? RadioTheme.vfdCyan : RadioTheme.borderSubtle, lineWidth: isSelected ? 1.5 : 1)
            )
            .scaleEffect(configuration.isPressed ? 0.96 : 1.0)
            .shadow(color: isSelected ? RadioTheme.vfdCyan.opacity(0.3) : .clear, radius: 4)
    }
}
