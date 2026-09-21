import AppKit
import SwiftUI
import SysMetrics
import UniformTypeIdentifiers

struct ProcessesView: View {
    @Bindable var store: ProcessStore
    let helper: HelperController
    let settings: AppSettings
    let reports: ReportService
    let showSettings: () -> Void

    @State private var pending: SignalRequest?

    var body: some View {
        VStack(spacing: 0) {
            SummaryHeader(store: store)
            Divider()
            toolbar
            Divider()
            table
            Divider()
            footer
        }
        .confirmationDialog(
            pending?.title ?? "",
            isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }),
            presenting: pending
        ) { request in
            Button(request.signal.title, role: .destructive) {
                store.send(request.signal, to: request.rows)
                pending = nil
            }
            Button("Cancel", role: .cancel) { pending = nil }
        } message: { request in
            Text(request.detail)
        }
    }

    // MARK: - Toolbar

    /// The three segments need 300 pt and everything to their right needs
    /// about 270 more. A 760 pt window - the narrowest the layout allows -
    /// leaves 568 for the lot, and the Force Quit button used to fall off the
    /// right edge of it. `ViewThatFits` takes the segments down to a pop-up
    /// with the same three choices when the row will not fit, so nothing is
    /// ever clipped and nothing wraps.
    private var toolbar: some View {
        ViewThatFits(in: .horizontal) {
            toolbarRow {
                Picker("Show", selection: $store.scope) {
                    ForEach(ProcessFilterScope.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 300)
                .controlSize(.small)
            }
            toolbarRow {
                Picker("Show", selection: $store.scope) {
                    ForEach(ProcessFilterScope.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .fixedSize()
                .controlSize(.small)
                .help("Which processes the table shows")
            }
        }
        .padding(.horizontal, Layout.cardPadding)
        .padding(.vertical, Layout.gutter)
    }

    private func toolbarRow(@ViewBuilder scope: () -> some View) -> some View {
        HStack(spacing: Layout.gutter) {
            scope()

            Spacer(minLength: Layout.gutter)

            // "Search", like the Storage tab, and what it searches is in the
            // tooltip: the toolbar squeezes this field below 110 pt in a
            // 900 pt window, and a prompt that reads "Name, PID or p…" tells
            // nobody anything.
            SearchField(text: $store.searchText)
                .frame(minWidth: 90, idealWidth: 190, maxWidth: 190)
                .help("Search by name, PID or path")

            CopyForAIMenu(
                subject: .processes,
                settings: settings,
                hasSelection: !store.selection.isEmpty
            ) { scope, format in
                reports.copyProcesses(scope: scope, format: format)
            }

            Button {
                ask(.terminate)
            } label: {
                Label("Quit", systemImage: "stop.circle")
            }
            .labelStyle(.iconOnly)
            .help("Quit the selected process (SIGTERM)")
            .disabled(store.selection.isEmpty)

            Button {
                ask(.kill)
            } label: {
                Label("Force Quit", systemImage: "xmark.octagon")
            }
            .labelStyle(.iconOnly)
            .help("Force Quit the selected process (SIGKILL)")
            .disabled(store.selection.isEmpty)
        }
    }

    private func ask(_ signal: ProcessSignal, ids: Set<ProcessTableRow.ID>? = nil) {
        let rows = ids.map { chosen in store.rows.filter { chosen.contains($0.id) } } ?? store.selectedRows
        guard !rows.isEmpty else { return }
        pending = SignalRequest(signal: signal, rows: rows)
    }

    // MARK: - Table

    @ViewBuilder
    private var table: some View {
        let rows = store.visibleRows
        if rows.isEmpty {
            ScrollView {
                emptyState
                    .frame(maxWidth: .infinity, minHeight: 200)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .scrollBounceBehavior(.basedOnSize)
        } else {
            Table(of: ProcessTableRow.self, selection: $store.selection, sortOrder: $store.sortOrder) {
                TableColumn("Process", sortUsing: ProcessComparator(key: .name)) { row in
                    HStack(spacing: 6) {
                        Image(nsImage: ProcessIconCache.shared.icon(pid: row.pid, path: row.executablePath))
                            .resizable()
                            .frame(width: 16, height: 16)
                        Text(row.name)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                .width(min: 140, ideal: 210)

                TableColumn("PID", sortUsing: ProcessComparator(key: .pid)) { row in
                    Text(String(row.pid))
                        .monospacedDigit()
                }
                .width(54)
                .alignment(.trailing)

                TableColumn("User", sortUsing: ProcessComparator(key: .user)) { row in
                    Text(row.userName)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(.secondary)
                }
                .width(min: 72, ideal: 96)

                TableColumn("CPU %", sortUsing: ProcessComparator(key: .cpu)) { row in
                    CPUCell(percent: row.cpuPercent)
                }
                .width(86)
                .alignment(.trailing)

                TableColumn("Memory", sortUsing: ProcessComparator(key: .memory)) { row in
                    ValueText(text: row.memoryBytes.map(Fmt.memorySize))
                }
                .width(84)
                .alignment(.trailing)
            } rows: {
                ForEach(rows) { TableRow($0) }
            }
            .tableStyle(.inset)
            .contextMenu(forSelectionType: ProcessTableRow.ID.self) { ids in
                menu(for: ids)
            }
        }
    }

    @ViewBuilder
    private func menu(for ids: Set<ProcessTableRow.ID>) -> some View {
        let rows = store.rows.filter { ids.contains($0.id) }
        if !rows.isEmpty {
            Button("Quit") { ask(.terminate, ids: ids) }
            Button("Force Quit", role: .destructive) { ask(.kill, ids: ids) }
            Divider()
            Button("Copy for AI") {
                store.selection = ids
                reports.copyProcesses(scope: .selection)
            }
            Button("Reveal in Finder") { reveal(rows) }
                .disabled(rows.allSatisfy { $0.executablePath == nil })
            Button(ids.count == 1 ? "Copy PID" : "Copy PIDs") {
                copy(rows.map { String($0.pid) }.joined(separator: "\n"))
            }
            Button(ids.count == 1 ? "Copy Path" : "Copy Paths") {
                copy(rows.compactMap(\.executablePath).joined(separator: "\n"))
            }
            .disabled(rows.allSatisfy { $0.executablePath == nil })
        }
    }

    private func reveal(_ rows: [ProcessTableRow]) {
        let urls = rows.compactMap(\.executablePath).map { URL(filePath: $0) }
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    private func copy(_ text: String) {
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    @ViewBuilder
    private var emptyState: some View {
        if store.rows.isEmpty {
            ContentUnavailableView {
                Label("Sampling", systemImage: "list.bullet.rectangle")
            } description: {
                Text("The process table appears within three seconds.")
            }
        } else {
            ContentUnavailableView.search(text: store.searchText)
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: Layout.gutter) {
            if store.restrictedCount > 0 {
                Image(systemName: "lock")
                    .imageScale(.small)
                    .foregroundStyle(.secondary)
                Text("\(store.restrictedCount) processes need the helper for CPU and memory")
                    .lineLimit(1)
                if !helperIsRunning {
                    Button("Open Settings", action: showSettings)
                        .controlSize(.small)
                }
            } else if !store.rows.isEmpty {
                Image(systemName: "checkmark.seal")
                    .imageScale(.small)
                    .foregroundStyle(.secondary)
                Text("Every process reports its counters")
                    .lineLimit(1)
            }

            Spacer(minLength: Layout.gutter)

            if let message = store.message {
                Text(message)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(.secondary)
                Button {
                    store.clearMessage()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .imageScale(.small)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .font(.callout)
        .padding(.horizontal, Layout.cardPadding)
        .padding(.vertical, Layout.gutter)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var helperIsRunning: Bool {
        if case .running = helper.state { return true }
        return false
    }
}

/// What a confirmation dialog needs to name the process it is about to end.
struct SignalRequest: Identifiable {
    let id = UUID()
    let signal: ProcessSignal
    let rows: [ProcessTableRow]

    var title: String {
        guard let first = rows.first else { return signal.title }
        return rows.count == 1
            ? "\(signal.title) \(first.name) (pid \(first.pid))?"
            : "\(signal.title) \(rows.count) processes?"
    }

    var detail: String {
        switch signal {
        case .terminate:
            "The process is asked to quit and can save its work first."
        case .kill:
            "The process ends at once. Anything it has not saved is lost."
        }
    }
}

// MARK: - Summary

/// The heavy processes at a glance, which is what the tab is opened for.
private struct SummaryHeader: View {
    let store: ProcessStore

    private static let count = 5

    var body: some View {
        HStack(alignment: .top, spacing: Layout.cardPadding) {
            TopList(
                title: "Top CPU",
                symbolName: "cpu",
                rows: Array(store.topByCPU.prefix(SummaryHeader.count))
            ) { row in
                row.cpuPercent.map { "\(Fmt.processCPU($0)) %" }
            }

            TopList(
                title: "Top memory",
                symbolName: "memorychip",
                rows: Array(store.topByMemory.prefix(SummaryHeader.count))
            ) { row in
                row.memoryBytes.map(Fmt.memorySize)
            }

            VStack(alignment: .leading, spacing: Layout.gutter) {
                StatBlock(caption: "Processes", value: "\(store.rows.count)", size: .callout)
                StatBlock(
                    caption: "Total CPU",
                    value: "\(Fmt.processCPU(store.totalCPUPercent)) %",
                    size: .callout
                )
                if store.helperIsAnswering {
                    StatBlock(caption: "From the helper", value: "\(store.helperRowCount)", size: .callout)
                }
            }
            .frame(width: 110, alignment: .leading)
        }
        .padding(.horizontal, Layout.cardPadding)
        .padding(.vertical, Layout.gutter * 1.5)
    }
}

private struct TopList: View {
    let title: String
    let symbolName: String
    let rows: [ProcessTableRow]
    let value: (ProcessTableRow) -> String?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                Image(systemName: symbolName)
                    .imageScale(.small)
                    .foregroundStyle(.secondary)
                Text(title)
                    .font(.subheadline.weight(.medium))
            }
            .padding(.bottom, 2)

            if rows.isEmpty {
                Text("Sampling…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(rows) { row in
                    HStack(spacing: Layout.gutter) {
                        Text(row.name)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: Layout.gutter)
                        ValueText(text: value(row))
                    }
                    .font(.caption)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Cells

/// A number, or the dash that stands for a counter this process would not
/// give up without the helper.
private struct ValueText: View {
    let text: String?

    var body: some View {
        Text(text ?? "-")
            .monospacedDigit()
            .foregroundStyle(text == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
    }
}

/// Activity Monitor's CPU column: 100 % is one busy core, one decimal, with a
/// thin bar that fills at one core so a glance finds the heavy row.
private struct CPUCell: View {
    let percent: Double?

    var body: some View {
        HStack(spacing: 6) {
            bar
            ValueText(text: percent.map(Fmt.processCPU))
        }
    }

    @ViewBuilder
    private var bar: some View {
        if let percent {
            let fraction = min(max(percent / 100, 0), 1)
            Capsule()
                .fill(Color(nsColor: .quaternaryLabelColor).opacity(0.6))
                .frame(width: 22, height: 4)
                .overlay(alignment: .leading) {
                    Capsule()
                        .fill(percent >= 90 ? Color.orange : Color.accentColor)
                        .frame(width: 22 * fraction, height: 4)
                }
        } else {
            Color.clear.frame(width: 22, height: 4)
        }
    }
}

/// Icons for the process table.
///
/// An app that is running answers with its own icon; anything else wears the
/// icon of its bundle or the generic Unix executable. Both lookups are cached
/// by executable path, so a refresh of 580 rows every three seconds costs
/// nothing after the first pass.
@MainActor
final class ProcessIconCache {
    static let shared = ProcessIconCache()

    /// Bounded: a Mac runs a few hundred distinct executables, and a table
    /// that has been open for a week must not hold an image for every one that
    /// ever appeared in it.
    private var icons = LRUCache<String, NSImage>(capacity: 256)
    private lazy var generic = NSWorkspace.shared.icon(for: .unixExecutable)

    func icon(pid: Int32, path: String?) -> NSImage {
        guard let path, !path.isEmpty else { return generic }
        if let cached = icons.value(forKey: path) { return cached }
        let icon = lookup(pid: pid, path: path) ?? generic
        icons.insert(icon, forKey: path)
        return icon
    }

    private func lookup(pid: Int32, path: String) -> NSImage? {
        if let running = NSRunningApplication(processIdentifier: pid_t(pid)), let icon = running.icon {
            return icon
        }
        // A helper inside a bundle is not an app of its own, and the bundle
        // icon says more than a generic binary would.
        guard let bundle = bundlePath(of: path) else { return nil }
        return NSWorkspace.shared.icon(forFile: bundle)
    }

    /// The innermost `.app` on the path, the same one the display name comes
    /// from: that is the app the user is looking at.
    private func bundlePath(of executablePath: String) -> String? {
        let components = executablePath.split(separator: "/", omittingEmptySubsequences: true)
        guard let index = components.lastIndex(where: { $0.hasSuffix(".app") }) else { return nil }
        return "/" + components[...index].joined(separator: "/")
    }
}
