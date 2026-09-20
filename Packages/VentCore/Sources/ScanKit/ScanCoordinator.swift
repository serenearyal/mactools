import Foundation
import Synchronization

/// Runs one scan on a thread of its own and reports it as a stream.
///
/// A dedicated `Thread` at utility QoS rather than a task: `fts_read` blocks,
/// and a few minutes of blocking would starve a cooperative pool thread. The
/// thread also owns the dataless I/O policy, which is per thread.
public final class ScanCoordinator: Sendable {
    public struct Configuration: Sendable {
        public var root: String
        public var limit: Int
        public var skip: SkipList
        /// Display path of the home folder, for the folder breakdown.
        public var homeDirectory: String
        public var progressInterval: Double
        /// Entries between two cancel checks. A test on a tree of a few dozen
        /// files lowers it; nothing else should.
        public var tickInterval: Int

        public init(
            root: String = Scan.dataVolumePath,
            limit: Int = Scan.resultLimit,
            skip: SkipList = .default,
            homeDirectory: String = NSHomeDirectory(),
            progressInterval: Double = Scan.progressInterval,
            tickInterval: Int = Scan.cancelCheckInterval
        ) {
            self.root = root
            self.limit = limit
            self.skip = skip
            self.homeDirectory = homeDirectory
            self.progressInterval = progressInterval
            self.tickInterval = tickInterval
        }
    }

    public let configuration: Configuration
    private let cancelled = Mutex(false)

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    public convenience init(root: String, limit: Int = Scan.resultLimit) {
        self.init(configuration: Configuration(root: root, limit: limit))
    }

    /// Checked every `Scan.cancelCheckInterval` entries, so the walk stops
    /// well inside a second.
    public func cancel() {
        cancelled.withLock { $0 = true }
    }

    public var isCancelled: Bool { cancelled.withLock { $0 } }

    /// Starts the scan and returns its events. The stream ends after exactly
    /// one `.finished` or `.failed`.
    ///
    /// Progress is buffered newest-first and shallow: a consumer that falls
    /// behind loses stale ticks, never the terminal event.
    public func run() -> AsyncStream<ScanEvent> {
        let (stream, continuation) = AsyncStream<ScanEvent>.makeStream(
            bufferingPolicy: .bufferingNewest(4)
        )
        // The thread holds the coordinator alive until the walk ends, which
        // is what keeps `cancel()` valid for a caller that let go of it.
        let thread = Thread { self.scan(into: continuation) }
        thread.name = "com.serenearyal.vent.scan"
        thread.qualityOfService = QualityOfService.utility
        thread.stackSize = 1 << 20
        thread.start()
        return stream
    }

    private func scan(into continuation: AsyncStream<ScanEvent>.Continuation) {
        // First statement on this thread, before any stat can materialise a
        // placeholder.
        FTSWalker.disableDatalessMaterialisation()

        let started = Date()
        let startClock = Date.timeIntervalSinceReferenceDate
        var accumulator = ScanAccumulator(
            limit: configuration.limit,
            homeDirectory: configuration.homeDirectory
        )
        var throttle = ProgressThrottle(
            interval: configuration.progressInterval,
            start: startClock
        )

        let outcome: FTSWalker.Outcome
        do {
            outcome = try FTSWalker.walk(
                root: configuration.root,
                skip: configuration.skip,
                tickInterval: configuration.tickInterval,
                onTick: { [self] tally, directory in
                    if isCancelled { return false }
                    let now = Date.timeIntervalSinceReferenceDate
                    if throttle.shouldEmit(at: now) {
                        continuation.yield(
                            .progress(
                                ScanProgress(
                                    files: tally.files,
                                    allocated: tally.allocated,
                                    currentDirectory: directory,
                                    unreadable: tally.unreadable,
                                    elapsed: now - startClock
                                )
                            )
                        )
                    }
                    return true
                },
                onFile: { accumulator.add($0) }
            )
        } catch {
            continuation.yield(.failed(error))
            continuation.finish()
            return
        }

        continuation.yield(
            .finished(
                ScanResult(
                    root: PathMapper.display(configuration.root),
                    entries: accumulator.entries,
                    tally: outcome.tally,
                    homeFolders: accumulator.homeFolders,
                    rootFolders: accumulator.rootFolders,
                    started: started,
                    finished: Date(),
                    wasCancelled: outcome.wasCancelled
                )
            )
        )
        continuation.finish()
    }
}
