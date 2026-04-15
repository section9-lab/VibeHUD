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

    /// Fires when the accelerometer detects a single tap on the MacBook surface.
    let singleTap = PassthroughSubject<Date, Never>()

    /// Fires when the accelerometer detects a double-tap on the MacBook surface.
    let doubleTap = PassthroughSubject<Date, Never>()

    private var mouseMoveMonitor: EventMonitor?
    private var mouseDownMonitor: EventMonitor?
    private var mouseDraggedMonitor: EventMonitor?
    private let sensorClient = SensorServiceClient.shared
    private var cancellables = Set<AnyCancellable>()

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
            guard AppSettings.vibrationTapEnabled else { return }
            guard amplitude >= AppSettings.vibrationTapMinAmplitude else { return }
            self?.singleTap.send(Date())
        }

        sensorClient.onDoubleTap = { [weak self] amplitude in
            guard AppSettings.vibrationTapEnabled else { return }
            guard amplitude >= AppSettings.vibrationTapMinAmplitude else { return }
            self?.doubleTap.send(Date())
        }

        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { _ in
                SensorServiceClient.shared.sendCurrentSensitivity()
            }
            .store(in: &cancellables)

        sensorClient.start()
    }

    deinit {
        mouseMoveMonitor?.stop()
        mouseDownMonitor?.stop()
        mouseDraggedMonitor?.stop()
        sensorClient.stop()
    }
}
