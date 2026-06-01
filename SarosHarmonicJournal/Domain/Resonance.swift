import Foundation

struct EntityFlip: Identifiable, Hashable {
    var id: UUID { entityID }

    let entityID: UUID
    let entityTitle: String
    let date: Date
    let saros: Int
    let octalAddress: String
}

struct ResonanceEvent: Identifiable, Codable, Hashable {
    let id: UUID
    let entityIDs: [UUID]
    let centerDate: Date
    let startDate: Date
    let endDate: Date
    let sarosValues: [Int]
    let octalAddresses: [String]
}

enum ResonanceDetector {
    static func detectResonances(flips: [EntityFlip], window: TimeInterval) -> [ResonanceEvent] {
        guard flips.count >= 2, window > 0 else { return [] }

        let sorted = flips.sorted { $0.date < $1.date }
        var candidates: [ResonanceEvent] = []

        for index in sorted.indices {
            let startFlip = sorted[index]
            let group = sorted[index...].prefix { flip in
                flip.date.timeIntervalSince(startFlip.date) <= window
            }

            guard group.count >= 2 else { continue }
            candidates.append(makeEvent(from: Array(group)))
        }

        return mergeOverlapping(candidates.sorted { $0.startDate < $1.startDate })
    }

    private static func makeEvent(from flips: [EntityFlip]) -> ResonanceEvent {
        let startDate = flips.map(\.date).min() ?? Date()
        let endDate = flips.map(\.date).max() ?? startDate
        let average = flips
            .map { $0.date.timeIntervalSinceReferenceDate }
            .reduce(0, +) / Double(flips.count)

        return ResonanceEvent(
            id: UUID(),
            entityIDs: unique(flips.map(\.entityID)),
            centerDate: Date(timeIntervalSinceReferenceDate: average),
            startDate: startDate,
            endDate: endDate,
            sarosValues: Array(Set(flips.map(\.saros))).sorted(),
            octalAddresses: unique(flips.map(\.octalAddress))
        )
    }

    private static func mergeOverlapping(_ events: [ResonanceEvent]) -> [ResonanceEvent] {
        var merged: [ResonanceEvent] = []

        for event in events {
            guard var last = merged.popLast() else {
                merged.append(event)
                continue
            }

            if event.startDate <= last.endDate {
                let entityIDs = unique(last.entityIDs + event.entityIDs)
                let sarosValues = Array(Set(last.sarosValues + event.sarosValues)).sorted()
                let octalAddresses = unique(last.octalAddresses + event.octalAddresses)
                let startDate = min(last.startDate, event.startDate)
                let endDate = max(last.endDate, event.endDate)
                let centerDate = Date(
                    timeIntervalSinceReferenceDate:
                        (startDate.timeIntervalSinceReferenceDate + endDate.timeIntervalSinceReferenceDate) / 2
                )

                last = ResonanceEvent(
                    id: last.id,
                    entityIDs: entityIDs,
                    centerDate: centerDate,
                    startDate: startDate,
                    endDate: endDate,
                    sarosValues: sarosValues,
                    octalAddresses: octalAddresses
                )
            }

            merged.append(last)
        }

        return merged
    }

    private static func unique<T: Hashable>(_ values: [T]) -> [T] {
        var seen = Set<T>()
        return values.filter { seen.insert($0).inserted }
    }
}

