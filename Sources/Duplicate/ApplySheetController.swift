import AppKit
import DuplicateCore
import Synchronization

/// What the apply has done so far, and what it is doing.
///
/// A class holding an `Atomic` and a `Mutex` rather than bare locals: `Mutex` is noncopyable, so it cannot be
/// captured by the escaping closures that write and read it. The class can.
///
/// **Written by the apply task and read by a timer at 10 Hz**, which is the same trade the scan path makes: the
/// folder runner reports every 64 files digested, and nobody reads more than ten updates a second.
final class AppliedCounter: Sendable {
    private let count = Atomic<Int>(0)
    private let latest = Mutex<ApplyProgress?>(nil)

    func set(_ value: Int) {
        count.store(value, ordering: .relaxed)
    }

    func set(_ progress: ApplyProgress) {
        count.store(progress.itemsDone, ordering: .relaxed)
        latest.withLock { $0 = progress }
    }

    var value: Int {
        count.load(ordering: .relaxed)
    }

    var progress: ApplyProgress? {
        latest.withLock { $0 }
    }
}

/// Why one file did not move, in the user's language.
///
/// **This is the one list a user has to read after a destructive action, and it was printing Swift.** A
/// failure came out as `contentChanged(path: "/Users/…")`, which names the case of an enum rather than saying
/// what happened -- and the two things a reader needs from this list are what went wrong and whether their file
/// is still there. Every case here answers both.
///
/// Shared by the three sheets rather than written in each, because a failure means the same thing whichever
/// detector produced it, and three copies is three chances to describe the same state differently.
func disposalFailureText(_ error: DisposalError) -> String {
    switch error {
    case .missing(let path):
        return String(
            format: Strings.string("apply.failure.missing"), (path as NSString).lastPathComponent)
    case .contentChanged(let path):
        return String(
            format: Strings.string("apply.failure.contentChanged"),
            (path as NSString).lastPathComponent)
    case .trashUnavailable(_, let reason):
        return String(format: Strings.string("apply.failure.trashUnavailable"), reason)
    case .quarantineFailed(_, let reason):
        return String(format: Strings.string("apply.failure.quarantineFailed"), reason)
    case .noFreeName:
        return Strings.string("apply.failure.noFreeName")
    // Not expected in a report -- the runners break out of the loop on a cancellation instead of recording it --
    // but a case that says "cancelled" is better than a case that says nothing if one ever arrives.
    case .cancelled:
        return Strings.string("apply.failure.cancelled")
    }
}

/// The sentence for a progress report, or `nil` when there is nothing new to say.
///
/// Here rather than in Core, because Core never produces prose. The path keeps its first and last two
/// components: a folder that differs from its twin at the end is exactly the case here, so a tail truncation
/// would hide the part that identifies it.
func applyProgressText(_ progress: ApplyProgress) -> String? {
    let name = PathElision.elide(progress.path)
    switch progress.stage {
    case .verifying(let filesChecked) where filesChecked > 0:
        return String(
            format: Strings.string("apply.progress.verifying.files"),
            progress.itemsDone + 1, progress.itemCount, name, filesChecked)
    case .verifying:
        return String(
            format: Strings.string("apply.progress.verifying"),
            progress.itemsDone + 1, progress.itemCount, name)
    case .moving:
        return String(
            format: Strings.string("apply.progress.moving"),
            min(progress.itemsDone + 1, progress.itemCount), progress.itemCount, name)
    // The bar advances on this; the label keeps what it last said rather than flashing a line for an item that
    // is already behind us.
    case .done:
        return nil
    }
}

