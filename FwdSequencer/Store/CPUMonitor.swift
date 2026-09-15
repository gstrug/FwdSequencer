import Foundation
import Combine

/// Process CPU load, for the transport readout.
///
/// Hosting AUv3s is the app's main cost and the ceiling is real — a single master
/// limiter once caused audible crackle with a heavy sampled instrument. Effects multiply
/// that, so the point of this is to see the limit approaching rather than to discover it
/// as a dropout.
///
/// Reported as a fraction of ONE core, the way a per-process figure is usually read.
/// That is the number that matters here: audio is rendered on a single thread, so a
/// device with spare cores elsewhere can still run out of room for it.
@MainActor
final class CPUMonitor: ObservableObject {
    /// 1.0 means a whole core. Can exceed 1 — plugins render on their own threads.
    @Published private(set) var load: Double = 0

    /// Above this the readout warns. Not a cliff: dropouts depend on how the work falls
    /// across buffers, so this is where to start paying attention, not where it breaks.
    static let warningLoad: Double = 0.70

    private var timer: Timer?

    /// Twice a second — enough to watch a level, cheap enough to leave running, and slow
    /// enough that reading it does not itself become a cost worth measuring.
    func start() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            let sample = Self.currentProcessLoad()
            Task { @MainActor in self?.load = sample }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    deinit { timer?.invalidate() }

    /// Sum the CPU of every thread in this process.
    ///
    /// `task_threads` hands back an allocation the caller owns, so it is freed on every
    /// path — this runs twice a second forever, and a leak here would dwarf whatever it
    /// was measuring.
    nonisolated static func currentProcessLoad() -> Double {
        var threads: thread_act_array_t?
        var count = mach_msg_type_number_t(0)
        guard task_threads(mach_task_self_, &threads, &count) == KERN_SUCCESS,
              let threads else { return 0 }
        defer {
            for index in 0..<Int(count) { mach_port_deallocate(mach_task_self_, threads[index]) }
            vm_deallocate(mach_task_self_,
                          vm_address_t(UInt(bitPattern: threads)),
                          vm_size_t(Int(count) * MemoryLayout<thread_t>.stride))
        }

        var total: Double = 0
        for index in 0..<Int(count) {
            var info = thread_basic_info()
            // THREAD_BASIC_INFO_COUNT is a C macro and so invisible to Swift; it is
            // just the struct measured in integer_t words.
            var infoCount = mach_msg_type_number_t(
                MemoryLayout<thread_basic_info_data_t>.size / MemoryLayout<integer_t>.size)
            let result = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(infoCount)) {
                    thread_info(threads[index], thread_flavor_t(THREAD_BASIC_INFO), $0, &infoCount)
                }
            }
            guard result == KERN_SUCCESS, info.flags & TH_FLAGS_IDLE == 0 else { continue }
            total += Double(info.cpu_usage) / Double(TH_USAGE_SCALE)
        }
        return total
    }
}
