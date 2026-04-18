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
    func didReceiveVibrationTrigger(_ amplitude: Double)
    func helperDidFail(_ message: String)
}

final class SensorHelperDelegate: NSObject, NSXPCListenerDelegate {
    private let service = SensorHelperService()

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        newConnection.exportedInterface = NSXPCInterface(with: SensorHelperXPCProtocol.self)
        newConnection.exportedObject = service
        newConnection.remoteObjectInterface = NSXPCInterface(with: SensorHelperClientXPCProtocol.self)
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
    private let minVibrationTriggerInterval: TimeInterval = 0.3
    private let vibrationTapDedupWindow: TimeInterval = 0.35
    private var lastTapDispatchTime: TimeInterval = 0
    private var lastVibrationDispatchTime: TimeInterval = 0
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
        self.minAmplitude = min(max(minAmplitude, 0.0002), 0.03)
        print("[SensorHelper] setSensitivity minAmplitude=\(self.minAmplitude)")
    }

    func setEnabled(_ enabled: Bool) {
        isTapDetectionEnabled = enabled
        print("[SensorHelper] setEnabled enabled=\(enabled)")
    }

    func startMonitoring() {
        guard accelerometer == nil else { return }
        print("[SensorHelper] startMonitoring")

        let accel = SPUAccelerometer(callbackQueue: .global(qos: .userInitiated))
        accel.trackTaps = true
        accel.onTap = { [weak self] kind, amplitude in
            guard let self else { return }
            guard self.isTapDetectionEnabled else { return }
            let now = ProcessInfo.processInfo.systemUptime
            self.lastTapDispatchTime = now
            let amp = Double(amplitude)
            print("[SensorHelper] tap detected kind=\(kind.rawValue) amp=\(String(format: "%.4f", amp)) threshold=\(String(format: "%.4f", self.minAmplitude))")
            guard amp >= self.minAmplitude else {
                print("[SensorHelper] ignoring tap below threshold")
                return
            }
            if kind == .single {
                self.remoteClient()?.didReceiveSingleTap(amp)
            } else if kind == .double {
                self.remoteClient()?.didReceiveDoubleTap(amp)
            }
        }
        accel.onEvent = { [weak self] event in
            guard let self else { return }
            guard self.isTapDetectionEnabled else { return }
            print("[SensorHelper] vibration event severity=\(event.severity.label) amp=\(String(format: "%.4f", event.amplitude)) threshold=\(String(format: "%.4f", self.minAmplitude))")
            guard event.amplitude >= self.minAmplitude else {
                print("[SensorHelper] ignoring vibration below threshold")
                return
            }

            let now = ProcessInfo.processInfo.systemUptime
            guard now - self.lastTapDispatchTime > self.vibrationTapDedupWindow else {
                print("[SensorHelper] ignoring vibration due to tap dedup window")
                return
            }
            guard now - self.lastVibrationDispatchTime > self.minVibrationTriggerInterval else {
                print("[SensorHelper] ignoring vibration due to trigger interval")
                return
            }

            self.lastVibrationDispatchTime = now
            print("[SensorHelper] dispatching vibration trigger to client")
            self.remoteClient()?.didReceiveVibrationTrigger(event.amplitude)
        }

        do {
            try accel.start()
            accelerometer = accel
            print("[SensorHelper] accelerometer started")
        } catch {
            print("[SensorHelper] accelerometer start failed: \(error.localizedDescription)")
            remoteClient()?.helperDidFail("Accelerometer unavailable: \(error.localizedDescription)")
        }
    }

    func stopMonitoring() {
        print("[SensorHelper] stopMonitoring")
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
        if let controlConnection {
            return controlConnection.remoteObjectProxyWithErrorHandler { error in
                print("[SensorHelper] Control connection callback failed: \(error.localizedDescription)")
            } as? SensorHelperClientXPCProtocol
        }

        return clientConnection?.remoteObjectProxyWithErrorHandler { error in
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
