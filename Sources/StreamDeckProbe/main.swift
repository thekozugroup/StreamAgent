import AppKit
import Combine
import StreamDeckKit

struct Options {
    var write = false
    var listenSeconds: Double = 0

    init(_ arguments: [String]) throws {
        var index = 0
        while index < arguments.count {
            switch arguments[index] {
            case "--write": write = true
            case "--listen-seconds":
                index += 1
                guard index < arguments.count, let value = Double(arguments[index]),
                      value.isFinite, (0...300).contains(value) else { throw ProbeError.arguments }
                listenSeconds = value
            case "--help", "-h":
                print("StreamDeckProbe [--write] [--listen-seconds 0...300]\nDefault: discovery only. --write: show 15 numbered SF Symbol keys at 60% brightness. All runs close the device.")
                exit(0)
            default: throw ProbeError.arguments
            }
            index += 1
        }
    }
}

enum ProbeError: Error { case arguments }

func emit(_ value: [String: Any]) {
    if let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
       let line = String(data: data, encoding: .utf8) { print(line); fflush(stdout) }
}

func spin(until deadline: Date, while condition: () -> Bool = { true }) {
    while Date() < deadline, condition() {
        _ = RunLoop.main.run(mode: .default, before: min(deadline, Date().addingTimeInterval(0.05)))
    }
}

func keyImage(index: Int) -> NSImage {
    let symbols = ["arrow.up", "bolt.fill", "play.fill", "pause.fill", "speaker.wave.2.fill",
                   "arrow.left", "folder.fill", "terminal.fill", "moon.fill", "sun.max.fill",
                   "arrow.down", "house.fill", "gearshape.fill", "checkmark", "arrow.right"]
    return NSImage(size: NSSize(width: 72, height: 72), flipped: false) { rect in
        NSColor(calibratedRed: 0.04, green: 0.09, blue: 0.16, alpha: 1).setFill()
        rect.fill()
        let configuration = NSImage.SymbolConfiguration(pointSize: 29, weight: .semibold)
            .applying(.init(paletteColors: [.white]))
        if let symbol = NSImage(systemSymbolName: symbols[index], accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration) {
            let bounds = NSRect(x: 18, y: 26, width: 36, height: 34)
            symbol.draw(in: bounds)
        }
        let label = String(format: "%02d", index + 1) as NSString
        label.draw(at: NSPoint(x: 26, y: 7), withAttributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium),
            .foregroundColor: NSColor.white])
        return true
    }
}

let options: Options
do { options = try Options(Array(CommandLine.arguments.dropFirst())) }
catch {
    emit(["error": "Usage: StreamDeckProbe [--write] [--listen-seconds 0...300]"])
    exit(64)
}
_ = NSApplication.shared
NSApp.setActivationPolicy(.prohibited)
let device = StreamDeckDevice()
var interrupted = false
signal(SIGINT, SIG_IGN)
signal(SIGTERM, SIG_IGN)
let interruptSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
let terminateSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
interruptSource.setEventHandler { interrupted = true }
terminateSource.setEventHandler { interrupted = true }
interruptSource.resume(); terminateSource.resume()
device.onKeyDown = { index in
    emit(["event": "keyDown", "key": index, "mainThread": Thread.isMainThread])
}
device.start()
spin(until: Date().addingTimeInterval(2), while: { !device.isConnected && !interrupted })
let discovered = device.isConnected
let model = device.modelName
var keysWritten = 0
var brightnessWritten = false
emit(["event": "discovery", "connected": discovered, "model": model, "status": device.statusMessage,
      "reportsSent": device.reportsSent])
if discovered, options.write, !interrupted {
    var baseline = device.reportsSent
    device.setBrightness(60)
    spin(until: Date().addingTimeInterval(2), while: { !interrupted && device.isConnected && device.reportsSent == baseline })
    brightnessWritten = device.isConnected && device.reportsSent > baseline
    if brightnessWritten {
        // The controller publishes reportsSent once each whole image transfer ends.
        // Wait for each key separately so partial writes cannot appear successful.
        for key in 0..<15 {
            guard !interrupted, device.isConnected else { break }
            baseline = device.reportsSent
            device.setKeyImage(keyImage(index: key), key: key)
            spin(until: Date().addingTimeInterval(2), while: { !interrupted && device.isConnected && device.reportsSent == baseline })
            guard device.isConnected, device.reportsSent > baseline else { break }
            keysWritten += 1
        }
    }
    emit(["event": "write", "connected": device.isConnected, "reportsSent": device.reportsSent,
          "keysWritten": keysWritten, "brightnessWritten": brightnessWritten, "status": device.statusMessage])
}
if discovered, options.listenSeconds > 0, !interrupted {
    emit(["event": "listening", "seconds": options.listenSeconds])
    spin(until: Date().addingTimeInterval(options.listenSeconds), while: { !interrupted })
}
let finalStatus = device.statusMessage
let wasConnected = device.isConnected
device.stop()
spin(until: Date().addingTimeInterval(3), while: { device.statusMessage != "Stopped" })
emit(["event": "finished", "discovered": discovered, "model": model,
      "connectedBeforeStop": wasConnected, "stopped": device.statusMessage == "Stopped",
      "keysWritten": keysWritten, "brightnessWritten": brightnessWritten,
      "reportsSent": device.reportsSent, "keyPressCount": device.keyPressCount,
      "lastKeyIndex": device.lastKeyIndex as Any? ?? NSNull(), "status": finalStatus])
let succeeded = discovered && (!options.write || (brightnessWritten && keysWritten == 15)) &&
    wasConnected && device.statusMessage == "Stopped"
exit(succeeded ? 0 : 1)
