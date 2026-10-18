import Foundation
import IOKit

final class StreamDeckOutput {
    let model: StreamDeckModel
    let write: (Data, Bool) -> IOReturn

    init(model: StreamDeckModel, write: @escaping (Data, Bool) -> IOReturn) {
        self.model = model
        self.write = write
    }
}

// One queued drain, at most one in-flight image and fifteen pending images. Repeated
// updates replace the pending key, so animation cannot build an unbounded USB backlog.
final class StreamDeckWritePump {
    let queue = DispatchQueue(label: "StreamDeckKit.HID.writes", qos: .userInitiated)
    var onResult: ((StreamDeckOutput, Int, IOReturn) -> Void)?
    private let lock = NSLock()
    private var output: StreamDeckOutput?
    private var desired: [Int: StreamDeckRaster] = [:]
    private var pending: [Int: StreamDeckRaster] = [:]
    private var order: [Int] = []
    private var desiredBrightness: Int?
    private var pendingBrightness: Int?
    private var scheduled = false
    // Cache state is confined to queue. Full raster keys avoid hash collision mistakes.
    private struct CacheKey: Hashable { let pixels: Data; let model: Int }
    private var cache: [CacheKey: Data] = [:]
    private var cacheOrder: [CacheKey] = []
    private var sent: [Int: StreamDeckRaster] = [:]
    private var sentOn: StreamDeckOutput?

    func connect(_ target: StreamDeckOutput?) {
        lock.lock()
        output = target
        pending = target == nil ? [:] : desired
        order = pending.keys.sorted()
        pendingBrightness = target == nil ? nil : desiredBrightness
        scheduleLocked()
        lock.unlock()
    }

    func image(_ raster: StreamDeckRaster, key: Int) {
        guard (0..<15).contains(key), raster.rgba.count == 72 * 72 * 4 else { return }
        lock.lock()
        desired[key] = raster
        if output != nil {
            if pending[key] == nil { order.append(key) }
            pending[key] = raster
        }
        scheduleLocked()
        lock.unlock()
    }

    func brightness(_ value: Int) {
        lock.lock()
        desiredBrightness = min(100, max(0, value))
        if output != nil { pendingBrightness = desiredBrightness }
        scheduleLocked()
        lock.unlock()
    }

    func clearCache() {
        queue.async { [self] in
            cache.removeAll(); cacheOrder.removeAll(); sent.removeAll()
        }
    }

    private func scheduleLocked() {
        guard !scheduled, output != nil, pendingBrightness != nil || !order.isEmpty else { return }
        scheduled = true
        queue.async { [self] in drainOne() }
    }

    private func isCurrent(_ target: StreamDeckOutput) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return output === target
    }

    private func drainOne() {
        lock.lock()
        let target = output
        let brightness = pendingBrightness
        pendingBrightness = nil
        var key: Int?
        var raster: StreamDeckRaster?
        if brightness == nil, !order.isEmpty {
            key = order.removeFirst()
            raster = pending.removeValue(forKey: key!)
        }
        lock.unlock()
        defer {
            lock.lock()
            scheduled = false
            scheduleLocked()
            lock.unlock()
        }
        guard let target, isCurrent(target) else { return }
        if sentOn !== target { sent.removeAll(); sentOn = target }
        var reports: [Data] = []
        if let brightness {
            reports = [StreamDeckProtocol.brightnessReport(brightness, model: target.model)]
        } else if let key, let raster, sent[key] != raster {
            // Skip work replaced before encoding started; an already-started transfer
            // finishes intact before the replacement is sent.
            lock.lock()
            let stillWanted = desired[key] == raster
            lock.unlock()
            guard stillWanted else { return }
            let cacheKey = CacheKey(pixels: raster.rgba, model: target.model.rawValue)
            let encoded: Data
            if let hit = cache[cacheKey] {
                encoded = hit
            } else {
                guard let result = StreamDeckImageEncoder.encode(raster, model: target.model) else { return }
                encoded = result
                if cacheOrder.count >= 64 { cache.removeValue(forKey: cacheOrder.removeFirst()) }
                cache[cacheKey] = result
                cacheOrder.append(cacheKey)
            }
            guard let packets = StreamDeckProtocol.imageReports(encoded, key: key, model: target.model) else { return }
            reports = packets
        }
        var count = 0
        var result = kIOReturnSuccess
        for report in reports {
            guard isCurrent(target) else { break }
            result = target.write(report, brightness != nil)
            guard result == kIOReturnSuccess else { break }
            count += 1
        }
        if count == reports.count, result == kIOReturnSuccess, let key, let raster { sent[key] = raster }
        if result != kIOReturnSuccess {
            lock.lock()
            if output === target { output = nil; pending.removeAll(); order.removeAll(); pendingBrightness = nil }
            lock.unlock()
        }
        if count > 0 || result != kIOReturnSuccess { onResult?(target, count, result) }
    }
}
