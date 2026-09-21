import Foundation

/// What the app asks the power manager for, as a value.
///
/// The IOKit call lives in the app; this is the whole decision, so the wording
/// the user reads in `pmset -g assertions` is testable without taking an
/// assertion.
public struct AssertionRequest: Sendable, Equatable {
    /// `PreventUserIdleSystemSleep`. Always true: an assertion that prevents
    /// nothing is not worth taking.
    public let systemSleep: Bool
    /// `PreventUserIdleDisplaySleep`.
    public let displaySleep: Bool
    /// `AssertName`, shown by `pmset -g assertions`.
    public let name: String
    /// `AssertDetails`: why, in the user's words.
    public let details: String
    /// `IOPMAssertionTimeout`. Nil runs until the app releases it.
    public let timeoutSeconds: Int?

    public init(
        systemSleep: Bool,
        displaySleep: Bool,
        name: String,
        details: String,
        timeoutSeconds: Int?
    ) {
        self.systemSleep = systemSleep
        self.displaySleep = displaySleep
        self.name = name
        self.details = details
        self.timeoutSeconds = timeoutSeconds
    }

    public static func make(
        duration: KeepAwakeDuration,
        keepDisplayOn: Bool,
        appName: String = "MacTools"
    ) -> AssertionRequest {
        let what = keepDisplayOn ? "this Mac and its display awake" : "this Mac awake"
        let how = duration == .indefinite ? "until you turn it off" : "for \(duration.title.lowercased())"
        return AssertionRequest(
            systemSleep: true,
            displaySleep: keepDisplayOn,
            name: "\(appName) Keep Awake",
            details: "\(appName) keeps \(what) \(how).",
            timeoutSeconds: duration.seconds
        )
    }
}
