import AppKit
import DuplicateCore
import Synchronization

/// Shows what a folder apply would do, then does it.
///
/// The third sheet of this shape, and the one with the most to refuse. **The list it shows is folders, and each
/// one is a tree** -- so the dry run names not only what would move but what was left out: descendants collapsed
/// into an ancestor already going, and folders another decision keeps or keeps something inside of.
///
/// **A refusal is a first-class outcome**, and here it is the most informative thing on screen: a folder is
/// declined because it holds files the keeper does not have, and those files are named. That is the check doing
/// its job.
@MainActor
final class FolderApplySheetController: NSWindowController {
    var onApplied: ((FolderDisposalReport) -> Void)?
    var onUndone: (() -> Void)?
    private(set) var isApplying = false

    private let stateDirectory: StateDirectory
    private let plan: FolderApplyPlan
    private let fingerprint: String
    private var flow: ReviewFlow
    private var report: FolderDisposalReport?
    private var progressTimer: Timer?
    private var applyTask: Task<Void, Never>?

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

    /// - Parameter flow: already advanced to `.dryRunDone` with `fingerprint`. The sheet does not advance it
    ///   itself: a sheet that authorised its own apply would be the gate authorising itself.
    init(
        plan: FolderApplyPlan,
        fingerprint: String,
        flow: ReviewFlow,
        stateDirectory: StateDirectory
    ) {
        self.plan = plan
        self.fingerprint = fingerprint
        self.flow = flow
        self.stateDirectory = stateDirectory

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 580, height: 400),
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
    required init?(coder: NSCoder) { fatalError("not from a nib") }

