//
//  EventMonitors.swift
//  VibeHUD
//
//  Singleton that aggregates all event monitors
//

import AppKit
import Combine

class EventMonitors {
    static let shared = EventMonitors()

    let mouseLocation = CurrentValueSubject<CGPoint, Never>(.zero)
    let mouseDown = PassthroughSubject<NSEvent, Never>()

    /// Fires when the accelerometer detects a single tap or a debounced vibration trigger.
    let singleTap = PassthroughSubject<Date, Never>()

    /// Fires when the accelerometer detects a double-tap on the MacBook surface.
    let doubleTap = PassthroughSubject<Date, Never>()

    private var mouseMoveMonitor: EventMonitor?
    private var mouseDownMonitor: EventMonitor?
    private var mouseDraggedMonitor: EventMonitor?
    private let sensorClient = SensorServiceClient.shared
    private var cancellables = Set<AnyCancellable>()
    private let tapStateQueue = DispatchQueue(label: "com.section9-lab.VibeHUD.EventMonitors.tap")
    private let minSingleTapInterval: TimeInterval = 0.45
    private let singleTapDecisionWindow: TimeInterval = 0.22
    private let singleTapSuppressionAfterDouble: TimeInterval = 0.75
    private var lastSingleTapTime: TimeInterval = 0
    private var lastDoubleTapTime: TimeInterval = 0
    private var pendingSingleTapWorkItem: DispatchWorkItem?

    private init() {
        setupMonitors()
        setupSensorBridge()
    }

    private func setupMonitors() {
        mouseMoveMonitor = EventMonitor(mask: .mouseMoved) { [weak self] _ in
            self?.mouseLocation.send(NSEvent.mouseLocation)
        }
        mouseMoveMonitor?.start()

        mouseDownMonitor = EventMonitor(mask: .leftMouseDown) { [weak self] event in
            self?.mouseDown.send(event)
        }
        mouseDownMonitor?.start()

        mouseDraggedMonitor = EventMonitor(mask: .leftMouseDragged) { [weak self] _ in
            self?.mouseLocation.send(NSEvent.mouseLocation)
        }
        mouseDraggedMonitor?.start()
    }

    private func setupSensorBridge() {
        sensorClient.onSingleTap = { [weak self] amplitude in
            self?.emitSingleTap(source: "tap", amplitude: amplitude)
        }

        sensorClient.onDoubleTap = { [weak self] amplitude in
            self?.emitDoubleTap(amplitude: amplitude)
        }

        sensorClient.onVibrationTrigger = { [weak self] amplitude in
            self?.emitSingleTap(source: "vibration", amplitude: amplitude)
        }

        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .map { _ in (AppSettings.vibrationTapEnabled, AppSettings.vibrationTapMinAmplitude) }
            .removeDuplicates(by: { $0.0 == $1.0 && $0.1 == $1.1 })
            .receive(on: DispatchQueue.main)
            .sink { _ in
                SensorServiceClient.shared.sendCurrentSensitivity()
            }
            .store(in: &cancellables)

        sensorClient.start()
    }

    private func emitSingleTap(source: String, amplitude: Double) {
        guard AppSettings.vibrationTapEnabled else { return }

        tapStateQueue.async {
            let now = Date().timeIntervalSinceReferenceDate
            if now - self.lastDoubleTapTime < self.singleTapSuppressionAfterDouble {
                print("[EventMonitors] suppress single tap after recent double source=\(source) amp=\(String(format: "%.4f", amplitude))")
                return
            }
            if now - self.lastSingleTapTime < self.minSingleTapInterval {
                print("[EventMonitors] suppress burst single tap source=\(source) amp=\(String(format: "%.4f", amplitude))")
                return
            }

            if self.pendingSingleTapWorkItem != nil {
                print("[EventMonitors] coalesce pending single tap source=\(source) amp=\(String(format: "%.4f", amplitude))")
                return
            }

            let workItem = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.tapStateQueue.async {
                    self.pendingSingleTapWorkItem = nil
                    self.lastSingleTapTime = Date().timeIntervalSinceReferenceDate
                    DispatchQueue.main.async {
                        self.singleTap.send(Date())
                    }
                }
            }

            self.pendingSingleTapWorkItem = workItem
            self.tapStateQueue.asyncAfter(deadline: .now() + self.singleTapDecisionWindow, execute: workItem)
        }
    }

    private func emitDoubleTap(amplitude: Double) {
        guard AppSettings.vibrationTapEnabled else { return }

        tapStateQueue.async {
            let now = Date().timeIntervalSinceReferenceDate
            self.pendingSingleTapWorkItem?.cancel()
            self.pendingSingleTapWorkItem = nil
            self.lastDoubleTapTime = now
            self.lastSingleTapTime = now
            DispatchQueue.main.async {
                self.doubleTap.send(Date())
            }
            print("[EventMonitors] emit double tap amp=\(String(format: "%.4f", amplitude))")
        }
    }

    deinit {
        mouseMoveMonitor?.stop()
        mouseDownMonitor?.stop()
        mouseDraggedMonitor?.stop()
        sensorClient.stop()
    }
}
