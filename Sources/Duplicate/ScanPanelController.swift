import AppKit
import DuplicateCore

/// Starts a scan and shows it running.
///
/// One window with two faces -- options, then progress -- because they are one task and two windows would
/// make the user find the second one.
///
/// **Progress is pulled, not pushed.** The scanner counts with atomics and this reads a snapshot on a timer
/// at 10 Hz. The CLI's hooks fire once per file; at 800,000 files a pushed update would be 800,000 actor
/// hops to redraw a label nobody can read more than ten times a second. Ten reads per second instead.
@MainActor
final class ScanPanelController: NSWindowController {
    /// Called with the scan that was saved, so the library can select it.
    var onFinished: ((DuplicateScan) -> Void)?

    private let stateDirectory: StateDirectory
    private let session: ScanSession

    private var root: String?
    private var task: Task<Void, Never>?
    private var counters = ProgressCounters()
    private var timer: Timer?
    private var startedAt: ContinuousClock.Instant?

    private let rootLabel = NSTextField(labelWithString: "")
    private let chooseButton = NSButton()
    private let hiddenToggle = NSButton()
    private let packagesToggle = NSButton()
    private let cacheToggle = NSButton()
    private let minimumSizeField = NSTextField()
    private let startButton = NSButton()
    private let cancelButton = NSButton()

    private let phaseLabel = NSTextField(labelWithString: "")
    private let countsLabel = NSTextField(labelWithString: "")
    private let pathLabel = NSTextField(labelWithString: "")
    private let bar = NSProgressIndicator()
    private let optionsStack: NSStackView
    private let progressStack: NSStackView

