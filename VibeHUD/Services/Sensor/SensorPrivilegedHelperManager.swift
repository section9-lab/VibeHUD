import CryptoKit
import Foundation
import ServiceManagement

final class SensorPrivilegedHelperManager {
    static let shared = SensorPrivilegedHelperManager()
    private let helperLabel = SensorServiceClient.machServiceName
    private let daemonPlistName = "com.section9-lab.VibeHUD.SensorHelper.plist"
    private let registrationFingerprintKey = "sensorHelperRegistrationFingerprint"

    private lazy var daemonService = SMAppService.daemon(plistName: daemonPlistName)

    private init() {}

    func installHelper() -> Bool {
        repairRegistrationIfNeeded()

        guard let bundledHelperURL else {
            print("[SensorHelperManager] Bundled helper is missing from the app bundle")
            return false
        }
        guard let bundledDaemonPlistURL else {
            print("[SensorHelperManager] Bundled daemon plist is missing from the app bundle")
            return false
        }

        print("[SensorHelperManager] Preparing helper from \(bundledHelperURL.path)")
        print("[SensorHelperManager] Preparing daemon plist from \(bundledDaemonPlistURL.path)")

        do {
            switch daemonService.status {
            case .enabled:
                persistRegisteredFingerprint()
                return true
            case .requiresApproval:
                persistRegisteredFingerprint()
                print("[SensorHelperManager] Helper registration requires approval in System Settings > Login Items")
                return false
            case .notRegistered, .notFound:
                try registerDaemon()
            @unknown default:
                try registerDaemon()
            }
        } catch {
            print("[SensorHelperManager] Failed to register helper daemon: \(error.localizedDescription)")
            return false
        }

        switch daemonService.status {
        case .enabled:
            persistRegisteredFingerprint()
            return true
        case .requiresApproval:
            persistRegisteredFingerprint()
            print("[SensorHelperManager] Helper registration requires approval in System Settings > Login Items")
            return false
        case .notRegistered, .notFound:
            print("[SensorHelperManager] Helper daemon is still unavailable after registration attempt")
            return false
        @unknown default:
            print("[SensorHelperManager] Helper daemon returned an unknown status after registration")
            return false
        }
    }

    var status: SMAppService.Status {
        repairRegistrationIfNeeded()
        return daemonService.status
    }

    func openApprovalSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    @discardableResult
    func uninstallHelper() -> Bool {
        unregisterDaemonIfNeeded()
        clearPersistedRegistrationState()

        switch daemonService.status {
        case .notRegistered, .notFound:
            return true
        case .requiresApproval, .enabled:
            return false
        @unknown default:
            return false
        }
    }

    private var bundledHelperURL: URL? {
        let helperURL = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Library/LaunchServices", isDirectory: true)
            .appendingPathComponent(helperLabel, isDirectory: false)

        return FileManager.default.isReadableFile(atPath: helperURL.path) ? helperURL : nil
    }

    private var bundledDaemonPlistURL: URL? {
        let plistURL = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Library/LaunchDaemons", isDirectory: true)
            .appendingPathComponent(daemonPlistName, isDirectory: false)

        return FileManager.default.isReadableFile(atPath: plistURL.path) ? plistURL : nil
    }

    private var currentRegistrationFingerprint: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown"
        let bundlePath = Bundle.main.bundleURL.resolvingSymlinksInPath().path
        let helperSignature = fileSignature(at: bundledHelperURL)
        let plistSignature = fileSignature(at: bundledDaemonPlistURL)
        return "\(version)-\(build)|\(bundlePath)|\(helperLabel)|\(daemonPlistName)|\(helperSignature)|\(plistSignature)"
    }

    private var shouldRefreshRegistration: Bool {
        let storedFingerprint = UserDefaults.standard.string(forKey: registrationFingerprintKey)
        return storedFingerprint != currentRegistrationFingerprint
    }

    private func persistRegisteredFingerprint() {
        UserDefaults.standard.set(currentRegistrationFingerprint, forKey: registrationFingerprintKey)
    }

    private func fileSignature(at url: URL?) -> String {
        guard let url else { return "missing" }
        guard let data = try? Data(contentsOf: url) else { return "unreadable" }
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func clearPersistedRegistrationState() {
        UserDefaults.standard.removeObject(forKey: registrationFingerprintKey)
    }

    private func registerDaemon() throws {
        do {
            try daemonService.register()
        } catch let error as NSError {
            if error.domain == SMAppServiceErrorDomain && error.code == kSMErrorAlreadyRegistered {
                return
            }
            throw error
        }
    }

    private func repairRegistrationIfNeeded() {
        if bundledHelperURL == nil || bundledDaemonPlistURL == nil {
            if daemonService.status == .enabled || daemonService.status == .requiresApproval {
                print("[SensorHelperManager] Bundled artifacts are missing; unregistering stale helper daemon")
                unregisterDaemonIfNeeded()
            }
            clearPersistedRegistrationState()
            return
        }

        if daemonService.status == .notFound {
            print("[SensorHelperManager] Found orphaned helper registration; unregistering stale daemon state")
            unregisterDaemonIfNeeded()
            clearPersistedRegistrationState()
            return
        }

        if shouldRefreshRegistration {
            switch daemonService.status {
            case .enabled, .requiresApproval:
                // Keep the current registration alive on startup. Tearing it down before a
                // successful re-register leaves the app with no helper at all.
                print("[SensorHelperManager] Helper registration fingerprint changed; keeping existing daemon registration")
            case .notRegistered, .notFound:
                print("[SensorHelperManager] Helper registration fingerprint changed; refreshing daemon registration")
                unregisterDaemonIfNeeded()
                clearPersistedRegistrationState()
            @unknown default:
                print("[SensorHelperManager] Helper registration fingerprint changed; refreshing daemon registration")
                unregisterDaemonIfNeeded()
                clearPersistedRegistrationState()
            }
        }
    }

    private func unregisterDaemonIfNeeded() {
        do {
            try daemonService.unregister()
        } catch let error as NSError {
            if error.domain == SMAppServiceErrorDomain && error.code == kSMErrorJobNotFound {
                return
            }
            print("[SensorHelperManager] Failed to unregister existing daemon: \(error.localizedDescription)")
        }
    }
}
