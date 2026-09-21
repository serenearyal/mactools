import Foundation

/// Cells that cannot break the table.
///
/// A file may be called `a|b`, may hold a tab and may even hold a newline, and
/// any of the three turns a pasted table into nonsense.
public enum TextSanitiser {
    public static func cell(_ text: String, format: TableFormat) -> String {
        var output = ""
        output.reserveCapacity(text.count)
        var lastWasSpace = false
        for character in text {
            // `isWhitespace` covers the tab, every newline and the CRLF pair,
            // which Swift counts as one character. Runs collapse into one
            // space: a name with a newline in it must not become a row with a
            // hole in it.
            if character.isWhitespace {
                if !lastWasSpace { output.append(" ") }
                lastWasSpace = true
                continue
            }
            lastWasSpace = false
            if character == "|", format == .markdown {
                output.append("\\|")
            } else {
                output.append(character)
            }
        }
        return output.trimmingCharacters(in: .whitespaces)
    }
}

/// `~` for the home directory, and only for it.
public enum PathAbbreviator {
    /// `/Users/me/a.txt` becomes `~/a.txt`. `/Users/me2/a.txt` does not: it is
    /// another account, not a longer path in this one.
    public static func tilde(_ path: String, home: String) -> String {
        guard !home.isEmpty, home != "/" else { return path }
        if path == home { return "~" }
        guard path.hasPrefix(home + "/") else { return path }
        return "~" + path.dropFirst(home.count)
    }
}