/// Shows what an apply would do, then does it.
///
/// **One sheet for both steps on purpose.** The dry run and the apply are the same plan seen twice, and the
/// only thing that authorises the second is having seen the first. Two separate windows would let the user
/// keep a stale dry run open and act on it -- which ``ApplyGate`` refuses anyway, but a UI that invites a
/// refusal is a UI that trains people to ignore refusals.
@MainActor
final class ApplySheetController: NSWindowController {
    /// Called after a successful apply, with the report, so the review can offer an undo.
    var onApplied: ((DisposalReport) -> Void)?
    /// Called after an undo put files back.
    ///
    /// **Separate from `onApplied` because the review has to re-read the disk either way.** Without this the
    /// window keeps showing "this file no longer exists" for a file that is sitting right there again --
    /// reported from real use, and the reason this callback exists.
    var onUndone: (() -> Void)?
    /// Whether an apply is under way, for `applicationShouldTerminate`.
    private(set) var isApplying = false

    private let stateDirectory: StateDirectory
    private let plan: ApplyPlan
    private let fingerprint: String
    private var flow: ReviewFlow
    private var report: DisposalReport?
    private var progressTimer: Timer?
    /// Held so the stop button can reach the run.
    private var applyTask: Task<Void, Never>?
    /// Kept so a selftest can await an undo: the work moved into a `Task` when folder manifests started
    /// being built against the cache instead of on the calling thread.
    private var undoTask: Task<Void, Never>?

    private let headlineLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(wrappingLabelWithString: "")
    private let listView = NSTextView()
    private let progressBar = NSProgressIndicator()
    /// What the apply is doing, because a bar that sits still on a folder pair for minutes with nothing said
    /// is indistinguishable from a hang -- and the user's remedy for a hang is force-quitting an app that is
    /// halfway through moving their files.
    private let progressLabel = NSTextField(labelWithString: "")
    private let applyButton = NSButton()
    private let cancelButton = NSButton()
    private let undoButton = NSButton()

