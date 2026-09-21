import AppKit
import ScanKit
import SwiftUI
import SysMetrics
import UniformTypeIdentifiers

struct StorageView: View {
    let store: MetricsStore
    @Bindable var storage: StorageStore
    let settings: AppSettings
    let reports: ReportService

    @State private var confirmingTrash = false
    @State private var breakdownScope = BreakdownScope.home

    var body: some View {
        VStack(spacing: 0) {
            VolumesSection(snapshot: store.snapshot)
            Divider()
            largestFiles
        }
        .onAppear { storage.loadCacheIfNeeded() }
        // A scan of a folder outside the home directory has nothing to show
        // under "Home"; land the picker on the side that has the numbers.
        .onChange(of: storage.result) { _, result in
            guard let result else { return }
            breakdownScope = result.homeFolders.isEmpty ? .disk : .home
        }
        .confirmationDialog(
            "Move \(storage.selection.count) \(storage.selection.count == 1 ? "item" : "items") to the Trash?",
            isPresented: $confirmingTrash
        ) {
            Button("Move to Trash", role: .destructive) { storage.trash(storage.selection) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "\(storage.selection.count) files, \(Fmt.storageSize(storage.selectedAllocated)) on disk. "
                    + "They stay in the Trash until you empty it."
            )
        }
    }

    // MARK: - Largest files

    private var largestFiles: some View {
        VStack(spacing: 0) {
            toolbar
            if let progress = storage.progress {
                ScanProgressLine(progress: progress)
            }
            if !storage.hasFullDiskAccess {
                FullDiskAccessBanner(storage: storage)
            }
            Divider()
            table
            Divider()
            // Under the table, not beside it: at the 900 pt default window
            // the detail pane is about 700 pt, and five columns plus a side
            // panel do not both fit.
            BreakdownStrip(result: storage.result, scope: $breakdownScope)
        }
    }

