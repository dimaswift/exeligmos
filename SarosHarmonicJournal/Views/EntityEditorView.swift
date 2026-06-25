import SwiftData
import SwiftUI

struct EntityEditorView: View {
    @EnvironmentObject private var services: AppServices
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @AppStorage(JournalSettings.harmonicDepthKey) private var harmonicDepth = JournalSettings.defaultHarmonicDepth

    let entity: TrackedEntity?

    @State private var title = ""
    @State private var anchorDate = Date()
    @State private var saros = 141
    @State private var emoji = ""
    @State private var notes = ""
    @State private var notificationsEnabled = true
    @State private var suggestionText = ""
    @State private var errorMessage: String?
    @State private var didLoad = false

    init(entity: TrackedEntity? = nil) {
        self.entity = entity
    }

    var body: some View {
        Form {
            Section("Anchor") {
                TextField("Title", text: $title)
                DatePicker("Date", selection: $anchorDate, displayedComponents: [.date, .hourAndMinute])
                TextField("Emoji", text: $emoji)
                TextField("Notes", text: $notes, axis: .vertical)
                    .lineLimit(3...6)

                if !suggestionText.isEmpty {
                    Text(suggestionText)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Saros clock") {
                Stepper("Saros \(saros)", value: $saros, in: 1...180)
            }

            Section("Notifications") {
                Toggle("Bin flip reminders", isOn: $notificationsEnabled)
            }
        }
        .navigationTitle(entity == nil ? "New Thread" : "Edit Thread")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save", action: save)
            }
        }
        .onAppear(perform: loadInitialState)
        .onChange(of: anchorDate) { _, _ in
            suggestNearestSaros()
        }
        .alert("Could not save", isPresented: Binding(get: { errorMessage != nil }, set: { _ in errorMessage = nil })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func loadInitialState() {
        guard !didLoad else { return }
        didLoad = true

        if let entity {
            title = entity.title
            anchorDate = entity.anchorDate
            saros = entity.saros
            emoji = entity.emoji ?? ""
            notes = entity.notes ?? ""
            notificationsEnabled = entity.notificationsEnabled
        } else {
            suggestNearestSaros()
        }
    }

    private func suggestNearestSaros() {
        guard let nearest = try? services.eclipseService.nearestEclipse(to: anchorDate) else {
            suggestionText = ""
            return
        }
        saros = nearest.saros
        suggestionText = "Nearest eclipse suggests Saros \(nearest.saros) on \(JournalFormatters.date.string(from: nearest.date))."
    }

    private func save() {
        do {
            if let entity {
                entity.title = title
                entity.anchorDate = anchorDate
                entity.saros = saros
                entity.harmonicDepth = harmonicDepth
                entity.emoji = Optional(emoji).nilIfBlank
                entity.notes = Optional(notes).nilIfBlank
                entity.notificationsEnabled = notificationsEnabled
                entity.touch()
            } else {
                let newEntity = try EntityFactory.makeTrackedEntity(
                    title: title,
                    anchorDate: anchorDate,
                    saros: saros,
                    harmonicDepth: harmonicDepth,
                    emoji: Optional(emoji).nilIfBlank,
                    notes: Optional(notes).nilIfBlank,
                    eclipseService: services.eclipseService
                )
                newEntity.notificationsEnabled = notificationsEnabled
                modelContext.insert(newEntity)
            }

            try modelContext.save()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
