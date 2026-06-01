import SwiftUI

enum AppTab: String, CaseIterable, Identifiable {
    case clock
    case catalog
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .clock: "Threads"
        case .catalog: "Catalog"
        case .settings: "Settings"
        }
    }

    var symbol: String {
        switch self {
        case .clock: "moonphase.new.moon"
        case .catalog: "globe.americas"
        case .settings: "gearshape"
        }
    }
}

struct RootView: View {
    var body: some View {
        TabView {
            ForEach(AppTab.allCases) { tab in
                NavigationStack {
                    screen(for: tab)
                }
                .tabItem {
                    Label(tab.title, systemImage: tab.symbol)
                }
            }
        }
    }

    @ViewBuilder
    private func screen(for tab: AppTab) -> some View {
        switch tab {
        case .clock:
            ClockDashboardView()
        case .catalog:
            CatalogView()
        case .settings:
            SettingsView()
        }
    }
}
