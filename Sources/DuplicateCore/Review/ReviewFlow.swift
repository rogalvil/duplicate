/// Where a review has got to.
///
/// Ports `FlowStep` (`src/rav/core/duplicate_flow.py:18-31`).
public enum FlowStep: String, Sendable, CaseIterable {
    case scanned
    case interactiveDone
    case decisionsShown
    case dryRunDone
}

/// Something the user can ask for.
///
/// Ports `FlowAction` (`src/rav/core/duplicate_flow.py:7-16`).
public enum FlowAction: String, Sendable, CaseIterable {
    case review
    case showReport
    case showDecisions
    case dryRun
    case apply
    case rescan
    case back
    case exit
}

/// The state machine that decides what the user may do next.
///
/// **The one invariant worth the whole type: `apply` is reachable only from `dryRunDone`.** Nothing is
/// moved until a dry run has been produced and shown. The CLI enforces this too
/// (`src/rav/core/duplicate_flow.py:49-71`), but implicitly, in the branches of its command loop -- so the
/// rule lives wherever the loop happens to be correct.
///
/// Here it is a value type Core owns, and the UI *asks* it. A greyed-out button is a presentation detail; a
/// disabled control that a keyboard shortcut can still reach, or a sheet that stays open after the plan
/// goes stale, would each be a way around a rule that only existed in the view layer.
///
/// `advance` is new logic rather than a port: the CLI has no such function, its transitions are inline.
public struct ReviewFlow: Sendable, Equatable {
    public private(set) var step: FlowStep
    /// Whether a decisions document exists for this scan, saved now or in an earlier session.
    public var hasDecisions: Bool

    /// A fingerprint of the decisions the last dry run was computed from.
    ///
    /// The gate is not "a dry run happened at some point" -- it is "the dry run you were shown describes
    /// what would happen now". Editing a single decision after the dry run invalidates it, because the plan
    /// the user approved no longer matches the plan that would run.
    public private(set) var dryRunFingerprint: String?

    public init(step: FlowStep = .scanned, hasDecisions: Bool = false) {
        self.step = step
        self.hasDecisions = hasDecisions
    }

    /// Whether an action is offered right now.
    ///
    /// Ports the per-step option tables of `menu_options` (`src/rav/core/duplicate_flow.py:40-73`), with
    /// `hasDecisions` actually consulted -- the CLI takes that parameter and never reads it, so its
    /// "ver decisiones" is offered even when there is nothing to show.
    public func isAvailable(_ action: FlowAction) -> Bool {
        switch action {
        case .review, .rescan, .exit:
            return true
        case .showReport:
            return true
        case .showDecisions:
            return hasDecisions
        case .dryRun:
            // Nothing to simulate until something has been decided.
            return hasDecisions
        case .apply:
            return step == .dryRunDone && dryRunFingerprint != nil
        case .back:
            return step == .decisionsShown
        }
    }

    /// The actions available now, in the order a menu would list them.
    public var availableActions: [FlowAction] {
        FlowAction.allCases.filter(isAvailable)
    }

    /// Applies an action, or returns `nil` when it is not available.
    ///
    /// - Parameter fingerprint: for `dryRun`, a digest of the decisions the run was computed from.
    @discardableResult
    public mutating func advance(_ action: FlowAction, fingerprint: String? = nil) -> FlowStep? {
        guard isAvailable(action) else { return nil }
        switch action {
        case .review:
            step = .interactiveDone
            // A fresh round of editing invalidates any dry run: the plan the user saw is no longer the plan
            // that would run.
            dryRunFingerprint = nil
        case .showDecisions:
            step = .decisionsShown
        case .back:
            step = .interactiveDone
        case .dryRun:
            step = .dryRunDone
            dryRunFingerprint = fingerprint
        case .apply:
            step = .scanned
            dryRunFingerprint = nil
        case .rescan:
            step = .scanned
            hasDecisions = false
            dryRunFingerprint = nil
        case .showReport, .exit:
            break
        }
        return step
    }

    /// Records that decisions were edited, which invalidates the dry run.
    ///
    /// Called on every mutation of the review, not only when a session ends. A user who changes one
    /// checkbox after seeing the dry run has to see a new one.
    public mutating func decisionsChanged(hasAny: Bool) {
        hasDecisions = hasAny
        dryRunFingerprint = nil
    }

    /// Whether `fingerprint` still matches the dry run the user was shown.
    public func authorises(_ fingerprint: String) -> Bool {
        step == .dryRunDone && dryRunFingerprint == fingerprint
    }
}

/// Why an apply was refused.
public enum ApplyGateError: Error, Equatable, Sendable {
    /// No dry run has been produced, or the flow is not at that step.
    case noDryRun
    /// The decisions changed since the dry run the user approved.
    case staleDryRun(shown: String?, current: String)
}

/// The last check before anything moves.
///
/// Separate from ``ReviewFlow`` so the refusal has one obvious place to happen, and so a caller cannot
/// forget it by reading the flow's state and drawing its own conclusion.
public enum ApplyGate {
    /// Throws unless the flow authorises exactly this plan.
    public static func authorize(flow: ReviewFlow, fingerprint: String) throws {
        guard flow.dryRunFingerprint != nil, flow.step == .dryRunDone else {
            throw ApplyGateError.noDryRun
        }
        guard flow.authorises(fingerprint) else {
            throw ApplyGateError.staleDryRun(shown: flow.dryRunFingerprint, current: fingerprint)
        }
    }

    /// A fingerprint of what a plan would do.
    ///
    /// Content-based, over the group keys and the paths that would be removed, so two plans that would
    /// touch exactly the same files fingerprint the same and a plan that would touch anything else does
    /// not. Sorted before hashing, so the value does not depend on iteration order.
    public static func fingerprint(of plan: [(group: DuplicateGroup, paths: [String])]) -> String {
        var parts: [String] = []
        for item in plan {
            parts.append(
                item.group.key + "\u{1}" + PathOrder.sorted(item.paths).joined(separator: "\u{2}"))
        }
        let joined = PathOrder.sorted(parts).joined(separator: "\u{3}")
        var hasher = FNV1a()
        hasher.combine(joined)
        return hasher.value
    }
}

/// A small non-cryptographic hash, for a fingerprint that only has to detect change.
///
/// Not SHA-256: this compares a plan against itself minutes later, not against an adversary. Swift's own
/// `Hasher` is seeded per process and would not survive a relaunch, which a fingerprint stored beside a
/// review has to.
struct FNV1a {
    private var state: UInt64 = 0xcbf2_9ce4_8422_2325

    mutating func combine(_ text: String) {
        for byte in text.utf8 {
            state ^= UInt64(byte)
            state = state &* 0x0000_0100_0000_01B3
        }
    }

    /// Mixes in a number, least significant byte first.
    ///
    /// Used by the perceptual cache to derive its salt from the pipeline's own parameters, so that changing the
    /// decode size invalidates the file instead of relying on someone remembering to bump a constant.
    mutating func combine(_ number: UInt64) {
        for shift in stride(from: 0, to: 64, by: 8) {
            state ^= (number >> UInt64(shift)) & 0xFF
            state = state &* 0x0000_0100_0000_01B3
        }
    }

    /// The raw state, for callers that want a number rather than the hex a fingerprint is stored as.
    var rawValue: UInt64 { state }

    var value: String {
        let digits = Array("0123456789abcdef")
        var result = ""
        for shift in stride(from: 60, through: 0, by: -4) {
            result.append(digits[Int((state >> UInt64(shift)) & 0xF)])
        }
        return result
    }
}
