import Foundation
import Testing

@testable import ScanKit

/// These tests really move files to the Trash, so they only ever create and
/// move files of their own under `$TMPDIR`, and every one of them is taken
/// back out of the Trash at the end through the URL `trashItem` returned.
@Suite("move to trash", .serialized)
struct TrashServiceTests {
    private func scratchDirectory() throws -> URL {
        let url = URL(filePath: NSTemporaryDirectory(), directoryHint: .isDirectory)
            .appending(path: "vent-trash-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func emptyFromTrash(_ outcome: TrashOutcome) {
        for url in outcome.trashed.values {
            try? FileManager.default.removeItem(at: url)
        }
    }

    @Test("a file moves to the Trash and stops being where it was")
    func trashesAFile() throws {
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "scratch.bin")
        try Data(count: 64 * 1024).write(to: file)

        let outcome = TrashService.trash([file.path])
        defer { emptyFromTrash(outcome) }

        #expect(outcome.failed.isEmpty)
        let resulting = try #require(outcome.trashed[file.path])
        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(FileManager.default.fileExists(atPath: resulting.path))
        #expect(resulting.path.contains(".Trash"))
    }

    @Test("several files move in one call")
    func trashesSeveralFiles() throws {
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let files = try (0..<3).map { index -> URL in
            let url = directory.appending(path: "scratch-\(index).bin")
            try Data(count: 1024).write(to: url)
            return url
        }

        let outcome = TrashService.trash(files.map(\.path))
        defer { emptyFromTrash(outcome) }

        #expect(outcome.trashed.count == 3)
        #expect(outcome.failed.isEmpty)
        for file in files {
            #expect(!FileManager.default.fileExists(atPath: file.path))
        }
    }

    @Test("a file that is already gone is reported, and the rest still move")
    func missingFileIsReported() throws {
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let present = directory.appending(path: "present.bin")
        try Data(count: 1024).write(to: present)
        let absent = directory.appending(path: "absent.bin").path

        let outcome = TrashService.trash([absent, present.path])
        defer { emptyFromTrash(outcome) }

        #expect(outcome.trashed.keys.sorted() == [present.path])
        #expect(outcome.failed.keys.sorted() == [absent])
    }
}
