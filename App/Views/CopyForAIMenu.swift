import ReportKit
import SwiftUI

/// The "Copy for AI" button of the Processes and Storage toolbars.
///
/// One view for both tables: the four items, their wording and their shortcut
/// are the same on each, and the only difference is the noun.
struct CopyForAIMenu: View {
    enum Subject {
        case processes
        case files

        var noun: String {
            switch self {
            case .processes: "processes"
            case .files: "files"
            }
        }

        var help: String {
            switch self {
            case .processes: "Copy the process list as text for a chat model"
            case .files: "Copy the largest files as text for a chat model"
            }
        }
    }

    let subject: Subject
    @Bindable var settings: AppSettings
    let hasSelection: Bool
    let copy: (ReportService.Scope, TableFormat) -> Void

    var body: some View {
        Menu {
            Button("Copy All") { copy(.all, .markdown) }
            Button("Copy Selected") { copy(.selection, .markdown) }
                .disabled(!hasSelection)
            Divider()
            Toggle("Include question for the AI", isOn: $settings.reportIncludesQuestion)
            Button("Copy as TSV") { copy(.all, .tsv) }
        } label: {
            Label("Copy for AI", systemImage: "doc.on.clipboard")
        }
        // The chevron stays: without it a menu in a row of plain buttons reads
        // as a button, and a click that opens four items is then a surprise.
        .menuIndicator(.visible)
        .fixedSize()
        .help(subject.help)
        // Command-Shift-C copies everything, from either tab. A zero-sized
        // button rather than a shortcut on the menu: a `Menu` with a shortcut
        // opens itself instead of acting.
        .background {
            Button("Copy \(subject.noun) for AI") { copy(.all, .markdown) }
                .keyboardShortcut("c", modifiers: [.command, .shift])
                .frame(width: 0, height: 0)
                .clipped()
                .accessibilityHidden(true)
        }
    }
}