    /// - Parameters:
    ///   - flow: already advanced to `.dryRunDone` with `fingerprint`. The sheet does not advance it
    ///     itself: the caller owns the review's state, and a sheet that silently authorised its own apply
    ///     would be the gate authorising itself.
    init(
        plan: ApplyPlan,
        fingerprint: String,
        flow: ReviewFlow,
        stateDirectory: StateDirectory
    ) {
        self.plan = plan
        self.fingerprint = fingerprint
        self.flow = flow
        self.stateDirectory = stateDirectory

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 380),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.title = Strings.string("apply.window.title")
        super.init(window: window)
        build()
        showPlan()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("not used: this window is built in code, there is no nib")
    }

    private func build() {
        guard let window else { return }
        headlineLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        detailLabel.font = .systemFont(ofSize: 11)
        detailLabel.textColor = .secondaryLabelColor

        listView.isEditable = false
        listView.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        listView.drawsBackground = false
        let scroll = NSScrollView()
        scroll.documentView = listView
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false

        progressBar.style = .bar
        progressBar.isIndeterminate = false
        progressBar.minValue = 0
        progressBar.maxValue = Double(max(1, plan.fileCount))
        progressBar.isHidden = true
        progressLabel.isHidden = true
        progressLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        progressLabel.textColor = .secondaryLabelColor
        // A label whose intrinsic width is its text would put a floor under the sheet, and this text carries a
        // path. Same cure as everywhere else in this app: let it compress.
        progressLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        progressLabel.lineBreakMode = .byTruncatingMiddle

        applyButton.title = Strings.string("apply.button.apply")
        applyButton.bezelStyle = .rounded
        applyButton.keyEquivalent = "\r"
        applyButton.target = self
        applyButton.action = #selector(applyNow(_:))

        cancelButton.title = Strings.string("button.cancel")
        cancelButton.bezelStyle = .rounded
        cancelButton.keyEquivalent = "\u{1b}"
        cancelButton.target = self
        cancelButton.action = #selector(dismiss(_:))

        undoButton.title = Strings.string("apply.button.undo")
        undoButton.bezelStyle = .rounded
        undoButton.target = self
        undoButton.action = #selector(undoNow(_:))
        undoButton.isHidden = true

        let buttons = NSStackView(views: [undoButton, cancelButton, applyButton])
        buttons.orientation = .horizontal
        buttons.spacing = 10

        let content = NSStackView(views: [
            headlineLabel, detailLabel, scroll, progressBar, progressLabel, buttons,
        ])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 10
        content.edgeInsets = NSEdgeInsets(top: 16, left: 20, bottom: 16, right: 20)
        content.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: container.topAnchor),
            content.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            content.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            scroll.widthAnchor.constraint(equalToConstant: 500),
            scroll.heightAnchor.constraint(equalToConstant: 200),
            progressBar.widthAnchor.constraint(equalToConstant: 500),
            detailLabel.widthAnchor.constraint(equalToConstant: 500),
        ])
        window.contentView = container
    }

    // MARK: - The dry run

    private func showPlan() {
        headlineLabel.stringValue = String(
            format: Strings.string("apply.headline"),
            plan.fileCount, ByteSize.format(plan.byteCount)
        )
        detailLabel.stringValue = Strings.string("apply.detail")
        // Every path, not a sample. A destructive action's confirmation that shows "and 3,997 more" is
        // asking for consent to something the user cannot see.
        listView.string = plan.items.map(\.path).joined(separator: "\n")
        applyButton.isEnabled = !plan.isEmpty
    }

    // MARK: - The apply

    @objc private func applyNow(_ sender: Any?) {
        // **The gate, checked here and not trusted from the button's state.** A disabled control that a
        // keyboard shortcut can still reach is not a rule.
        do {
            try ApplyGate.authorize(flow: flow, fingerprint: fingerprint)
        } catch {
            presentGateRefusal(error)
            return
        }

        isApplying = true
        applyButton.isEnabled = false
        // **The stop button stays alive, and that is the point of this change.** Verifying and moving hundreds of
        // items takes minutes, and a progress bar with no way out is not a choice. Cancelling stops before the
        // next item and the journal still describes everything already moved.
        cancelButton.title = Strings.string("apply.button.stop")
        progressBar.isHidden = false
        progressLabel.isHidden = false
        progressBar.doubleValue = 0
        headlineLabel.stringValue = Strings.string("apply.running")

        let runner = ApplyRunner(state: stateDirectory)
        let plan = self.plan
        let sessionID = runner.sessionIdentifier(at: Date())
        let instant = ScanIdentifier.Instant(Date())
        let progress = AppliedCounter()

        applyTask = Task.detached(priority: .userInitiated) {
            let outcome: Result<DisposalReport, any Error>
            do {
                outcome = .success(
                    try runner.run(
                        plan,
                        sessionID: sessionID,
                        instant: instant,
                        // The Trash first, quarantine only when it refuses -- which is what happens on a
                        // network mount or a read-only volume.
                        disposer: FallbackDisposer(
                            quarantineRoot: QuarantineDisposer.defaultRoot(),
                            sessionID: sessionID
                        ),
                        onProgress: { report in progress.set(report) }
                    )
                )
            } catch {
                outcome = .failure(error)
            }
            await MainActor.run { [weak self] in
                self?.finish(outcome)
            }
        }

        // Pulled at 10 Hz, like the scan: an apply of 4,000 files must not push 4,000 redraws.
        //
        // The work item is `@MainActor`-isolated rather than a bare closure: a `Timer` closure is
        // nonisolated, and handing `timer` into it to invalidate itself is a data race the compiler
        // rejects. Reading `isApplying` on the main actor and stopping there is the same behaviour without
        // the capture.
        startProgressTimer(reading: progress)
    }

    private func startProgressTimer(reading progress: AppliedCounter) {
        let timer = Timer(timeInterval: 0.1, repeats: true) { _ in
            MainActor.assumeIsolated {
                self.progressBar.doubleValue = Double(progress.value)
                if let report = progress.progress, let text = applyProgressText(report) {
                    self.progressLabel.stringValue = text
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        progressTimer = timer
    }

    private func finish(_ outcome: Result<DisposalReport, any Error>) {
        isApplying = false
        progressTimer?.invalidate()
        progressTimer = nil
        progressBar.isHidden = true
        progressLabel.isHidden = true
        cancelButton.isEnabled = true
        cancelButton.title = Strings.string("button.close")
        applyButton.isHidden = true

        switch outcome {
        case .failure(let error):
            headlineLabel.stringValue = Strings.string("apply.failed.title")
            detailLabel.stringValue = String(describing: error)
        case .success(let report):
            self.report = report
            onApplied?(report)
            headlineLabel.stringValue =
                report.wasCancelled
                ? String(
                    format: Strings.string("apply.stopped"),
                    report.movedCount, ByteSize.format(report.freedBytes))
                : String(
                    format: Strings.string("apply.done.headline"),
                    report.movedCount, ByteSize.format(report.freedBytes)
                )

            var notes: [String] = []
            if report.wasCancelled { notes.append(Strings.string("apply.stopped.note")) }
            if report.quarantinedCount > 0 {
                notes.append(
                    String(
                        format: Strings.string("apply.done.quarantined"), report.quarantinedCount))
            }
            if !report.failures.isEmpty {
                notes.append(
                    String(format: Strings.string("apply.done.failed"), report.failures.count))
            }
            if report.stoppedEarly {
                notes.append(Strings.string("apply.done.stoppedEarly"))
            }
            detailLabel.stringValue =
                notes.isEmpty ? Strings.string("apply.done.clean") : notes.joined(separator: " ")

            // The failures are what the user needs to see, so they replace the plan in the list.
            if report.failures.isEmpty {
                listView.string = report.moved.map {
                    "\($0.originalPath)  \u{2192}  \($0.resultingPath)"
                }
                .joined(separator: "\n")
            } else {
                listView.string = report.failures.map {
                    "\($0.path)  \u{2014}  \(disposalFailureText($0.reason))"
                }
                .joined(separator: "\n")
            }
            undoButton.isHidden = report.movedCount == 0
        }
    }

    @objc private func undoNow(_ sender: Any?) {
        guard let report else { return }
        undoButton.isEnabled = false
        // A folder undo now awaits its manifests, built against the cache instead of on this thread.
        undoTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let outcome = await UndoCoordinator.undo(
                sessionID: report.sessionID, in: stateDirectory)
            onUndone?()
            headlineLabel.stringValue = String(
                format: Strings.string("undo.done.headline"),
                outcome.restoredCount, ByteSize.format(outcome.restoredBytes)
            )
            detailLabel.stringValue = outcome.summary
            listView.string = outcome.detail
        }
    }

    private func presentGateRefusal(_ error: any Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = Strings.string("apply.refused.title")
        alert.informativeText = Strings.string("apply.refused.body")
        alert.addButton(withTitle: Strings.string("button.ok"))
        if let window {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }

    @objc private func dismiss(_ sender: Any?) {
        // While an apply is running this stops it and stays open: the report of what already moved -- and the undo
        // for it -- is the whole reason not to close.
        if isApplying {
            applyTask?.cancel()
            cancelButton.isEnabled = false
            cancelButton.title = Strings.string("scan.stopping")
            return
        }
        guard !isApplying else { return }
        if let sheetParent = window?.sheetParent {
            sheetParent.endSheet(window!)
        } else {
            window?.close()
        }
    }

    // MARK: - Selftest hooks

    var headlineText: String { headlineLabel.stringValue }
    var detailText: String { detailLabel.stringValue }
    var listText: String { listView.string }
    var canApply: Bool { applyButton.isEnabled }
    var canUndo: Bool { !undoButton.isHidden && undoButton.isEnabled }
    var lastReport: DisposalReport? { report }

    func applyForSelftest() { applyNow(nil) }

    /// Whether the progress line is showing, and what it says.
    var progressLineForSelftest: (hidden: Bool, text: String) {
        (progressLabel.isHidden, progressLabel.stringValue)
    }
    func undoForSelftest() { undoNow(nil) }

    /// Waits for an undo started by ``undoForSelftest()``.
    func awaitUndoForSelftest() async { await undoTask?.value }

    /// Waits for a running apply to finish.
    func awaitApplyForSelftest() async {
        for _ in 0..<400 where isApplying {
            try? await Task.sleep(for: .milliseconds(25))
        }
    }
}
