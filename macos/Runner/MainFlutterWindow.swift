import Cocoa
import FlutterMacOS
import ApplicationServices

final class MainFlutterWindow: NSWindow {
  private var channel: FlutterMethodChannel?
  private var penIsDown = false
  private var inProximity = false
  private let deviceID: Int64 = 0x5042

  override func awakeFromNib() {
    let controller = FlutterViewController()
    let windowFrame = frame
    contentViewController = controller
    setFrame(windowFrame, display: true)
    RegisterGeneratedPlugins(registry: controller)

    channel = FlutterMethodChannel(
      name: "io.penbridge/input",
      binaryMessenger: controller.engine.binaryMessenger
    )
    channel?.setMethodCallHandler { [weak self] call, result in
      switch call.method {
      case "injectStylus":
        guard let packet = call.arguments as? [String: Any] else {
          result(FlutterError(code: "bad_packet", message: "Invalid stylus packet", details: nil))
          return
        }
        self?.inject(packet)
        result(nil)
      case "requestAccessibility":
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        result(AXIsProcessTrustedWithOptions(options))
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    super.awakeFromNib()
  }

  private func inject(_ packet: [String: Any]) {
    guard
      let x = (packet["x"] as? NSNumber)?.doubleValue,
      let y = (packet["y"] as? NSNumber)?.doubleValue,
      let action = packet["action"] as? String
    else { return }

    let pressure = (packet["pressure"] as? NSNumber)?.doubleValue ?? 0
    let tilt = (packet["tilt"] as? NSNumber)?.doubleValue ?? 0
    let orientation = (packet["orientation"] as? NSNumber)?.doubleValue ?? 0
    let buttons = (packet["buttons"] as? NSNumber)?.int64Value ?? 0
    let inverted = (packet["inverted"] as? NSNumber)?.boolValue ?? false
    let bounds = CGDisplayBounds(CGMainDisplayID())
    let location = CGPoint(
      x: bounds.minX + x * bounds.width,
      y: bounds.minY + y * bounds.height
    )

    if !inProximity { postProximity(entering: true, inverted: inverted) }

    let type: CGEventType
    switch action {
    case "down":
      type = .leftMouseDown
      penIsDown = true
    case "up":
      type = .leftMouseUp
      penIsDown = false
    case "drag":
      type = penIsDown ? .leftMouseDragged : .mouseMoved
    default:
      type = .mouseMoved
    }

    guard let event = CGEvent(
      mouseEventSource: nil,
      mouseType: type,
      mouseCursorPosition: location,
      mouseButton: .left
    ) else { return }

    let altitude = max(0, min(.pi / 2, .pi / 2 - tilt))
    let tiltMagnitude = cos(altitude)
    let tiltX = tiltMagnitude * cos(orientation)
    let tiltY = tiltMagnitude * sin(orientation)

    event.setIntegerValueField(.mouseEventSubtype, value: 1)
    event.setDoubleValueField(.mouseEventPressure, value: pressure)
    event.setIntegerValueField(.tabletEventPointX, value: Int64(location.x))
    event.setIntegerValueField(.tabletEventPointY, value: Int64(location.y))
    event.setIntegerValueField(.tabletEventPointButtons, value: buttons)
    event.setDoubleValueField(.tabletEventPointPressure, value: pressure)
    event.setDoubleValueField(.tabletEventTiltX, value: tiltX)
    event.setDoubleValueField(.tabletEventTiltY, value: tiltY)
    event.setIntegerValueField(.tabletEventDeviceID, value: deviceID)
    event.post(tap: .cghidEventTap)
  }

  private func postProximity(entering: Bool, inverted: Bool) {
    guard let event = CGEvent(source: nil) else { return }
    event.type = .tabletProximity
    event.setIntegerValueField(.tabletProximityEventVendorID, value: 0x5042)
    event.setIntegerValueField(.tabletProximityEventTabletID, value: deviceID)
    event.setIntegerValueField(.tabletProximityEventPointerID, value: 1)
    event.setIntegerValueField(.tabletProximityEventDeviceID, value: deviceID)
    event.setIntegerValueField(.tabletProximityEventPointerType, value: inverted ? 3 : 1)
    event.setIntegerValueField(.tabletProximityEventEnterProximity, value: entering ? 1 : 0)
    event.post(tap: .cghidEventTap)
    inProximity = entering
  }
}
