import SwiftUI

/// The warning above every tab when Vent is not running from `/Applications`.
///
/// The launch daemon is registered with the path of the bundle that registered
/// it, and every TCC grant - Accessibility, Input Monitoring, Full Disk Access
/// - is bound to the same path. A copy that runs from the Downloads folder
/// therefore collects its own set of both and loses them again the moment it
/// is moved. Vent says so and changes nothing: moving an app behind the user's
/// back is worse than a line of text.
struct LaunchLocationBanner: View {
    /// `/Applications/Vent.app`, where `make install` puts it. A copy in
    /// `~/Applications` is a different path to launchd and to TCC, so it
    /// counts as misplaced too.
    static var isInPlace: Bool {
        Bundle.main.bundlePath.hasPrefix("/Applications/")
    }

    var body: some View {
        if !LaunchLocationBanner.isInPlace {
            HStack(spacing: Layout.gutter) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .frame(width: 18, alignment: .center)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Vent is not running from /Applications")
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                    // One line, and the path is not in it: a bundle path is
                    // longer than this banner, and a sentence cut in the
                    // middle by a truncated path reads as a bug. The tooltip
                    // has the path for anyone who wants it.
                    Text("The helper and the permission grants are bound to the bundle path, so both break when the app moves.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: Layout.gutter)
                Text((Bundle.main.bundlePath as NSString).abbreviatingWithTildeInPath)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .frame(maxWidth: 220, alignment: .trailing)
            }
            .padding(.horizontal, Layout.cardPadding)
            .padding(.vertical, Layout.gutter)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.orange.opacity(0.12))
            .help(Bundle.main.bundlePath)
        }
    }
}
