// Game-controller input through Apple's device-independent extended profile.
// This covers DualSense over Bluetooth as well as Xbox, Switch Pro and other
// controllers that macOS exposes through GameController.framework.

import Foundation
import GameController

final class GamepadInput {
    private weak var view: PlayerView?
    private let eventQueue = DispatchQueue(label: "local.psvr2player.controller-input",
                                           qos: .userInteractive)
    private var activeController: GCController?
    private var observers: [NSObjectProtocol] = []
    private var pollTimer: Timer?
    private var heldDirection: ControllerNavigationDirection?
    private var heldDirectionFromStick = false
    private var nextDirectionRepeat = 0.0
    private var dpadX: Float = 0
    private var dpadY: Float = 0
    private var stickX: Float = 0
    private var stickY: Float = 0
    private var rightX: Float = 0
    private var rightY: Float = 0

    var connectedName: String? {
        activeController.map { $0.vendorName ?? $0.productCategory }
    }

    init(view: PlayerView) {
        self.view = view

        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: .GCControllerDidConnect, object: nil, queue: .main
        ) { [weak self] note in
            guard let controller = note.object as? GCController else { return }
            self?.connect(controller, announce: true)
        })
        observers.append(center.addObserver(
            forName: .GCControllerDidDisconnect, object: nil, queue: .main
        ) { [weak self] note in
            guard let self, let controller = note.object as? GCController else { return }
            if self.activeController === controller {
                self.activeController = GCController.controllers().first {
                    $0 !== controller && $0.extendedGamepad != nil
                }
                self.resetAxes()
            }
            print("[controller] disconnected: \(controller.vendorName ?? controller.productCategory)")
        })

        for controller in GCController.controllers() where controller.extendedGamepad != nil {
            connect(controller, announce: false)
        }

        // Polling gives analog sticks a dead zone and makes held D-pad/stick
        // navigation repeat consistently, independent of device event rate.
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) {
            [weak self] _ in self?.tick()
        }
    }

    deinit {
        pollTimer?.invalidate()
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }

    private func connect(_ controller: GCController, announce: Bool) {
        guard let pad = controller.extendedGamepad else {
            print("[controller] ignoring controller without extended gamepad profile: "
                + (controller.vendorName ?? controller.productCategory))
            return
        }
        // Capture hardware edges away from the 120 Hz rendering queue. When
        // these callbacks share the main queue, a quick press and release can
        // be coalesced before the app gets a chance to observe the press.
        controller.handlerQueue = eventQueue
        activeController = controller

        bind(pad.buttonMenu, controller: controller) { [weak self] in
            self?.view?.gamepadToggleMenu()
        }
        bind(pad.buttonA, controller: controller) { [weak self] in
            self?.view?.gamepadPrimary()
        }
        bind(pad.buttonB, controller: controller) { [weak self] in
            self?.view?.gamepadSecondary()
        }
        bind(pad.buttonX, controller: controller) { [weak self] in
            self?.view?.gamepadPassthrough()
        }
        bind(pad.buttonY, controller: controller) { [weak self] in
            self?.view?.gamepadRecenter()
        }
        bind(pad.leftShoulder, controller: controller) { [weak self] in
            self?.view?.gamepadShoulder(forward: false)
        }
        bind(pad.rightShoulder, controller: controller) { [weak self] in
            self?.view?.gamepadShoulder(forward: true)
        }
        bindAxes(pad.dpad, controller: controller, fromStick: false)
        bindAxes(pad.leftThumbstick, controller: controller, fromStick: true)
        pad.rightThumbstick.valueChangedHandler = { [weak self, weak controller] _, x, y in
            guard let self, let controller else { return }
            DispatchQueue.main.async { [weak self, weak controller] in
                guard let self, let controller else { return }
                self.activeController = controller
                self.rightX = x
                self.rightY = y
            }
        }

        let name = controller.vendorName ?? controller.productCategory
        print("[controller] connected: \(name)")
        if announce { view?.renderer?.overlay?.showOSD("Controller connected: \(name)") }
    }

    private func bind(_ button: GCControllerButtonInput?, controller: GCController,
                      action: @escaping () -> Void) {
        button?.pressedChangedHandler = { [weak self, weak controller] _, _, pressed in
            guard pressed, let self else { return }
            let capturedAt = ProcessInfo.processInfo.systemUptime
            // The input queue captures every edge; AppKit/player state remains
            // main-thread-only.
            DispatchQueue.main.async { [weak self, weak controller] in
                guard let self else { return }
                let latencyMs = (ProcessInfo.processInfo.systemUptime - capturedAt) * 1000
                if latencyMs > 25 {
                    print(String(format: "[controller] main-queue input latency: %.1f ms", latencyMs))
                }
                if let controller { self.activeController = controller }
                action()
            }
        }
    }

    private func bindAxes(_ axes: GCControllerDirectionPad, controller: GCController,
                          fromStick: Bool) {
        axes.valueChangedHandler = { [weak self, weak controller] _, x, y in
            guard let self, let controller else { return }
            let capturedAt = ProcessInfo.processInfo.systemUptime
            DispatchQueue.main.async { [weak self, weak controller] in
                guard let self, let controller else { return }
                let latencyMs = (ProcessInfo.processInfo.systemUptime - capturedAt) * 1000
                if latencyMs > 25 {
                    print(String(format: "[controller] main-queue input latency: %.1f ms", latencyMs))
                }
                self.activeController = controller
                if fromStick {
                    self.stickX = x
                    self.stickY = y
                } else {
                    self.dpadX = x
                    self.dpadY = y
                }
                self.updateDirection()
            }
        }
    }

    private func updateDirection() {
        let usingDpad = abs(dpadX) > 0.5 || abs(dpadY) > 0.5
        let fromStick = !usingDpad
        let direction = directionFor(x: usingDpad ? dpadX : stickX,
                                     y: usingDpad ? dpadY : stickY)
        let now = ProcessInfo.processInfo.systemUptime
        if direction != heldDirection || (direction != nil && fromStick != heldDirectionFromStick) {
            heldDirection = direction
            heldDirectionFromStick = fromStick
            if let direction {
                view?.gamepadDirection(direction, fromStick: fromStick, repeated: false)
                nextDirectionRepeat = now + 0.38
            }
        }
    }

    private func tick() {
        guard activeController?.extendedGamepad != nil else {
            heldDirection = nil
            return
        }
        let now = ProcessInfo.processInfo.systemUptime
        if let direction = heldDirection, now >= nextDirectionRepeat {
            view?.gamepadDirection(direction, fromStick: heldDirectionFromStick, repeated: true)
            nextDirectionRepeat = now + 0.10
        }

        // Right-stick scene tilt is continuous. A cubic response gives fine
        // adjustment near the center without making full deflection sluggish.
        let rx = applyDeadZone(rightX)
        let ry = applyDeadZone(rightY)
        if rx != 0 || ry != 0 {
            view?.gamepadRotate(dx: Double(rx * abs(rx) * 7),
                                dy: Double(-ry * abs(ry) * 7))
        }
    }

    private func directionFor(x: Float, y: Float) -> ControllerNavigationDirection? {
        let threshold: Float = 0.62
        guard max(abs(x), abs(y)) >= threshold else { return nil }
        if abs(x) > abs(y) { return x < 0 ? .left : .right }
        return y < 0 ? .down : .up
    }

    private func applyDeadZone(_ value: Float) -> Float {
        let deadZone: Float = 0.18
        guard abs(value) > deadZone else { return 0 }
        return copysign((abs(value) - deadZone) / (1 - deadZone), value)
    }

    private func resetAxes() {
        dpadX = 0
        dpadY = 0
        stickX = 0
        stickY = 0
        rightX = 0
        rightY = 0
        heldDirection = nil
    }
}
