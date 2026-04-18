import Foundation

final class SensorServiceClient: NSObject {
    static let shared = SensorServiceClient()

    static let machServiceName = "com.section9-lab.VibeHUD.SensorHelper"

    var onSingleTap: ((Double) -> Void)?
    var onDoubleTap: ((Double) -> Void)?
    var onVibrationTrigger: ((Double) -> Void)?

    private var helperConnection: NSXPCConnection?
    private var isRunning = false
    private var didAttemptRegistration = false

    private override init() {
        super.init()
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        print("[SensorServiceClient] start")
        tryRegisterHelperOnce()
        connectToHelper()
        checkHelperHealth()
        sendCurrentSensitivity()
        helperProxy()?.startMonitoring()
    }

    func stop() {
        helperProxy()?.stopMonitoring()
        helperConnection?.invalidate()
        helperConnection = nil
        isRunning = false
    }

    func sendCurrentSensitivity() {
        print("[SensorServiceClient] sendCurrentSensitivity enabled=\(AppSettings.vibrationTapEnabled) minAmplitude=\(AppSettings.vibrationTapMinAmplitude)")
        helperProxy()?.setEnabled(AppSettings.vibrationTapEnabled)
        helperProxy()?.setSensitivity(AppSettings.vibrationTapMinAmplitude)
    }

    private func connectToHelper() {
        let connection = NSXPCConnection(
            machServiceName: Self.machServiceName,
            options: .privileged
        )
        connection.remoteObjectInterface = NSXPCInterface(with: SensorHelperXPCProtocol.self)
        connection.exportedInterface = NSXPCInterface(with: SensorHelperClientXPCProtocol.self)
        connection.exportedObject = self
        connection.invalidationHandler = { [weak self] in
            self?.helperConnection = nil
        }
        connection.interruptionHandler = { [weak self] in
            self?.helperConnection = nil
        }
        connection.resume()
        helperConnection = connection
    }

    private func helperProxy() -> SensorHelperXPCProtocol? {
        guard let helperConnection else { return nil }
        return helperConnection.remoteObjectProxyWithErrorHandler { error in
            print("[SensorServiceClient] Helper call failed: \(error.localizedDescription)")
            self.tryRegisterHelperOnce()
        } as? SensorHelperXPCProtocol
    }

    private func checkHelperHealth() {
        helperProxy()?.ping { [weak self] ok in
            guard let self else { return }
            if !ok {
                self.tryRegisterHelperOnce()
            }
        }
    }

    private func tryRegisterHelperOnce() {
        guard !didAttemptRegistration else { return }
        didAttemptRegistration = true
        DispatchQueue.global(qos: .userInitiated).async {
            let installed = SensorPrivilegedHelperManager.shared.installHelper()
            if installed {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    self.connectToHelper()
                    self.sendCurrentSensitivity()
                    self.helperProxy()?.startMonitoring()
                }
            } else {
                print("[SensorServiceClient] Helper daemon is not ready yet. It may still require approval in System Settings.")
            }
        }
    }
}

extension SensorServiceClient: SensorHelperClientXPCProtocol {
    func didReceiveSingleTap(_ amplitude: Double) {
        print("[SensorServiceClient] received single tap amp=\(String(format: "%.4f", amplitude))")
        onSingleTap?(amplitude)
    }

    func didReceiveDoubleTap(_ amplitude: Double) {
        print("[SensorServiceClient] received double tap amp=\(String(format: "%.4f", amplitude))")
        onDoubleTap?(amplitude)
    }

    func didReceiveVibrationTrigger(_ amplitude: Double) {
        print("[SensorServiceClient] received vibration trigger amp=\(String(format: "%.4f", amplitude))")
        onVibrationTrigger?(amplitude)
    }

    func helperDidFail(_ message: String) {
        print("[SensorServiceClient] Helper error: \(message)")
    }
}
