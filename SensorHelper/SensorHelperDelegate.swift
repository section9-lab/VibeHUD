import AppleSPUAccelerometer
import Darwin
import Foundation

@objc protocol SensorHelperXPCProtocol {
    func ping(_ reply: @escaping (Bool) -> Void)
    func startMonitoring()
    func stopMonitoring()
    func setSensitivity(_ minAmplitude: Double)
    func setEnabled(_ enabled: Bool)
    func setClientEndpoint(_ endpoint: NSXPCListenerEndpoint)
}

@objc protocol SensorHelperClientXPCProtocol {
    func didReceiveSingleTap(_ amplitude: Double)
    func didReceiveDoubleTap(_ amplitude: Double)
    func helperDidFail(_ message: String)
}

final class SensorHelperDelegate: NSObject, NSXPCListenerDelegate {
    private let service = SensorHelperService()

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        newConnection.exportedInterface = NSXPCInterface(with: SensorHelperXPCProtocol.self)
        newConnection.exportedObject = service
        newConnection.invalidationHandler = { [weak service] in
            service?.handleClientDisconnect(for: newConnection)
        }
        newConnection.interruptionHandler = { [weak service] in
            service?.handleClientDisconnect(for: newConnection)
        }
        service.attachControlConnection(newConnection)
        newConnection.resume()
        return true
    }
}

final class SensorHelperService: NSObject, SensorHelperXPCProtocol {
    private var accelerometer: SPUAccelerometer?
    private var controlConnection: NSXPCConnection?
    private var clientConnection: NSXPCConnection?
    private var minAmplitude: Double = 0.005
    private var isTapDetectionEnabled = true
    private let stateQueue = DispatchQueue(label: "com.section9-lab.VibeHUD.SensorHelper.state")
    private var idleExitWorkItem: DispatchWorkItem?

    func attachControlConnection(_ connection: NSXPCConnection) {
        stateQueue.async {
            self.cancelIdleExitLocked()
            self.controlConnection = connection
        }
    }

    func ping(_ reply: @escaping (Bool) -> Void) {
        reply(true)
    }

    func setClientEndpoint(_ endpoint: NSXPCListenerEndpoint) {
        let connection = NSXPCConnection(listenerEndpoint: endpoint)
        connection.remoteObjectInterface = NSXPCInterface(with: SensorHelperClientXPCProtocol.self)
        connection.invalidationHandler = { [weak self] in
            self?.handleCallbackDisconnect()
        }
        connection.interruptionHandler = { [weak self] in
            self?.handleCallbackDisconnect()
        }
        connection.resume()
        stateQueue.async {
            self.cancelIdleExitLocked()
            self.clientConnection?.invalidate()
            self.clientConnection = connection
        }
    }

    func setSensitivity(_ minAmplitude: Double) {
        self.minAmplitude = min(max(minAmplitude, 0.0015), 0.03)
    }

    func setEnabled(_ enabled: Bool) {
        isTapDetectionEnabled = enabled
    }

    func startMonitoring() {
        guard accelerometer == nil else { return }

        let accel = SPUAccelerometer()
        accel.trackTaps = true
        accel.onTap = { [weak self] kind, amplitude in
            guard let self else { return }
            guard self.isTapDetectionEnabled else { return }
            let amp = Double(amplitude)
            guard amp >= self.minAmplitude else { return }
            if kind == .single {
                self.remoteClient()?.didReceiveSingleTap(amp)
            } else if kind == .double {
                self.remoteClient()?.didReceiveDoubleTap(amp)
            }
        }

        do {
            try accel.start()
            accelerometer = accel
        } catch {
            remoteClient()?.helperDidFail("Accelerometer unavailable: \(error.localizedDescription)")
        }
    }

    func stopMonitoring() {
        accelerometer?.stop()
        accelerometer = nil
        scheduleIdleExitIfNeeded()
    }

    func handleClientDisconnect(for connection: NSXPCConnection) {
        stateQueue.async {
            guard self.controlConnection === connection else { return }
            self.controlConnection = nil
            self.clientConnection?.invalidate()
            self.clientConnection = nil
            DispatchQueue.main.async {
                self.stopMonitoring()
            }
        }
    }

    private func handleCallbackDisconnect() {
        stateQueue.async {
            self.clientConnection = nil
            self.scheduleIdleExitLocked()
        }
    }

    private func remoteClient() -> SensorHelperClientXPCProtocol? {
        clientConnection?.remoteObjectProxyWithErrorHandler { error in
            print("[SensorHelper] Client callback failed: \(error.localizedDescription)")
        } as? SensorHelperClientXPCProtocol
    }

    private func scheduleIdleExitIfNeeded() {
        stateQueue.async {
            self.scheduleIdleExitLocked()
        }
    }

    private func scheduleIdleExitLocked() {
        cancelIdleExitLocked()
        guard accelerometer == nil, controlConnection == nil, clientConnection == nil else { return }

        let workItem = DispatchWorkItem {
            exit(EXIT_SUCCESS)
        }
        idleExitWorkItem = workItem
        stateQueue.asyncAfter(deadline: .now() + 2, execute: workItem)
    }

    private func cancelIdleExitLocked() {
        idleExitWorkItem?.cancel()
        idleExitWorkItem = nil
    }
}
