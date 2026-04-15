import Foundation

final class SensorServiceClient: NSObject {
    static let shared = SensorServiceClient()

    static let machServiceName = "com.section9-lab.VibeHUD.SensorHelper"

    var onSingleTap: ((Double) -> Void)?
    var onDoubleTap: ((Double) -> Void)?

    private var helperConnection: NSXPCConnection?
    private var callbackListener: NSXPCListener?
    private var isRunning = false
    private var didAttemptRegistration = false

    private override init() {
        super.init()
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        setupCallbackListener()
        connectToHelper()
        checkHelperHealth()
        sendCurrentSensitivity()
        helperProxy()?.startMonitoring()
    }

    func stop() {
        helperProxy()?.stopMonitoring()
        callbackListener?.invalidate()
        callbackListener = nil
        helperConnection?.invalidate()
        helperConnection = nil
        isRunning = false
    }

    func sendCurrentSensitivity() {
        helperProxy()?.setEnabled(AppSettings.vibrationTapEnabled)
        helperProxy()?.setSensitivity(AppSettings.vibrationTapMinAmplitude)
    }

    private func setupCallbackListener() {
        let listener = NSXPCListener.anonymous()
        listener.delegate = self
        listener.resume()
        callbackListener = listener
    }

    private func connectToHelper() {
        let connection = NSXPCConnection(
            machServiceName: Self.machServiceName,
            options: .privileged
        )
        connection.remoteObjectInterface = NSXPCInterface(with: SensorHelperXPCProtocol.self)
        connection.invalidationHandler = { [weak self] in
            self?.helperConnection = nil
        }
        connection.interruptionHandler = { [weak self] in
            self?.helperConnection = nil
        }
        connection.resume()
        helperConnection = connection

        if let endpoint = callbackListener?.endpoint {
            helperProxy()?.setClientEndpoint(endpoint)
        }
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

extension SensorServiceClient: NSXPCListenerDelegate, SensorHelperClientXPCProtocol {
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        newConnection.exportedInterface = NSXPCInterface(with: SensorHelperClientXPCProtocol.self)
        newConnection.exportedObject = self
        newConnection.resume()
        return true
    }

    func didReceiveSingleTap(_ amplitude: Double) {
        onSingleTap?(amplitude)
    }

    func didReceiveDoubleTap(_ amplitude: Double) {
        onDoubleTap?(amplitude)
    }

    func helperDidFail(_ message: String) {
        print("[SensorServiceClient] Helper error: \(message)")
    }
}
