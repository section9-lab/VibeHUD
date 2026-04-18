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
