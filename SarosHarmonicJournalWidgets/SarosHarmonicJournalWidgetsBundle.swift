import SwiftUI
import WidgetKit

@main
struct SarosHarmonicJournalWidgetsBundle: WidgetBundle {
    var body: some Widget {
        TrackedThreadWidget()
        ThreadTrackingLiveActivityWidget()
    }
}
