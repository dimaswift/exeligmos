import Foundation
import SwiftData
import SwiftUI

@main
struct SarosHarmonicJournalApp: App {
    @StateObject private var services = AppServices()

    private let modelContainer: ModelContainer

    init() {
        let defaults = UserDefaults.standard
        if defaults.string(forKey: JournalSettings.syncServerURLKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
            defaults.set(
                JournalSettings.defaultSyncServerURL,
                forKey: JournalSettings.syncServerURLKey
            )
        }
        do {
            modelContainer = try ModelContainer(
                for: TrackedEntity.self,
                ThreadGroup.self,
                JournalRecord.self,
                JournalEntry.self,
                JournalTag.self,
                JournalTemplate.self,
                JournalEntryDraft.self,
                SyncLocalCommand.self,
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
                .environmentObject(services.syncCoordinator)
                .preferredColorScheme(.dark)
        }
        .modelContainer(modelContainer)
    }
}