    private var toolbar: some View {
        HStack(spacing: Layout.gutter) {
            Button(storage.isScanning ? "Stop" : "Scan") {
                if storage.isScanning { storage.cancelScan() } else { storage.startScan() }
            }
            .keyboardShortcut(storage.isScanning ? .cancelAction : .defaultAction)

            Text(statusText)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            if storage.message != nil {
                Button {
                    storage.clearMessage()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .imageScale(.small)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Dismiss")
            }

            Spacer(minLength: Layout.gutter)

            SearchField(text: $storage.searchText)
                .frame(minWidth: 120, idealWidth: 190, maxWidth: 190)

            CopyForAIMenu(
                subject: .files,
                settings: settings,
                hasSelection: !storage.selection.isEmpty
            ) { scope, format in
                reports.copyFiles(scope: scope, format: format)
            }
            .disabled(storage.result == nil)

            Button {
                storage.revealInFinder(storage.selection)
            } label: {
                Label("Reveal in Finder", systemImage: "folder")
            }
            .labelStyle(.iconOnly)
            .help("Reveal in Finder")
            .disabled(storage.selection.isEmpty)

            Button {
                confirmingTrash = true
            } label: {
                Label("Move to Trash", systemImage: "trash")
            }
            .labelStyle(.iconOnly)
            .help("Move to Trash")
            .disabled(storage.selection.isEmpty)
        }
        .padding(.horizontal, Layout.cardPadding)
        .padding(.vertical, Layout.gutter * 1.5)
    }

    private var statusText: String {
        if let message = storage.message { return message }
        if storage.isScanning { return "Scanning..." }
        if let description = storage.lastScanDescription { return description }
        return "Never scanned"
    }

    @ViewBuilder
    private var table: some View {
        let rows = storage.visibleRows
        if rows.isEmpty {
            // The scroll view caps the height `ContentUnavailableView` asks
            // for: in a short window the tab scrolls instead of growing past
            // the window and taking the sidebar off the top with it.
            ScrollView {
                emptyState
                    .frame(maxWidth: .infinity, minHeight: 240)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .scrollBounceBehavior(.basedOnSize)
        } else {
            // The ideal widths add up to the 560 pt the detail pane has in the
            // 760 pt minimum window: a `Table` lays out at the ideal and clips
            // the rest instead of shrinking, so ideals that add up to more
            // than the pane push the last columns off screen.
            Table(of: StorageRow.self, selection: $storage.selection, sortOrder: $storage.sortOrder) {
                TableColumn("Name", value: \.name) { row in
                    HStack(spacing: 6) {
                        Image(nsImage: FileIconCache.shared.icon(forPath: row.path))
                            .resizable()
                            .frame(width: 16, height: 16)
                        Text(row.name)
                            .lineLimit(1)
                    }
                    .opacity(row.exists ? 1 : 0.4)
                }
                .width(min: 130, ideal: 180)

                TableColumn("Folder") { row in
                    Text(row.parent)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(.secondary)
                        .opacity(row.exists ? 1 : 0.4)
                }
                .width(min: 100, ideal: 116)

                TableColumn("Size on disk", value: \.allocated) { row in
                    trailing(Fmt.storageSize(row.allocated))
                }
                .width(92)

                // Empty unless the file is sparse, cloned or compressed.
                TableColumn("Logical") { row in
                    trailing(row.logicalNote ?? "", muted: true)
                }
                .width(72)

                // The day is enough to decide whether a file is still wanted,
                // and the time would only truncate at this width.
                TableColumn("Modified", value: \.modified) { row in
                    Text(row.modified.formatted(date: .abbreviated, time: .omitted))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .width(96)
            } rows: {
                ForEach(rows) { TableRow($0) }
            }
            .tableStyle(.inset)
            .contextMenu(forSelectionType: StorageRow.ID.self) { ids in
                Button("Reveal in Finder") { storage.revealInFinder(ids) }
                Button("Copy for AI") {
                    storage.selection = ids
                    reports.copyFiles(scope: .selection)
                }
                Divider()
                Button("Move to Trash", role: .destructive) {
                    storage.selection = ids
                    confirmingTrash = true
                }
            }
        }
    }

    private func trailing(_ text: String, muted: Bool = false) -> some View {
        HStack(spacing: 0) {
            Spacer(minLength: 0)
            Text(text)
                .monospacedDigit()
                .foregroundStyle(muted ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if storage.result == nil && !storage.isScanning {
            ContentUnavailableView {
                Label("No scan yet", systemImage: "magnifyingglass.circle")
            } description: {
                Text("A scan walks every file on the volume and keeps the \(Scan.resultLimit) largest. It takes a few minutes the first time.")
            } actions: {
                Button("Scan Now") { storage.startScan() }
                    .buttonStyle(.borderedProminent)
            }
        } else if storage.isScanning {
            ContentUnavailableView {
                Label("Scanning", systemImage: "magnifyingglass")
            } description: {
                Text("The largest files appear when the walk finishes. Stopping keeps what it found so far.")
            }
        } else {
            ContentUnavailableView.search(text: storage.searchText)
        }
    }
}

// MARK: - Volumes

private struct VolumesSection: View {
    let snapshot: MetricsSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: Layout.gutter) {
            HStack(alignment: .firstTextBaseline, spacing: Layout.gutter) {
                Text("Volumes")
                    .font(.headline)
                Spacer(minLength: Layout.gutter)
                throughput("Read", snapshot.diskIO?.bytesReadPerSecond)
                throughput("Write", snapshot.diskIO?.bytesWrittenPerSecond)
            }

            if snapshot.volumes.isEmpty {
                Text("Sampling...")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(height: 52)
            } else if snapshot.volumes.count > 2 {
                // Only a stack of disks needs to scroll, and only then may it
                // take a fixed slice of a 600 pt window.
                ScrollView {
                    VStack(spacing: Layout.gutter * 1.5) {
                        ForEach(snapshot.volumes) { VolumeRow(volume: $0) }
                    }
                }
                .frame(height: 132)
                .scrollBounceBehavior(.basedOnSize)
            } else {
                VStack(spacing: Layout.gutter * 1.5) {
                    ForEach(snapshot.volumes) { VolumeRow(volume: $0) }
                }
            }
        }
        .padding(Layout.cardPadding)
    }

    private func throughput(_ caption: String, _ value: Double?) -> some View {
        HStack(spacing: 5) {
            Text(caption)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(Fmt.throughput(value ?? 0))
                .font(.callout)
                .monospacedDigit()
        }
    }
}

private struct VolumeRow: View {
    let volume: VolumeInfo

    var body: some View {
        HStack(alignment: .top, spacing: Layout.gutter * 1.5) {
            Image(systemName: volume.isRemovable || !volume.isInternal ? "externaldrive" : "internaldrive")
                .font(.title2)
                .foregroundStyle(.secondary)
                .frame(width: 26)

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: Layout.gutter) {
                    Text(volume.name)
                        .font(.headline)
                        .lineLimit(1)
                    Text(tags)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: Layout.gutter)
                    Text("\(Fmt.storageSize(volume.used)) of \(Fmt.storageSize(volume.total)) used")
                        .font(.callout)
                        .monospacedDigit()
                    Text("· \(Fmt.storageSize(volume.available)) free")
                        .font(.callout)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }

                SegmentedBar(
                    segments: [
                        .init(
                            id: "used",
                            value: Double(volume.used),
                            style: volume.usedFraction >= 0.9
                                ? MetricColor.usage(volume.usedFraction)
                                : Color.accentColor
                        )
                    ],
                    total: Double(volume.total),
                    height: 8
                )
            }
        }
    }

    private var tags: String {
        [
            volume.mountPath,
            volume.fileSystemType.uppercased(),
            volume.isInternal ? "Internal" : "External",
            volume.isRemovable ? "Removable" : nil,
            volume.isBootVolume ? "Startup" : nil,
        ]
        .compactMap { $0 }
        .joined(separator: " · ")
    }
}

// MARK: - Scan progress and permission

