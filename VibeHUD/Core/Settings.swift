//
//  Settings.swift
//  VibeHUD
//
//  App settings manager using UserDefaults
//

import Foundation

/// Available notification sounds
enum NotificationSound: String, CaseIterable {
    case none = "None"
    case pop = "Pop"
    case ping = "Ping"
    case tink = "Tink"
    case glass = "Glass"
    case blow = "Blow"
    case bottle = "Bottle"
    case frog = "Frog"
    case funk = "Funk"
    case hero = "Hero"
    case morse = "Morse"
    case purr = "Purr"
    case sosumi = "Sosumi"
    case submarine = "Submarine"
    case basso = "Basso"

    /// The system sound name to use with NSSound, or nil for no sound
    var soundName: String? {
        self == .none ? nil : rawValue
    }
}

enum AppSettings {
    private static let defaults = UserDefaults.standard

    // MARK: - Keys

    private enum Keys {
        static let notificationSound = "notificationSound"
        static let claudeDirectoryName = "claudeDirectoryName"
        static let vibrationTapEnabled = "vibrationTapEnabled"
        static let vibrationTapMinAmplitude = "vibrationTapMinAmplitude"
    }

    // MARK: - Notification Sound

    /// The sound to play when Claude finishes and is ready for input
    static var notificationSound: NotificationSound {
        get {
            guard let rawValue = defaults.string(forKey: Keys.notificationSound),
                  let sound = NotificationSound(rawValue: rawValue) else {
                return .pop // Default to Pop
            }
            return sound
        }
        set {
            defaults.set(newValue.rawValue, forKey: Keys.notificationSound)
        }
    }

    // MARK: - Claude Directory

    /// The name of the Claude config directory under the user's home folder.
    /// Defaults to ".claude" (standard Claude Code installation).
    /// Change to ".claude-internal" (or similar) for enterprise/custom distributions.
    static var claudeDirectoryName: String {
        get {
            let value = defaults.string(forKey: Keys.claudeDirectoryName) ?? ""
            return value.isEmpty ? ".claude" : value
        }
        set {
            defaults.set(newValue.trimmingCharacters(in: .whitespaces), forKey: Keys.claudeDirectoryName)
        }
    }

    // MARK: - Vibration Tap Detection

    /// Whether vibration tap detection is enabled.
    static var vibrationTapEnabled: Bool {
        get {
            if defaults.object(forKey: Keys.vibrationTapEnabled) == nil {
                return true
            }
            return defaults.bool(forKey: Keys.vibrationTapEnabled)
        }
        set {
            defaults.set(newValue, forKey: Keys.vibrationTapEnabled)
        }
    }

    /// Minimum tap amplitude required to emit tap events.
    static var vibrationTapMinAmplitude: Double {
        get {
            guard defaults.object(forKey: Keys.vibrationTapMinAmplitude) != nil else {
                return 0.005
            }
            return clampTapAmplitude(defaults.double(forKey: Keys.vibrationTapMinAmplitude))
        }
        set {
            defaults.set(clampTapAmplitude(newValue), forKey: Keys.vibrationTapMinAmplitude)
        }
    }

    /// Lower amplitude means more sensitive.
    static let vibrationTapMinAmplitudeLowerBound: Double = 0.0015
    static let vibrationTapMinAmplitudeUpperBound: Double = 0.03

    /// 0.0 = least sensitive, 1.0 = most sensitive.
    static var vibrationSensitivityLevel: Double {
        get {
            let minA = vibrationTapMinAmplitudeLowerBound
            let maxA = vibrationTapMinAmplitudeUpperBound
            let amp = vibrationTapMinAmplitude
            let ratio = (maxA - amp) / (maxA - minA)
            return min(max(ratio, 0), 1)
        }
        set {
            let clamped = min(max(newValue, 0), 1)
            let minA = vibrationTapMinAmplitudeLowerBound
            let maxA = vibrationTapMinAmplitudeUpperBound
            vibrationTapMinAmplitude = maxA - clamped * (maxA - minA)
        }
    }

    private static func clampTapAmplitude(_ value: Double) -> Double {
        min(max(value, vibrationTapMinAmplitudeLowerBound), vibrationTapMinAmplitudeUpperBound)
    }
}
