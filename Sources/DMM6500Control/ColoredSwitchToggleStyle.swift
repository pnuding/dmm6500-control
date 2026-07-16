import SwiftUI

/// A compact switch that always renders in the given color, regardless of
/// whether the window is key/main. The system's native .switch style
/// deliberately desaturates to gray when the window loses focus (standard
/// macOS behavior for every tinted control) - this draws its own track and
/// thumb instead, so the toggle stays legible even when glancing at a
/// background window.
struct ColoredSwitchToggleStyle: ToggleStyle {
    var tint: Color
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let isOn = configuration.isOn
        Capsule()
            .fill(isOn ? tint : Color.secondary.opacity(0.35))
            .opacity(isEnabled ? 1 : 0.4)
            .frame(width: 30, height: 17)
            .overlay(
                Circle()
                    .fill(.white)
                    .padding(2)
                    .offset(x: isOn ? 6 : -6)
            )
            .contentShape(Capsule())
            .onTapGesture { if isEnabled { configuration.isOn.toggle() } }
            .animation(.easeInOut(duration: 0.12), value: isOn)
    }
}
