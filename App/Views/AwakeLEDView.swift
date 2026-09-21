import AppKit
import AwakeKit
import SwiftUI

extension AwakeLED {
    /// System colours, so the light follows the accessibility settings.
    var nsColor: NSColor {
        switch self {
        case .green: .systemGreen
        case .amber: .systemOrange
        case .red: .systemRed
        }
    }

    var color: Color { Color(nsColor: nsColor) }
}

/// The same light the menu bar shows, for the places that explain it.
struct AwakeLEDDot: View {
    let led: AwakeLED
    var diameter: CGFloat = 8

    var body: some View {
        Circle()
            .fill(led.color)
            .frame(width: diameter, height: diameter)
            .shadow(color: led.color.opacity(0.6), radius: 2)
            .accessibilityLabel("Status light: \(led.meaning)")
    }
}

/// The light and its legend in one line: three dots with their meaning, and
/// the one that is lit right now is the only one at full strength.
struct AwakeLEDLegend: View {
    let current: AwakeLED

    var body: some View {
        HStack(spacing: 10) {
            ForEach(AwakeLED.allCases, id: \.self) { led in
                HStack(spacing: 4) {
                    AwakeLEDDot(led: led, diameter: led == current ? 8 : 6)
                    Text(led.meaning)
                        .fontWeight(led == current ? .semibold : .regular)
                        .foregroundStyle(led == current ? .primary : .secondary)
                }
                .opacity(led == current ? 1 : 0.45)
            }
        }
        .font(.caption2)
        .lineLimit(1)
        .minimumScaleFactor(0.8)
        .help("The light under the fan in the menu bar shows the same state")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Status light: \(current.meaning)")
    }
}
