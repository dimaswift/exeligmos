import Foundation
import UIKit

struct JournalDeviceIdentity: Codable, Hashable {
    let id: String
    let name: String
    let emoji: String
}

enum JournalDevice {
    static func current(defaults: UserDefaults = .standard) -> JournalDeviceIdentity {
        ensureIdentity(defaults: defaults)
        return JournalDeviceIdentity(
            id: defaults.string(forKey: JournalSettings.deviceIDKey) ?? generateID(),
            name: defaults.string(forKey: JournalSettings.deviceNameKey).nilIfBlank ?? UIDevice.current.name,
            emoji: defaults.string(forKey: JournalSettings.deviceEmojiKey).nilIfBlank ?? "◇"
        )
    }

    @discardableResult
    static func ensureIdentity(defaults: UserDefaults = .standard) -> JournalDeviceIdentity {
        if defaults.string(forKey: JournalSettings.deviceIDKey).nilIfBlank == nil {
            defaults.set(generateID(), forKey: JournalSettings.deviceIDKey)
        }
        if defaults.string(forKey: JournalSettings.deviceNameKey).nilIfBlank == nil {
            defaults.set(UIDevice.current.name, forKey: JournalSettings.deviceNameKey)
        }
        if defaults.string(forKey: JournalSettings.deviceEmojiKey).nilIfBlank == nil {
            defaults.set("◇", forKey: JournalSettings.deviceEmojiKey)
        }
        return JournalDeviceIdentity(
            id: defaults.string(forKey: JournalSettings.deviceIDKey) ?? generateID(),
            name: defaults.string(forKey: JournalSettings.deviceNameKey).nilIfBlank ?? "Device",
            emoji: defaults.string(forKey: JournalSettings.deviceEmojiKey).nilIfBlank ?? "◇"
        )
    }

    private static func generateID() -> String {
        let letters = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ")
        return String((0..<5).map { _ in letters.randomElement() ?? "X" })
    }
}
