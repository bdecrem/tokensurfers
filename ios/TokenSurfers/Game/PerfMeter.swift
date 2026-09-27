import Foundation
import UIKit
import QuartzCore

/// `TS_PERF=1`: a `[perf]` line every 2 s — the process's CPU (as a share of
/// one core, and of all cores), memory footprint, the thermal state and the
/// frames the game drew — so a build or a run can be measured on the phone
/// through `devicectl … launch --console` when Instruments won't attach
/// (iOS 27 beta, 2026-09-24).
enum PerfMeter {
    nonisolated(unsafe) static var frames = 0
    /// Per-window accounting (ms): the game frame (engine step + scene draw),
    /// the feed's apply per poll, and main-thread hitches seen as gaps between
    /// game frames of 40 ms or more (two or more dropped frames at 60 Hz).
    nonisolated(unsafe) static var frameMs = 0.0, frameMax = 0.0
    nonisolated(unsafe) static var applyMs = 0.0, applyMax = 0.0, applies = 0
    nonisolated(unsafe) static var hitches = 0, gapMax = 0.0
    nonisolated(unsafe) private static var lastFrameAt = 0.0
    nonisolated(unsafe) static var enabled = false

    /// Wraps the game's frame closure: call at the start and pass the value to `frameEnd`.
    @inline(__always) static func frameStart() -> Double { enabled ? CACurrentMediaTime() : 0 }
    static func frameEnd(_ t0: Double) {
        guard enabled else { return }
        let now = CACurrentMediaTime()
        let ms = (now - t0) * 1000
        frameMs += ms; frameMax = max(frameMax, ms)
        if lastFrameAt > 0 {
            let gap = (now - lastFrameAt) * 1000
            if gap >= 40 { hitches += 1; gapMax = max(gapMax, gap) }
        }
        lastFrameAt = now
    }
    static func applied(_ t0: Double) {
        guard enabled else { return }
        let ms = (CACurrentMediaTime() - t0) * 1000
        applyMs += ms; applyMax = max(applyMax, ms); applies += 1
    }
    private static var last = Date()
    private static var lastFrames = 0
    private static var mainThread: thread_t = 0

    static func start() {
        guard ProcessInfo.processInfo.environment["TS_PERF"] != nil else { return }
        // stdout is a pipe under `devicectl … launch --console`: without this the
        // lines sit in a 4 KB buffer and the console looks empty for minutes.
        setvbuf(stdout, nil, _IOLBF, 0)
        enabled = true
        mainThread = mach_thread_self()   // start() runs on the main thread
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in tick() }
    }

    private static func tick() {
        let now = Date()
        let dt = now.timeIntervalSince(last)
        last = now
        let f = frames
        let drawn = f - lastFrames
        let fps = Double(drawn) / max(dt, 0.001)
        lastFrames = f
        let frameAvg = drawn > 0 ? frameMs / Double(drawn) : 0
        let applyAvg = applies > 0 ? applyMs / Double(applies) : 0
        let detail = String(format: "frame %.1f ms (max %.0f) · apply %d× %.1f ms (max %.0f) · hitches %d (max gap %.0f ms)",
                            frameAvg, frameMax, applies, applyAvg, applyMax, hitches, gapMax)
        frameMs = 0; frameMax = 0; applyMs = 0; applyMax = 0; applies = 0; hitches = 0; gapMax = 0
        lastFrameAt = 0
        let cores = Double(ProcessInfo.processInfo.activeProcessorCount)
        let (cpu, main) = cpuUsage()
        let thermal: String
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: thermal = "nominal"
        case .fair: thermal = "fair"
        case .serious: thermal = "serious"
        case .critical: thermal = "critical"
        @unknown default: thermal = "?"
        }
        print(String(format: "[perf] cpu %.0f%% of one core (%.0f%% of %d) · main %.0f%% · mem %.0f MB · %@ · %.0f fps · %@",
                     cpu, cpu / cores, Int(cores), main, Double(footprint()) / 1_048_576, thermal, fps, detail))
    }

    /// Sum of the threads' current CPU usage in percent of one core, and the main thread's own.
    private static func cpuUsage() -> (Double, Double) {
        var threads: thread_act_array_t?
        var count = mach_msg_type_number_t(0)
        guard task_threads(mach_task_self_, &threads, &count) == KERN_SUCCESS, let threads else { return (0, 0) }
        defer { vm_deallocate(mach_task_self_, vm_address_t(bitPattern: threads), vm_size_t(count) * vm_size_t(MemoryLayout<thread_t>.size)) }
        var total = 0.0
        var main = 0.0
        for i in 0..<Int(count) {
            var info = thread_basic_info()
            var infoCount = mach_msg_type_number_t(MemoryLayout<thread_basic_info>.size / MemoryLayout<integer_t>.size)
            let ok = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(infoCount)) {
                    thread_info(threads[i], thread_flavor_t(THREAD_BASIC_INFO), $0, &infoCount)
                }
            }
            if ok == KERN_SUCCESS, info.flags & TH_FLAGS_IDLE == 0 {
                let pct = Double(info.cpu_usage) / Double(TH_USAGE_SCALE) * 100
                total += pct
                if threads[i] == mainThread { main = pct }
            }
        }
        return (total, main)
    }

    private static func footprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let ok = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return ok == KERN_SUCCESS ? info.phys_footprint : 0
    }
}
