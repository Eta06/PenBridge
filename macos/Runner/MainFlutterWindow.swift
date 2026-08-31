import Cocoa
import FlutterMacOS
import ApplicationServices

final class MainFlutterWindow: NSWindow {
  private var channel: FlutterMethodChannel?
  private var pointerIsDown = false
  private var inProximity = false
  private var relativeLocation = NSEvent.mouseLocation
  private let deviceID: Int64 = 0x5042

  override func awakeFromNib() {
    let controller = FlutterViewController()
    let windowFrame = frame
    contentViewController = controller
    setFrame(windowFrame, display: true)
    RegisterGeneratedPlugins(registry: controller)

    channel = FlutterMethodChannel(name: "io.penbridge/input", binaryMessenger: controller.engine.binaryMessenger)
    channel?.setMethodCallHandler { [weak self] call, result in
      switch call.method {
      case "injectBatch":
        guard let typedData = call.arguments as? FlutterStandardTypedData else {
          result(FlutterError(code: "bad_batch", message: "Invalid input batch", details: nil))
          return
        }
        self?.injectBatch(typedData.data)
        result(nil)
      case "injectInput":
        guard let packet = call.arguments as? [String: Any] else {
          result(FlutterError(code: "bad_packet", message: "Invalid input packet", details: nil))
          return
        }
        self?.inject(packet)
        result(nil)
      case "checkAccessibility":
        result(AXIsProcessTrusted())
      case "requestAccessibility":
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(options)
        if !trusted {
          DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
          }
        }
        result(trusted)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
      let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
      _ = AXIsProcessTrustedWithOptions(options)
    }
    super.awakeFromNib()
  }

  private func injectBatch(_ data: Data) {
    let bytes = [UInt8](data)
    guard bytes.count >= 40 else { return }
    let modes = ["pen", "mouse", "trackpad", "blender"]
    let tools = ["draw", "orbit", "pan", "zoom"]
    let actions = ["hover", "down", "drag", "up"]

    func float(at offset: Int) -> Double {
      let bits = UInt32(bytes[offset])
        | UInt32(bytes[offset + 1]) << 8
        | UInt32(bytes[offset + 2]) << 16
        | UInt32(bytes[offset + 3]) << 24
      return Double(Float(bitPattern: bits))
    }

    for base in stride(from: 0, through: bytes.count - 40, by: 40) {
      guard bytes[base] == 1 else { continue }
      let modeIndex = min(Int(bytes[base + 1]), modes.count - 1)
      let toolIndex = min(Int(bytes[base + 2]), tools.count - 1)
      let actionIndex = min(Int(bytes[base + 3]), actions.count - 1)
      let buttonBits = UInt32(bytes[base + 32])
        | UInt32(bytes[base + 33]) << 8
        | UInt32(bytes[base + 34]) << 16
        | UInt32(bytes[base + 35]) << 24
      inject([
        "action": actions[actionIndex],
        "mode": modes[modeIndex],
        "tool": tools[toolIndex],
        "x": float(at: base + 4),
        "y": float(at: base + 8),
        "dx": float(at: base + 12),
        "dy": float(at: base + 16),
        "pressure": float(at: base + 20),
        "tilt": float(at: base + 24),
        "orientation": float(at: base + 28),
        "buttons": Int64(Int32(bitPattern: buttonBits)),
        "inverted": bytes[base + 36] == 1,
      ])
    }
  }

  private func inject(_ packet: [String: Any]) {
    guard let action = packet["action"] as? String else { return }
    let mode = packet["mode"] as? String ?? "pen"
    let tool = packet["tool"] as? String ?? "draw"
    let absolute = absolutePoint(packet)
    let location = mode == "trackpad" ? relativePoint(packet) : absolute

    if mode == "blender" && tool == "zoom" {
      if action == "drag", let dy = (packet["dy"] as? NSNumber)?.doubleValue {
        postScroll(delta: dy)
      }
      return
    }

    let tablet = mode == "pen" || (mode == "blender" && tool == "draw")
    let middle = mode == "blender" && (tool == "orbit" || tool == "pan")
    let button: CGMouseButton = middle ? .center : .left
    let type = mouseType(action: action, middle: middle)
    guard let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: location, mouseButton: button) else { return }

    if mode == "blender" && tool == "pan" { event.flags.insert(.maskShift) }
    if tablet { applyTabletFields(event, packet: packet, location: location) }
    event.post(tap: .cghidEventTap)
  }

  private func mouseType(action: String, middle: Bool) -> CGEventType {
    switch action {
    case "down":
      pointerIsDown = true
      return middle ? .otherMouseDown : .leftMouseDown
    case "up":
      pointerIsDown = false
      return middle ? .otherMouseUp : .leftMouseUp
    case "drag":
      guard pointerIsDown else { return .mouseMoved }
      return middle ? .otherMouseDragged : .leftMouseDragged
    default:
      return .mouseMoved
    }
  }

  private func absolutePoint(_ packet: [String: Any]) -> CGPoint {
    let x = (packet["x"] as? NSNumber)?.doubleValue ?? 0
    let y = (packet["y"] as? NSNumber)?.doubleValue ?? 0
    let bounds = CGDisplayBounds(CGMainDisplayID())
    return CGPoint(x: bounds.minX + x * bounds.width, y: bounds.minY + y * bounds.height)
  }

  private func relativePoint(_ packet: [String: Any]) -> CGPoint {
    let bounds = CGDisplayBounds(CGMainDisplayID())
    let dx = (packet["dx"] as? NSNumber)?.doubleValue ?? 0
    let dy = (packet["dy"] as? NSNumber)?.doubleValue ?? 0
    relativeLocation.x = min(bounds.maxX, max(bounds.minX, relativeLocation.x + dx * 1.45))
    relativeLocation.y = min(bounds.maxY, max(bounds.minY, relativeLocation.y + dy * 1.45))
    return relativeLocation
  }

  private func applyTabletFields(_ event: CGEvent, packet: [String: Any], location: CGPoint) {
    let pressure = (packet["pressure"] as? NSNumber)?.doubleValue ?? 0
    let tilt = (packet["tilt"] as? NSNumber)?.doubleValue ?? 0
    let orientation = (packet["orientation"] as? NSNumber)?.doubleValue ?? 0
    let buttons = (packet["buttons"] as? NSNumber)?.int64Value ?? 0
    let inverted = (packet["inverted"] as? NSNumber)?.boolValue ?? false
    if !inProximity { postProximity(entering: true, inverted: inverted) }
    let magnitude = sin(max(0, min(.pi / 2, tilt)))
    event.setIntegerValueField(.mouseEventSubtype, value: 1)
    event.setDoubleValueField(.mouseEventPressure, value: pressure)
    event.setIntegerValueField(.tabletEventPointX, value: Int64(location.x))
    event.setIntegerValueField(.tabletEventPointY, value: Int64(location.y))
    event.setIntegerValueField(.tabletEventPointButtons, value: buttons)
    event.setDoubleValueField(.tabletEventPointPressure, value: pressure)
    event.setDoubleValueField(.tabletEventTiltX, value: magnitude * cos(orientation))
    event.setDoubleValueField(.tabletEventTiltY, value: magnitude * sin(orientation))
    event.setIntegerValueField(.tabletEventDeviceID, value: deviceID)
  }

  private func postScroll(delta: Double) {
    let amount = Int32(max(-12, min(12, delta.rounded())))
    guard amount != 0, let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: amount, wheel2: 0, wheel3: 0) else { return }
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
