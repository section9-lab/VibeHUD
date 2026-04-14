//
//  EventMonitors.swift
//  VibeHUD
//
//  Singleton that aggregates all event monitors
//

import AppKit
import AppleSPUAccelerometer
import Combine

class EventMonitors {
    static let shared = EventMonitors()

    let mouseLocation = CurrentValueSubject<CGPoint, Never>(.zero)
    let mouseDown = PassthroughSubject<NSEvent, Never>()

    /// Fires when the accelerometer detects a double-tap on the MacBook surface.
    let doubleTap = PassthroughSubject<Date, Never>()

    private var mouseMoveMonitor: EventMonitor?
    private var mouseDownMonitor: EventMonitor?
    private var mouseDraggedMonitor: EventMonitor?
    private var accelerometer: SPUAccelerometer?

    private init() {
        setupMonitors()
        setupAccelerometer()
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

    private func setupAccelerometer() {
        let accel = SPUAccelerometer()
        accel.trackTaps = true

        accel.onTap = { [weak self] kind, _ in
            if kind == .double {
                self?.doubleTap.send(Date())
            }
        }

        do {
            try accel.start()
            accelerometer = accel
        } catch {
            print("[EventMonitors] Accelerometer unavailable: \(error)")
        }
    }

    deinit {
        mouseMoveMonitor?.stop()
        mouseDownMonitor?.stop()
        mouseDraggedMonitor?.stop()
        accelerometer?.stop()
    }
}
