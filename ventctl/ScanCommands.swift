import Darwin
import Foundation

import ScanKit

enum ScanCommands {
    /// Walks a volume and prints the largest files.
    ///
    /// Progress goes to stderr and the result to stdout, so
    /// `ventctl scan > top.txt` keeps the live line on the terminal.
    static func scan(root: String, top: Int) throws {
        let path = (root as NSString).expandingTildeInPath
        let coordinator = ScanCoordinator(
            configuration: ScanCoordinator.Configuration(root: path, limit: max(top, Scan.resultLimit))
        )

        // SIG_IGN first: the default action would kill the process before the
        // dispatch source ever runs. The source lives on a global queue, so
        // it fires while the main thread waits on the semaphore.
        signal(SIGINT, SIG_IGN)
        let interrupts = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
        interrupts.setEventHandler {
            FileHandle.standardError.write(Data("\ncancelling...\n".utf8))
            coordinator.cancel()
        }
        interrupts.resume()
        defer { interrupts.cancel() }

        if !FullDiskAccess.isGranted() {
            warn("no Full Disk Access: protected folders will be counted as unreadable")
        }
        warn("scanning \(PathMapper.display(path)), Ctrl-C to stop")

        let finished = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var outcome: Result<ScanResult, ScanError>?
        Task {
            for await event in coordinator.run() {
                switch event {
                case .progress(let progress): report(progress)
                case .finished(let result): outcome = .success(result)
                case .failed(let error): outcome = .failure(error)
                }
            }
            finished.signal()
        }
        finished.wait()
        clearProgressLine()

        switch outcome {
        case .success(let result): print(report(result, top: top))
        case .failure(let error): throw CLIError(error.description)
        case nil: throw CLIError("the scan produced no result")
        }
    }

    // MARK: - progress

    private static let progressIsTTY = isatty(STDERR_FILENO) == 1

    private static func report(_ progress: ScanProgress) {
        let line = [
            "files \(MetricsCommands.pad(count(progress.files), 12))",
            "on disk \(MetricsCommands.pad(MetricsCommands.bytes(progress.allocated), 11))",
            "unreadable \(MetricsCommands.pad(count(progress.unreadable), 8))",
            "\(MetricsCommands.format(progress.elapsed, 1)) s ",
            middleTruncated(progress.currentDirectory, limit: 52),
        ].joined(separator: "  ")
        // A terminal gets one line that rewrites itself; a pipe gets one line
        // per tick, because \r in a file is noise.
        warn(progressIsTTY ? "\r\(MetricsCommands.pad(line, 118))" : "\(line)\n", newline: false)
    }

    private static func clearProgressLine() {
        guard progressIsTTY else { return }
        warn("\r\(String(repeating: " ", count: 118))\r", newline: false)
    }

    // MARK: - result

    private static func report(_ result: ScanResult, top: Int) -> String {
        var lines: [String] = []
        func field(_ name: String, _ value: String) {
            lines.append("\(MetricsCommands.pad(name, 20))\(value)")
        }
        let tally = result.tally
        field("root", result.root)
        field("elapsed", "\(MetricsCommands.format(result.duration, 2)) s")
        field("cancelled", result.wasCancelled ? "yes (partial result)" : "no")
        field("files", count(tally.files))
        field("directories", count(tally.directories))
        field("size on disk", MetricsCommands.bytes(tally.allocated))
        field("logical size", MetricsCommands.bytes(tally.logical))
        field("unreadable", count(tally.unreadable))
        field("dataless skipped", count(tally.dataless))
        field("hard links skipped", count(tally.hardLinkDuplicates))
        field("directories skipped", count(tally.skippedDirectories))

        let entries = result.entries.prefix(top)
        lines.append("")
        lines.append("top \(entries.count) by size on disk")
        lines.append(
            "  \(MetricsCommands.pad("#", 5))\(MetricsCommands.pad("ON DISK", 12))"
                + "\(MetricsCommands.pad("LOGICAL", 12))\(MetricsCommands.pad("MODIFIED", 18))PATH"
        )
        for (index, entry) in entries.enumerated() {
            lines.append(
                "  \(MetricsCommands.pad("\(index + 1)", 5))"
                    + "\(MetricsCommands.pad(MetricsCommands.bytes(entry.allocated), 12))"
                    + "\(MetricsCommands.pad(MetricsCommands.bytes(entry.logical), 12))"
                    + "\(MetricsCommands.pad(stamp(entry.modified), 18))\(entry.path)"
            )
        }

        lines.append(contentsOf: breakdown("space by folder, home", result.homeFolders))
        lines.append(contentsOf: breakdown("space by folder, root", result.rootFolders))
        return lines.joined(separator: "\n")
    }

    private static func breakdown(_ title: String, _ folders: [FolderUsage]) -> [String] {
        guard !folders.isEmpty else { return [] }
        var lines = ["", title]
        for folder in folders.prefix(15) {
            lines.append(
                "  \(MetricsCommands.pad(MetricsCommands.bytes(folder.allocated), 12))"
                    + "\(MetricsCommands.pad(count(folder.files) + " files", 16))\(folder.path)"
            )
        }
        return lines
    }

    // MARK: - formatting

    private static func count(_ value: UInt64) -> String { value.formatted(.number.grouping(.automatic)) }

    private static func stamp(_ date: Date) -> String {
        date.formatted(
            Date.FormatStyle(date: .numeric, time: .shortened, locale: Locale(identifier: "en_GB"))
        )
    }

    /// Keeps the head and the tail of a path, which is where the meaning is.
    static func middleTruncated(_ text: String, limit: Int) -> String {
        guard text.count > limit, limit > 5 else { return text }
        let keep = limit - 3
        let head = keep - keep / 2
        return "\(text.prefix(head))...\(text.suffix(keep / 2))"
    }

    private static func warn(_ text: String, newline: Bool = true) {
        FileHandle.standardError.write(Data((text + (newline ? "\n" : "")).utf8))
    }
}
