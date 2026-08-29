import SwiftUI

struct RootView: View {
    @EnvironmentObject private var controller: CaptureController
    @Environment(\.scenePhase) private var scenePhase

    @State private var selection = Tab.measure

    private enum Tab: Hashable {
        case measure, history, settings
    }

    var body: some View {
        TabView(selection: $selection) {
            CaptureView()
                .tabItem { Label("Measure", systemImage: "scope") }
                .tag(Tab.measure)

            HistoryView()
                .tabItem { Label("History", systemImage: "list.bullet.rectangle") }
                .tag(Tab.history)

            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag(Tab.settings)
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                controller.resume()
            case .background, .inactive:
                controller.pause()
            @unknown default:
                break
            }
        }
        .onChange(of: selection) { _, tab in
            // Keep the camera running only where it is needed.
            if tab == .measure {
                controller.resume()
            } else {
                controller.pause()
            }
        }
    }
}
