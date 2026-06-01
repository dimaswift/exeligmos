import Foundation

enum EntityFactory {
    static func makeTrackedEntity(
        title: String,
        anchorDate: Date,
        saros requestedSaros: Int? = nil,
        harmonicDepth: Int = JournalSettings.defaultHarmonicDepth,
        emoji: String? = nil,
        notes: String? = nil,
        eclipseService: any EclipseService
    ) throws -> TrackedEntity {
        let nearest = try eclipseService.nearestEclipse(to: anchorDate)
        guard let saros = requestedSaros ?? nearest?.saros else {
            throw EclipseServiceError.sarosNotFound(0)
        }

        return TrackedEntity(
            title: title,
            anchorDate: anchorDate,
            saros: saros,
            harmonicDepth: harmonicDepth,
            emoji: emoji,
            notes: notes,
            nearestEclipseID: nearest?.id,
            birthOrAnchorEclipseDate: nearest?.date
        )
    }
}
