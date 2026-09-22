/// Who is still watching the fans.
///
/// Guarantee 1 of the restore-Auto rules: when the last XPC client goes away,
/// the fans go back to Auto. A fan curve therefore needs the app running,
/// which is what Macs Fan Control does as well, and it is the reason a crash
/// of the app cannot leave a fan pinned.
///
/// A pure value type: XPC hands out one token per connection, and the helper
/// only has to act on the `true` this returns.
public struct FanClientRegistry: Sendable, Equatable {
    private var tokens: Set<UInt64> = []

    public init() {}

    public var count: Int { tokens.count }
    public var isEmpty: Bool { tokens.isEmpty }

    /// True when this was the first client.
    @discardableResult
    public mutating func add(_ token: UInt64) -> Bool {
        let wasEmpty = tokens.isEmpty
        return tokens.insert(token).inserted && wasEmpty
    }

    /// True when the last client just left, which means: restore Auto now.
    ///
    /// A token that was never registered, or one that is removed twice
    /// because XPC sent both an interruption and an invalidation, returns
    /// false.
    @discardableResult
    public mutating func remove(_ token: UInt64) -> Bool {
        guard tokens.remove(token) != nil else { return false }
        return tokens.isEmpty
    }
}

/// What a power transition must do to the fans.
public enum FanPowerAction: Sendable, Equatable {
    case restoreAuto
    case reapplyDesired
    case nothing
}

/// Guarantee 4: Auto on the way into sleep, the held modes again on the way
/// out. The SMC drops the forced mode across a sleep, so a wake without a
/// rewrite would silently leave a curve doing nothing.
public struct FanPowerPolicy: Sendable, Equatable {
    private var asleep = false
    /// True between a sleep that parked the fans and the next wake. The wake
    /// must end that hold even when the wish is gone by then.
    private var parked = false

    public init() {}

    public mutating func willSleep(hasDesiredMode: Bool) -> FanPowerAction {
        // macOS can send the message twice for one sleep.
        guard !asleep else { return .nothing }
        asleep = true
        parked = hasDesiredMode
        return hasDesiredMode ? .restoreAuto : .nothing
    }

    /// `hasDesiredMode` is asked again on wake, because the fans were put into
    /// Auto but the wish itself was kept. A client may also have set Auto
    /// during a dark wake, so a parked sleep always ends in a reapply, which
    /// is what lifts the governor's sleep hold.
    public mutating func hasPoweredOn(hasDesiredMode: Bool) -> FanPowerAction {
        let wasParked = parked
        asleep = false
        parked = false
        return hasDesiredMode || wasParked ? .reapplyDesired : .nothing
    }
}
