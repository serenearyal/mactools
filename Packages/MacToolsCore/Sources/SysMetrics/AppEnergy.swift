import Foundation

/// One app in the energy list: what the Battery tab draws for "apps using the
/// most energy".
///
/// The watts are CPU energy only - `ri_energy_nj` of `proc_pid_rusage` counts
/// what the cores burned for this process, so the display, the radios and the
/// GPU work of another process are not in it. Nothing that draws this value may
/// claim it explains the whole draw of the machine.
public struct AppEnergy: Sendable, Equatable, Identifiable {
    /// The `.app` bundle path, or the process name when there is no bundle.
    /// Two apps of the same name in different folders are two rows.
    public var id: String
    /// "Arc", "Xcode", "kernel_task".
    public var name: String
    /// The bundle the icon comes from. nil for a process with no bundle.
    public var bundlePath: String?
    /// The mean power over the window, in watts.
    public var watts: Double
    /// 0...1 of the energy every process burned in the window.
    public var share: Double
    /// How many live processes the app had in the newest sample that saw it:
    /// a browser is one row and thirty processes.
    public var processCount: Int

    public init(
        id: String,
        name: String,
        bundlePath: String? = nil,
        watts: Double,
        share: Double,
        processCount: Int
    ) {
        self.id = id
        self.name = name
        self.bundlePath = bundlePath
        self.watts = watts
        self.share = share
        self.processCount = processCount
    }
}

/// Which app a process belongs to. The key of the grouping, so the arithmetic
/// never carries a display string around.
public struct AppIdentity: Sendable, Equatable, Hashable {
    /// The bundle path, or the process name when there is no bundle.
    public let id: String
    public let name: String
    public let bundlePath: String?

    public init(id: String, name: String, bundlePath: String? = nil) {
        self.id = id
        self.name = name
        self.bundlePath = bundlePath
    }
}

/// The pure half of "apps using the most energy": which app owns a process.
///
/// A helper of a browser is the browser. The renderers of Arc live at
/// `/Applications/Arc.app/Contents/Frameworks/.../Browser Helper
/// (Renderer).app/Contents/MacOS/...`, so the rule is the OUTERMOST `.app` of
/// the path and never the innermost one: the innermost is what the process
/// table calls the row, and it would spread one browser over four names.
public enum AppGrouping {
    /// The outermost `.app` an executable path sits inside, or nil for an
    /// executable that is in no bundle at all.
    ///
    /// The `.app` component has to have something under it: a path that ends
    /// in `.app` is a file called `.app`, not a process inside a bundle.
    public static func bundlePath(forExecutablePath path: String) -> String? {
        guard path.hasPrefix("/") else { return nil }
        let parts = path.split(separator: "/", omittingEmptySubsequences: true)
        guard parts.count >= 2 else { return nil }
        guard let index = parts.indices.first(where: { index in
            index < parts.count - 1 && isBundleComponent(parts[index])
        }) else { return nil }
        return "/" + parts[0...index].joined(separator: "/")
    }

    /// The name a bundle path shows: the last component without `.app`.
    public static func bundleName(forBundlePath path: String) -> String {
        let last = path.split(separator: "/", omittingEmptySubsequences: true).last ?? ""
        return String(last.dropLast(4))
    }

    /// The app a sampled process belongs to.
    ///
    /// Without a bundle the process is its own app, which is what keeps
    /// `kernel_task` and `WindowServer` as themselves.
    public static func identity(executablePath: String?, processName: String) -> AppIdentity {
        guard let executablePath,
              let bundle = bundlePath(forExecutablePath: executablePath)
        else {
            return AppIdentity(id: processName, name: processName, bundlePath: nil)
        }
        return AppIdentity(id: bundle, name: bundleName(forBundlePath: bundle), bundlePath: bundle)
    }

    /// A real bundle component: `.app` with a name in front of it.
    private static func isBundleComponent(_ part: Substring) -> Bool {
        part.count > 4 && part.hasSuffix(".app")
    }
}
