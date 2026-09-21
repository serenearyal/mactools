import Foundation

/// The table itself: a markdown pipe table or a tab separated one.
///
/// The markdown is unpadded - a chat model does not read the alignment and a
/// padded table triples the size of the paste.
enum ReportTable {
    static func render(headers: [String], rows: [[String]], format: TableFormat) -> String {
        let clean = { (cells: [String]) in cells.map { TextSanitiser.cell($0, format: format) } }
        switch format {
        case .markdown:
            var lines = ["| " + clean(headers).joined(separator: " | ") + " |"]
            lines.append("|" + String(repeating: "---|", count: headers.count))
            lines += rows.map { "| " + clean($0).joined(separator: " | ") + " |" }
            return lines.joined(separator: "\n")
        case .tsv:
            var lines = [clean(headers).joined(separator: "\t")]
            lines += rows.map { clean($0).joined(separator: "\t") }
            return lines.joined(separator: "\n")
        }
    }
}