    init(stateDirectory: StateDirectory) {
        self.stateDirectory = stateDirectory
        self.session = ScanSession(store: ScanStore(state: stateDirectory))
        self.optionsStack = NSStackView()
        self.progressStack = NSStackView()

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 260),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = Strings.string("scan.window.title")
        window.center()
        super.init(window: window)
        window.delegate = self
        build()
        showOptions()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("not used: this window is built in code, there is no nib")
    }

    // MARK: - Layout

    private func build() {
        guard let window else { return }

        rootLabel.stringValue = Strings.string("scan.noRoot")
        rootLabel.textColor = .secondaryLabelColor
        rootLabel.lineBreakMode = .byTruncatingHead

        chooseButton.title = Strings.string("scan.chooseFolder")
        chooseButton.bezelStyle = .rounded
        chooseButton.target = self
        chooseButton.action = #selector(chooseRoot(_:))

        for (button, key, on) in [
            (hiddenToggle, "scan.option.hidden", false),
            (packagesToggle, "scan.option.packages", false),
            (cacheToggle, "scan.option.cache", true),
        ] {
            button.setButtonType(.switch)
            button.title = Strings.string(key)
            button.state = on ? .on : .off
        }

        minimumSizeField.stringValue = "1"
        minimumSizeField.placeholderString = "1"
        minimumSizeField.alignment = .right
        minimumSizeField.widthAnchor.constraint(equalToConstant: 90).isActive = true
        let sizeRow = NSStackView(views: [
            NSTextField(labelWithString: Strings.string("scan.option.minimumSize")),
            minimumSizeField,
        ])
        sizeRow.orientation = .horizontal
        sizeRow.spacing = 8

        startButton.title = Strings.string("scan.start")
        startButton.bezelStyle = .rounded
        startButton.keyEquivalent = "\r"
        startButton.target = self
        startButton.action = #selector(startScan(_:))
        startButton.isEnabled = false

        cancelButton.title = Strings.string("button.cancel")
        cancelButton.bezelStyle = .rounded
        cancelButton.keyEquivalent = "\u{1b}"
        cancelButton.target = self
        cancelButton.action = #selector(cancelScan(_:))

        let rootRow = NSStackView(views: [chooseButton, rootLabel])
        rootRow.orientation = .horizontal
        rootRow.spacing = 8

        optionsStack.orientation = .vertical
        optionsStack.alignment = .leading
        optionsStack.spacing = 8
        for view in [rootRow, hiddenToggle, packagesToggle, cacheToggle, sizeRow] {
            optionsStack.addArrangedSubview(view)
        }

        bar.style = .bar
        bar.isIndeterminate = true
        bar.usesThreadedAnimation = true
        phaseLabel.font = .systemFont(ofSize: 13, weight: .medium)
        // Monospaced digits, because a proportional numeral updating ten times a second jumps sideways.
        countsLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        countsLabel.textColor = .secondaryLabelColor
        pathLabel.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        pathLabel.textColor = .tertiaryLabelColor
        pathLabel.lineBreakMode = .byTruncatingHead

        progressStack.orientation = .vertical
        progressStack.alignment = .leading
        progressStack.spacing = 6
        for view in [phaseLabel, bar, countsLabel, pathLabel] {
            progressStack.addArrangedSubview(view)
        }

        let buttons = NSStackView(views: [cancelButton, startButton])
        buttons.orientation = .horizontal
        buttons.spacing = 10

        let content = NSStackView(views: [optionsStack, progressStack, buttons])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 14
        content.edgeInsets = NSEdgeInsets(top: 16, left: 20, bottom: 16, right: 20)
        content.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: container.topAnchor),
            content.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            content.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            bar.widthAnchor.constraint(equalToConstant: 460),
            rootLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 340),
            pathLabel.widthAnchor.constraint(equalToConstant: 460),
        ])
        window.contentView = container
    }

    private func showOptions() {
        optionsStack.isHidden = false
        progressStack.isHidden = true
        startButton.isHidden = false
    }

    private func showProgress() {
        optionsStack.isHidden = true
        progressStack.isHidden = false
        startButton.isHidden = true
    }

    // MARK: - Actions

    /// Asks for a folder.
    ///
    /// `NSOpenPanel` is what grants access to it: the user picking a folder is what macOS treats as
    /// consent, and it is why the app never needs to ask for Full Disk Access.
    @objc private func chooseRoot(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = Strings.string("scan.chooseFolder.prompt")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        setRoot(url.path(percentEncoded: false))
    }

    private func setRoot(_ path: String) {
        switch session.check(root: path) {
        case .ok:
            root = path
            rootLabel.stringValue = path
            rootLabel.textColor = .labelColor
            startButton.isEnabled = true
        case .missing, .notADirectory, .unreadable:
            root = nil
            rootLabel.stringValue = Strings.string("scan.badRoot")
            rootLabel.textColor = .systemOrange
            startButton.isEnabled = false
        }
    }

    private var request: ScanSession.Request? {
        guard let root else { return nil }
        var policy = ScanPolicy()
        policy.includesHiddenFiles = hiddenToggle.state == .on
        policy.includesHiddenDirectories = hiddenToggle.state == .on
        policy.packageHandling = packagesToggle.state == .on ? .descend : .skipEntirely
        // A blank field means the default rather than zero: an empty box reads as "I did not choose", and
        // zero would put every empty file in the scan.
        let text = minimumSizeField.stringValue.trimmingCharacters(in: .whitespaces)
        policy.minimumSize = text.isEmpty ? 1 : (try? ByteSize.parse(text)) ?? 1
        return ScanSession.Request(
            root: root, policy: policy, usesCache: cacheToggle.state == .on)
    }

    @objc private func startScan(_ sender: Any?) {
        guard let request else { return }
        counters = ProgressCounters()
        startedAt = ContinuousClock.now
        showProgress()
        bar.startAnimation(nil)
        startTimer()

        let session = self.session
        let counters = self.counters
        task = Task { [weak self] in
            let result: Result<ScanSession.Result, any Error>
            do {
                result = .success(
                    try await session.run(request, at: Date(), progress: counters))
            } catch {
                result = .failure(error)
            }
            await MainActor.run { [weak self] in
                self?.finish(result)
            }
        }
    }

    @objc private func cancelScan(_ sender: Any?) {
        guard let task else {
            window?.close()
            return
        }
        // Cancellation is cooperative: the finder checks at four points, so this returns quickly rather
        // than instantly. The button reads as "stopping" so the delay is not mistaken for a hang.
        cancelButton.isEnabled = false
        cancelButton.title = Strings.string("scan.stopping")
        task.cancel()
    }

    private func finish(_ result: Result<ScanSession.Result, any Error>) {
        stopTimer()
        bar.stopAnimation(nil)
        task = nil

        switch result {
        case .failure(is CancellationError):
            // Nothing was written, so there is nothing to report but the fact.
            window?.close()
        case .failure(let error):
            presentFailure(String(describing: error))
        case .success(let scanResult):
            if let failure = scanResult.saveFailure {
                // The scan itself succeeded. Saying so matters: the work is not lost, it is just not on
                // disk, and the user can still review it.
                presentFailure(failure)
            } else {
                onFinished?(scanResult.scan)
                reportUnreadable(scanResult)
                window?.close()
            }
        }
    }

    /// Tells the user about directories the walk could not enter.
    ///
    /// **The failure that must not ship silently.** An unreadable subtree produces "no duplicates found",
    /// which looks exactly like success. The count is the only thing the app can honestly report.
    private func reportUnreadable(_ result: ScanSession.Result) {
        let count = result.outcome.walk.inaccessiblePaths.count
        guard count > 0 else { return }
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = Strings.string("scan.inaccessible.title")
        alert.informativeText = String(
            format: Strings.string("scan.inaccessible.body"), count)
        alert.addButton(withTitle: Strings.string("button.ok"))
        alert.addButton(withTitle: Strings.string("scan.inaccessible.openSettings"))
        if alert.runModal() == .alertSecondButtonReturn {
            // A TCC grant does not apply to a process already running, which is why the sheet says to
            // relaunch rather than implying the scan can be retried in place.
            if let url = URL(
                string:
                    "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")
            {
                NSWorkspace.shared.open(url)
            }
        }
    }

    private func presentFailure(_ message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = Strings.string("scan.failed.title")
        alert.informativeText = message
        alert.addButton(withTitle: Strings.string("button.ok"))
        alert.runModal()
        showOptions()
        cancelButton.isEnabled = true
        cancelButton.title = Strings.string("button.cancel")
    }

    // MARK: - Progress

    /// Ten reads a second, on the common run loop mode.
    ///
    /// `.common` and not the default: without it a scan that finishes while a menu is open stops updating,
    /// because tracking modes do not run default-mode timers.
    private func startTimer() {
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshProgress() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        refreshProgress()
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func refreshProgress() {
        let snapshot = counters.snapshot()
        phaseLabel.stringValue = Strings.string("scan.phase.\(snapshot.phase)")

        if let fraction = snapshot.fraction {
            bar.isIndeterminate = false
            bar.doubleValue = fraction * 100
        } else {
            bar.isIndeterminate = true
        }

        var parts: [String] = [
            String(format: Strings.string("scan.counts.files"), snapshot.filesSeen)
        ]
        if snapshot.candidates > 0 {
            parts.append(
                String(
                    format: Strings.string("scan.counts.hashed"),
                    snapshot.filesHashed, snapshot.candidates))
        }
        if snapshot.bytesRead > 0 {
            parts.append(ByteSize.format(snapshot.bytesRead))
        }
        if snapshot.cacheHits > 0 {
            parts.append(
                String(format: Strings.string("scan.counts.cached"), snapshot.cacheHits))
        }
        if let startedAt {
            let seconds = Int((ContinuousClock.now - startedAt).components.seconds)
            parts.append(String(format: Strings.string("scan.counts.elapsed"), seconds))
        }
        countsLabel.stringValue = parts.joined(separator: "  \u{00B7}  ")
        pathLabel.stringValue = snapshot.currentPath
    }

    // MARK: - Selftest hooks

    var isRunning: Bool { task != nil }
    var phaseText: String { phaseLabel.stringValue }
    var countsText: String { countsLabel.stringValue }
    var isShowingProgress: Bool { !progressStack.isHidden }
    var canStart: Bool { startButton.isEnabled }

    func setRootForSelftest(_ path: String) { setRoot(path) }
    func startForSelftest() { startScan(nil) }
    func cancelForSelftest() { cancelScan(nil) }
    func refreshProgressForSelftest() { refreshProgress() }
    func requestForSelftest() -> ScanSession.Request? { request }

    /// Waits for the running scan to end, however it ends.
    func awaitCompletionForSelftest() async {
        _ = await task?.value
    }
}

// MARK: - Window lifecycle

extension ScanPanelController: NSWindowDelegate {
    /// Closing the window cancels the scan rather than orphaning it.
    ///
    /// A scan that kept running with its window gone would keep a hash cache open and eventually write a
    /// document nobody asked for.
    func windowWillClose(_ notification: Notification) {
        stopTimer()
        task?.cancel()
    }
}
