import SwiftUI

@main
struct VentApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Window("Vent", id: "main") {
            PlaceholderView()
        }
        .defaultSize(width: 900, height: 600)
    }
}

struct PlaceholderView: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "fan")
                .font(.system(size: 48, weight: .light))
                .foregroundStyle(.secondary)
            Text("Vent")
                .font(.title2.weight(.semibold))
            Text("Skeleton build. Sensors, fans and storage arrive in later batches.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
}