    private func build() {
        guard let window else { return }
        headlineLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        detailLabel.font = .systemFont(ofSize: 11)
        detailLabel.textColor = .secondaryLabelColor
        for label in [headlineLabel, detailLabel] {
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }

        listView.isEditable = false
        listView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        let scroll = NSScrollView()
        scroll.documentView = listView
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        progressBar.isIndeterminate = false
        progressBar.minValue = 0
        progressBar.maxValue = Double(max(1, plan.items.count))
        progressBar.isHidden = true
        progressLabel.isHidden = true
        progressLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        progressLabel.textColor = .secondaryLabelColor
        // A label whose intrinsic width is its text would put a floor under the sheet, and this text carries a
        // path. Same cure as everywhere else in this app: let it compress.
        progressLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        progressLabel.lineBreakMode = .byTruncatingMiddle
        progressBar.translatesAutoresizingMaskIntoConstraints = false

        applyButton.title = Strings.string("apply.button.apply")
        applyButton.bezelStyle = .rounded
        applyButton.keyEquivalent = "\r"
        applyButton.target = self
        applyButton.action = #selector(applyNow(_:))
        applyButton.isEnabled = !plan.isEmpty

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
        buttons.alignment = .centerY

        let content = NSStackView(views: [
            headlineLabel, detailLabel, scroll, progressBar, progressLabel, buttons,
        ])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 10
        content.edgeInsets = NSEdgeInsets(top: 16, left: 18, bottom: 16, right: 18)
        content.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: container.topAnchor),
            content.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            content.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 18),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -18),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 180),
            progressBar.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 18),
            progressBar.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -18),
            buttons.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -18),
        ])
        window.contentView = container
    }

    /// The dry run: what would move, and what would not.
    private func showPlan() {
        headlineLabel.stringValue = String(
            format: Strings.string("folders.apply.headline"), plan.items.count)

        var details: [String] = []
        // Said before the button is pressed: every folder is checked for containment when it moves, and one that
        // holds a file the keeper lacks is skipped. Learning that from the result would read as a malfunction.
        details.append(Strings.string("folders.apply.verifyNote"))
        if !plan.contradicted.isEmpty {
            details.append(
                String(format: Strings.string("folders.apply.excluded"), plan.contradicted.count))
        }
        // **The collapsed ones are named too.** A folder missing from this list because an ancestor is already on
        // it is not an omission, and a reader counting rows would otherwise think one went missing.
        if !plan.collapsed.isEmpty {
            details.append(
                String(format: Strings.string("folders.apply.collapsed"), plan.collapsed.count))
        }
        detailLabel.stringValue = details.joined(separator: "\n")

        listView.string =
            plan.isEmpty
            ? Strings.string("folders.apply.nothing")
            : plan.items.map {
                String(format: Strings.string("folders.apply.item"), $0.path, $0.recordedFileCount)
            }.joined(separator: "\n")
    }

    @objc private func applyNow(_ sender: Any?) {
        // The gate, checked here rather than trusted from the button's state: a disabled control a keyboard
        // shortcut can still reach is not a rule.
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

        let runner = FolderApplyRunner(state: stateDirectory)
        let plan = self.plan
        let sessionID = runner.sessionIdentifier(at: Date())
        let instant = ScanIdentifier.Instant(Date())
        let progress = AppliedCounter()

        applyTask = Task.detached(priority: .userInitiated) {
            let outcome: Result<FolderDisposalReport, any Error>
            do {
                outcome = .success(
                    try await runner.run(
                        plan,
                        sessionID: sessionID,
                        instant: instant,
                        // The Trash first, quarantine only when it refuses -- a network mount or a read-only
                        // volume.
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

    private func finish(_ outcome: Result<FolderDisposalReport, any Error>) {
        isApplying = false
        progressTimer?.invalidate()
        progressTimer = nil
        progressBar.isHidden = true
        progressLabel.isHidden = true
        cancelButton.isEnabled = true
        cancelButton.title = Strings.string("button.close")

        switch outcome {
        case .failure(let error):
            headlineLabel.stringValue = Strings.string("apply.failed.title")
            listView.string = String(describing: error)
        case .success(let result):
            report = result
            if result.wasCancelled {
                headlineLabel.stringValue = String(
                    format: Strings.string("apply.stopped"),
                    result.moved.count, ByteSize.format(result.movedBytes))
                detailLabel.stringValue = Strings.string("apply.stopped.note")
            } else {
                headlineLabel.stringValue = String(
                    format: Strings.string("folders.apply.done"),
                    result.moved.count, ByteSize.format(result.movedBytes))
            }

            var lines: [String] = []
            // **The refusals first**, because they are the part a reader has to act on: those files are still
            // there and their pairs need looking at again.
            if !result.refused.isEmpty {
                lines.append(
                    String(
                        format: Strings.string("folders.apply.refusedHeader"), result.refused.count)
                )
                for entry in result.refused.prefix(50) {
                    lines.append("    \(entry.path)  —  \(Self.reason(entry.reason))")
                }
            }
            if !result.failures.isEmpty {
                lines.append(
                    String(format: Strings.string("apply.done.failed"), result.failures.count))
                for failure in result.failures.prefix(50) {
                    lines.append("    \(failure.path)  —  \(failure.reason)")
                }
            }
            if result.stoppedEarly { lines.append(Strings.string("apply.done.stoppedEarly")) }
            for outcome in result.moved.prefix(200) { lines.append(outcome.originalPath) }
            listView.string = lines.joined(separator: "\n")

            undoButton.isHidden = result.moved.isEmpty
            onApplied?(result)
        }
    }

    static func reason(_ refusal: FolderRefusal) -> String {
        switch refusal {
        case .wouldLoseFiles(let count, let examples):
            // **The names, not just the count.** "3 files would be lost" is a number; "3 files would be lost,
            // starting with taxes-2019.pdf" is a decision.
            return String(
                format: Strings.string("folders.apply.refused.wouldLose"),
                count, examples.joined(separator: ", "))
        case .keeperMissing(let path):
            return String(
                format: Strings.string("folders.apply.refused.keeperMissing"),
                (path as NSString).lastPathComponent)
        case .unreadable(let path):
            return String(
                format: Strings.string("similar.apply.refused.unreadable"),
                (path as NSString).lastPathComponent)
        case .missing:
            return Strings.string("similar.apply.refused.missing")
        }
    }

    @objc private func undoNow(_ sender: Any?) {
        guard let report, !report.moved.isEmpty else { return }
        let outcome = UndoCoordinator.undo(sessionID: report.sessionID, in: stateDirectory)
        headlineLabel.stringValue = outcome.summary
        listView.string = outcome.detail
        undoButton.isHidden = true
        onUndone?()
    }

    private func presentGateRefusal(_ error: any Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = Strings.string("apply.refused.title")
        alert.informativeText = Strings.string("apply.refused.body")
        alert.addButton(withTitle: Strings.string("button.ok"))
        alert.runModal()
    }

    @objc private func dismiss(_ sender: Any?) {
        // **While an apply is running this stops it and stays open**, because the report of what already moved --
        // and the undo for it -- is the whole reason not to close.
        if isApplying {
            applyTask?.cancel()
            cancelButton.isEnabled = false
            cancelButton.title = Strings.string("scan.stopping")
            return
        }
        applyTask?.cancel()
        window?.sheetParent?.endSheet(window!)
        window?.close()
    }

    // MARK: - Selftest hooks

    var headlineText: String { headlineLabel.stringValue }
    var detailText: String { detailLabel.stringValue }
    var listText: String { listView.string }
    var isApplyEnabled: Bool { applyButton.isEnabled }
    var isUndoVisible: Bool { !undoButton.isHidden }
    var requiredContentSize: NSSize {
        window?.contentView?.layoutSubtreeIfNeeded()
        return window?.contentView?.fittingSize ?? .zero
    }

    /// Whether the gate would let this sheet apply, without applying.
    ///
    /// **Exposed because asserting on the sheet's text does not test the gate.** A first version of the harness
    /// checked the headline and the list and passed with `flow.advance(.dryRun,…)` removed -- the refusal only
    /// happens when the button is pressed, and the harness was not pressing it. Pressing it there would move real
    /// files, which the `similar-apply` mode already does properly, with cleanup.
    var isAuthorizedForSelftest: Bool {
        (try? ApplyGate.authorize(flow: flow, fingerprint: fingerprint)) != nil
    }

    func applyForSelftest() { applyNow(nil) }
    func undoForSelftest() { undoNow(nil) }
    var reportForSelftest: FolderDisposalReport? { report }
}