private struct ScanProgressLine: View {
    let progress: ScanProgress

    var body: some View {
        HStack(spacing: Layout.gutter) {
            ProgressView()
                .progressViewStyle(.linear)
                .frame(width: 96)
            Text("\(progress.files.formatted()) files · \(Fmt.storageSize(progress.allocated)) · \(progress.elapsed.formatted(.number.precision(.fractionLength(0)))) s")
                .monospacedDigit()
            Text(progress.currentDirectory)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .font(.callout)
        .padding(.horizontal, Layout.cardPadding)
        .padding(.bottom, Layout.gutter * 1.5)
    }
}

private struct FullDiskAccessBanner: View {
    let storage: StorageStore

    var body: some View {
        HStack(spacing: Layout.gutter) {
            Image(systemName: "lock.shield")
                .foregroundStyle(.orange)
            // Both lines are capped. Wrapping text with `fixedSize` in a row
            // that the table squeezes grows without bound, and its height
            // then pushes the whole window content off the top.
            VStack(alignment: .leading, spacing: 1) {
                Text("Vent does not have Full Disk Access")
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                Text("The scan still runs; it skips protected folders and counts them as unreadable.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: Layout.gutter)
            Button("Open Settings") { storage.openFullDiskAccessSettings() }
                .controlSize(.small)
        }
        .padding(.horizontal, Layout.gutter * 1.5)
        .padding(.vertical, Layout.gutter)
        .frame(maxWidth: .infinity, alignment: .leading)
        // An inset card, not a full-bleed band: the sidebar is translucent
        // and a band that runs to the edge of the pane tints it.
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.orange.opacity(0.12))
        }
        .padding(.horizontal, Layout.cardPadding)
        .padding(.bottom, Layout.gutter * 1.5)
    }
}

// MARK: - Space by folder

enum BreakdownScope: String, CaseIterable, Identifiable {
    case home
    case disk

    var id: String { rawValue }
    var title: String { self == .home ? "Home" : "Whole disk" }
}

/// The "what takes the space" strip: the biggest top-level folders of the
/// home directory or of the whole disk, as a row of bars.
private struct BreakdownStrip: View {
    let result: ScanResult?
    @Binding var scope: BreakdownScope

    /// Six fits the 700 pt pane without the names truncating to nothing.
    private static let columns = 6

    var body: some View {
        VStack(alignment: .leading, spacing: Layout.gutter) {
            HStack(spacing: Layout.gutter * 1.5) {
                Text("Space by folder")
                    .font(.headline)
                Picker("Space by folder", selection: $scope) {
                    ForEach(BreakdownScope.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 180)
                .controlSize(.small)
                Spacer(minLength: 0)
                if let folders = folders.first, result != nil {
                    Text("largest: \(folders.name)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            if folders.isEmpty {
                Text(result == nil ? "A scan fills this in." : "The scan found nothing here.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(height: 34, alignment: .top)
            } else {
                HStack(alignment: .top, spacing: Layout.cardPadding) {
                    ForEach(folders.prefix(BreakdownStrip.columns)) { folder in
                        FolderBar(folder: folder, largest: folders[0].allocated)
                    }
                    Spacer(minLength: 0)
                }
                .frame(height: 34, alignment: .top)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Layout.cardPadding)
        .padding(.vertical, Layout.gutter * 1.5)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var folders: [FolderUsage] {
        guard let result else { return [] }
        return scope == .home ? result.homeFolders : result.rootFolders
    }
}

private struct FolderBar: View {
    let folder: FolderUsage
    let largest: UInt64

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(folder.name)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.middle)
            SegmentedBar(
                segments: [.init(id: folder.id, value: Double(folder.allocated), style: Color.accentColor)],
                total: Double(max(largest, 1)),
                height: 6
            )
            Text(Fmt.storageSize(folder.allocated))
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .frame(width: 92, alignment: .leading)
        .help("\(folder.path) · \(folder.files.formatted()) files")
    }
}

// MARK: - Pieces

/// Icons for the table.
///
/// `NSWorkspace.icon(forFile:)` opens the file to look for a custom icon,
/// which is 500 disk round trips for one scan result. A file almost always
/// wears the icon of its type, so one lookup per file extension covers the
/// whole table with a handful of calls and nothing lazy to schedule.
@MainActor
final class FileIconCache {
    static let shared = FileIconCache()

    /// Bounded, for the same reason as the process icons: a scan of a full
    /// disk meets more file extensions than anybody wants to keep images for.
    private var icons = LRUCache<String, NSImage>(capacity: 128)

    func icon(forPath path: String) -> NSImage {
        let suffix = (path as NSString).pathExtension.lowercased()
        if let cached = icons.value(forKey: suffix) { return cached }
        let type = suffix.isEmpty ? nil : UTType(filenameExtension: suffix)
        let icon = NSWorkspace.shared.icon(for: type ?? .data)
        icons.insert(icon, forKey: suffix)
        return icon
    }
}
