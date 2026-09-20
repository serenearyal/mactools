import SwiftUI

/// The Windows section, until the window manager lands.
///
/// One line and a symbol, centred in the height every section shares. It draws
/// no live number at all, which is why an open popover on this section samples
/// exactly what a closed one samples.
struct PopoverWindows: View {
    var body: some View {
        PopoverEmptyState(
            symbolName: "macwindow.on.rectangle",
            text: "Window layouts arrive with the window manager."
        )
    }
}
