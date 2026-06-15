import SwiftData
import SwiftUI

@main
struct SarosHarmonicJournalApp: App {
    @StateObject private var services = AppServices()

    private let modelContainer: ModelContainer

    init() {
        do {
            modelContainer = try ModelContainer(
                for: TrackedEntity.self,
                ThreadGroup.self,
                JournalRecord.self,
                RecordDraft.self,
                CustomFlipEvent.self
            )
        } catch {
            fatalError("Could not create SwiftData model container: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(services)
        }
        .modelContainer(modelContainer)
    }
}
