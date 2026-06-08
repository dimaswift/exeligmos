import Combine
import Foundation

final class AppServices: ObservableObject {
    let eclipseService: any EclipseService
    let clockService: any SarosClockService
    let moonPhaseService: any MoonPhaseService
    let notificationScheduler: NotificationScheduler
    let exportService: ExportService
    let syncService: SyncService
    let animacyDatasetQueue: AnimacyDatasetQueueStore

    init(
        eclipseService: any EclipseService = CPlusPlusEclipseService(),
        moonPhaseService: any MoonPhaseService = BundledMoonPhaseService()
    ) {
        self.eclipseService = eclipseService
        self.clockService = DefaultSarosClockService(eclipseService: eclipseService)
        self.moonPhaseService = moonPhaseService
        self.notificationScheduler = .shared
        self.exportService = ExportService()
        self.syncService = SyncService()
        self.animacyDatasetQueue = AnimacyDatasetQueueStore()
    }
}
