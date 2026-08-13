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
    /// Called with the folder scan that was saved.
    var onFolderFinished: ((FolderScan) -> Void)?
    /// Called with the perceptual scan that was saved.
    var onSimilarFinished: ((SimilarScan) -> Void)?

    private let stateDirectory: StateDirectory
    private let session: ScanSession

    private var root: String?
    private var task: Task<Void, Never>?
    private var counters = ProgressCounters()
    private var timer: Timer?
    private var startedAt: ContinuousClock.Instant?

    private let rootLabel = NSTextField(labelWithString: "")
    private let chooseButton = NSButton()
    private let recentPopup = NSPopUpButton()
    private let recentRoots = RecentRootsStore()
    /// Which detector to run. Exact files, or similar folders.
    private let detectorPopup = NSPopUpButton()
    private let thresholdPopup = NSPopUpButton()
    private let folderSession: FolderScanSession
    private let similarSession: SimilarScanSession
    private let hiddenToggle = NSButton()
    private let videoToggle = NSButton()
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
        self.folderSession = FolderScanSession(store: ScanStore(state: stateDirectory))
        self.similarSession = SimilarScanSession(store: ScanStore(state: stateDirectory))
        self.optionsStack = NSStackView()
        self.progressStack = NSStackView()

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 320),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = Strings.string("scan.window.title")
        window.center()
        window.minSize = NSSize(width: 620, height: 300)
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

        detectorPopup.target = self
        detectorPopup.action = #selector(detectorChanged(_:))
        detectorPopup.addItem(withTitle: Strings.string("scan.detector.exact"))
        detectorPopup.addItem(withTitle: Strings.string("scan.detector.folders"))
        detectorPopup.addItem(withTitle: Strings.string("scan.detector.similar"))
        detectorPopup.selectItem(at: 0)

        rebuildThresholdMenu()
        thresholdPopup.isHidden = true

        // **On by default, like the CLI, and offered because video is the expensive half.** Measured on a real
        // tree: 2,779 images take 19 seconds and 617 videos take 93. Someone who wants a quick pass over a
        // photo folder should not pay for the movies sitting next to it.
        videoToggle.setButtonType(.switch)
        videoToggle.title = Strings.string("scan.includeVideo")
        videoToggle.state = .on
        videoToggle.isHidden = true

        // Recent roots, so a second scan of the same folder is a click rather than a walk through the open
        // panel. Hidden entirely when there are none, because an empty popup is worse than no popup.
        recentPopup.target = self
        recentPopup.action = #selector(recentChosen(_:))
        rebuildRecentMenu()

        // **Short titles with the reason underneath.** The first version put the whole reason in the title,
        // which produced labels like "Incluir archivos ocultos (el CLI lo hace; una carpeta de .DS_Store
        // idénticos entierra los hallazgos reales)" -- a doc comment pretending to be a checkbox, clipped
        // against the window edge. The reason still matters, so it stays; it just stops being the label.
        var optionRows: [NSView] = []
        for (button, titleKey, whyKey, on) in [
            (hiddenToggle, "scan.option.hidden", "scan.option.hidden.why", false),
            (packagesToggle, "scan.option.packages", "scan.option.packages.why", false),
            (cacheToggle, "scan.option.cache", "scan.option.cache.why", true),
        ] {
            button.setButtonType(.switch)
            button.title = Strings.string(titleKey)
            button.state = on ? .on : .off

            let why = NSTextField(wrappingLabelWithString: Strings.string(whyKey))
            why.font = .systemFont(ofSize: 11)
            why.textColor = .secondaryLabelColor
            why.translatesAutoresizingMaskIntoConstraints = false
            why.widthAnchor.constraint(equalToConstant: 540).isActive = true

            let row = NSStackView(views: [button, why])
            row.orientation = .vertical
            row.alignment = .leading
            row.spacing = 1
            // The reason is indented under its checkbox so it reads as belonging to it.
            row.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
            why.setContentHuggingPriority(.defaultLow, for: .horizontal)
            optionRows.append(row)
        }

        // **The CLI's default, unchanged.** Showing "1 KB" here was the first attempt and it was wrong:
        // it reads as copy but it is a behaviour change -- the scan-window selftest caught it, because a
        // 6-byte file stopped being counted. What the field needed was a unit that says units are accepted,
        // not a different threshold. A default worth changing is worth changing on purpose, in its own
        // change, with the README saying so.
        minimumSizeField.stringValue = "1 B"
        minimumSizeField.placeholderString = "1 B"
        minimumSizeField.alignment = .right
        minimumSizeField.widthAnchor.constraint(equalToConstant: 90).isActive = true
        let sizeHint = NSTextField(labelWithString: Strings.string("scan.option.minimumSize.hint"))
        sizeHint.font = .systemFont(ofSize: 11)
        sizeHint.textColor = .secondaryLabelColor
        let sizeRow = NSStackView(views: [
            NSTextField(labelWithString: Strings.string("scan.option.minimumSize")),
            minimumSizeField,
            sizeHint,
        ])
        sizeRow.orientation = .horizontal
        sizeRow.spacing = 8

        startButton.title = Strings.string("scan.start")
        startButton.bezelStyle = .rounded
        startButton.controlSize = .large
        startButton.keyEquivalent = "\r"
        startButton.target = self
        startButton.action = #selector(startScan(_:))
        startButton.isEnabled = false

        cancelButton.title = Strings.string("button.cancel")
        cancelButton.bezelStyle = .rounded
        cancelButton.controlSize = .large
        cancelButton.keyEquivalent = "\u{1b}"
        cancelButton.target = self
        cancelButton.action = #selector(cancelScan(_:))

        let rootRow = NSStackView(views: [recentPopup, chooseButton, rootLabel])
        rootRow.orientation = .horizontal
        rootRow.spacing = 8

        optionsStack.orientation = .vertical
        optionsStack.alignment = .leading
        optionsStack.spacing = 10
        let detectorRow = NSStackView(views: [
            NSTextField(labelWithString: Strings.string("scan.detector")), detectorPopup,
            thresholdPopup, videoToggle,
        ])
        detectorRow.orientation = .horizontal
        detectorRow.spacing = 8

        optionsStack.addArrangedSubview(detectorRow)
        optionsStack.addArrangedSubview(rootRow)
        for view in optionRows { optionsStack.addArrangedSubview(view) }
        optionsStack.addArrangedSubview(sizeRow)

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

        // Right-aligned, which is where a Mac user looks for the action of a sheet.
        let buttonSpacer = NSView()
        let buttons = NSStackView(views: [buttonSpacer, cancelButton, startButton])
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
            bar.widthAnchor.constraint(equalToConstant: 560),
            rootLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 330),
            pathLabel.widthAnchor.constraint(equalToConstant: 560),
            buttons.widthAnchor.constraint(equalTo: content.widthAnchor, constant: -40),
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

    /// Fills the recent-roots popup, or hides it when there is nothing to offer.
    ///
    /// Only folders that exist right now are listed: an unmounted external drive stays in the file so it
    /// comes back when the drive does, but offering it as scannable would be a click that fails.
    private func rebuildRecentMenu() {
        let roots = recentRoots.available()
        recentPopup.isHidden = roots.isEmpty
        recentPopup.removeAllItems()
        guard !roots.isEmpty else { return }
        recentPopup.addItem(withTitle: Strings.string("scan.recent.placeholder"))
        for root in roots {
            // Elided in the middle: the head says which volume and the tail says which folder.
            let item = NSMenuItem(
                title: PathElision.elide(root.path, leading: 2, trailing: 2),
                action: nil, keyEquivalent: ""
            )
            item.toolTip = root.path
            item.representedObject = root.path
            recentPopup.menu?.addItem(item)
        }
        recentPopup.selectItem(at: 0)
    }

    @objc private func recentChosen(_ sender: NSPopUpButton) {
        guard let path = sender.selectedItem?.representedObject as? String else { return }
        setRoot(path)
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

    /// Which detector the popup is on.
    private enum Detector: Int {
        case exact = 0
        case folders = 1
        case similar = 2
    }

    private var detector: Detector {
        Detector(rawValue: detectorPopup.indexOfSelectedItem) ?? .exact
    }

    @objc private func detectorChanged(_ sender: Any?) {
        // **Each detector's threshold is a different quantity in a different unit**: folders are a Dice
        // coefficient in percent, images are a Hamming distance in bits out of 64. One popup showing "90%"
        // for both would be two meanings behind one number, so the items are rebuilt with the detector.
        rebuildThresholdMenu()
        thresholdPopup.isHidden = detector == .exact
        videoToggle.isHidden = detector != .similar
    }

    private func rebuildThresholdMenu() {
        thresholdPopup.removeAllItems()
        switch detector {
        case .exact, .folders:
            for value in [0.95, 0.9, 0.8, 0.7] {
                thresholdPopup.addItem(
                    withTitle: String(
                        format: Strings.string("scan.threshold.value"), Int(value * 100)))
                thresholdPopup.lastItem?.representedObject = value
            }
            thresholdPopup.selectItem(at: 1)
        case .similar:
            // The CLI's default is 5 bits of 64, which its own comment calls about 92% similarity.
            for value in [0, 2, 5, 10] {
                thresholdPopup.addItem(
                    withTitle: String(format: Strings.string("scan.threshold.bits"), value))
                thresholdPopup.lastItem?.representedObject = value
            }
            thresholdPopup.selectItem(at: 2)
        }
    }

    private var isFolderScan: Bool { detector == .folders }

    private var threshold: Double {
        (thresholdPopup.selectedItem?.representedObject as? Double) ?? 0.9
    }

    private var imageThreshold: Int {
        (thresholdPopup.selectedItem?.representedObject as? Int) ?? 5
    }

    @objc private func startScan(_ sender: Any?) {
        guard let request else { return }
        // Remembered here rather than on success: a scan the user started is one they meant to start, and a
        // cancelled scan of the right folder should still put it at the top of the list.
        recentRoots.remember(request.root, at: ScanIdentifier.timestamp(from: Date()))

        counters = ProgressCounters()
        startedAt = ContinuousClock.now
        showProgress()
        bar.startAnimation(nil)
        startTimer()

        let counters = self.counters
        if detector == .similar {
            let similarSession = self.similarSession
            let similarRequest = SimilarScanSession.Request(
                root: request.root, imageThreshold: imageThreshold, policy: request.policy,
                includesVideo: videoToggle.state == .on)
            task = Task { [weak self] in
                let outcome: Result<SimilarScanSession.Result, any Error>
                do {
                    outcome = .success(
                        try await similarSession.run(similarRequest, at: Date(), progress: counters)
                    )
                } catch {
                    outcome = .failure(error)
                }
                await MainActor.run { [weak self] in
                    self?.finishSimilar(outcome)
                }
            }
        } else if isFolderScan {
            let folderSession = self.folderSession
            let folderRequest = FolderScanSession.Request(
                root: request.root, threshold: threshold, policy: request.policy,
                usesCache: request.usesCache
            )
            task = Task { [weak self] in
                let outcome: Result<FolderScanSession.Result, any Error>
                do {
                    outcome = .success(
                        try await folderSession.run(folderRequest, at: Date(), progress: counters))
                } catch {
                    outcome = .failure(error)
                }
                await MainActor.run { [weak self] in
                    self?.finishFolder(outcome)
                }
            }
        } else {
            let session = self.session
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
    }

    /// The perceptual detector's completion.
    ///
    /// **It says what it did not look at.** This build hashes images and no video, so a scan of a tree full of
    /// `.mp4` files finds nothing and would otherwise look like "there is nothing here". The sheet names the
    /// number of images it read instead.
    private func finishSimilar(_ outcome: Result<SimilarScanSession.Result, any Error>) {
        stopTimer()
        bar.stopAnimation(nil)
        task = nil

        switch outcome {
        case .failure(is CancellationError):
            window?.close()
        case .failure(let error):
            presentFailure(String(describing: error))
        case .success(let result):
            if let failure = result.saveFailure {
                presentFailure(failure)
                return
            }
            if !result.unreadable.isEmpty {
                let alert = NSAlert()
                alert.alertStyle = .informational
                alert.messageText = Strings.string("scan.unreadableImages.title")
                alert.informativeText = String(
                    format: Strings.string("scan.unreadableImages.body"),
                    result.unreadable.count, result.hashedCount)
                alert.addButton(withTitle: Strings.string("button.ok"))
                alert.runModal()
            }
            onSimilarFinished?(result.scan)
            window?.close()
        }
    }

    /// The folder detector's completion. Same shape as the exact one, different result type.
    private func finishFolder(_ outcome: Result<FolderScanSession.Result, any Error>) {
        stopTimer()
        bar.stopAnimation(nil)
        task = nil

        switch outcome {
        case .failure(is CancellationError):
            window?.close()
        case .failure(let error):
            presentFailure(String(describing: error))
        case .success(let result):
            if let failure = result.saveFailure {
                presentFailure(failure)
                return
            }
            // A truncated class means the answer is incomplete, and saying so is the whole point of
            // tracking it rather than returning quietly wrong results.
            if let worst = result.truncated.max(by: { $0.fileCount < $1.fileCount }) {
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = Strings.string("scan.truncated.title")
                alert.informativeText = String(
                    format: Strings.string("scan.truncated.body"), worst.fileCount, worst.basename)
                alert.addButton(withTitle: Strings.string("button.ok"))
                alert.runModal()
            }
            onFolderFinished?(result.scan)
            window?.close()
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

    /// The smallest size this window's constraints allow. See the review window for why this is asserted.
    var requiredContentSize: NSSize {
        window?.contentView?.layoutSubtreeIfNeeded()
        return window?.contentView?.fittingSize ?? .zero
    }

    func setRootForSelftest(_ path: String) { setRoot(path) }
    func startForSelftest() { startScan(nil) }
    func cancelForSelftest() { cancelScan(nil) }
    func refreshProgressForSelftest() { refreshProgress() }
    func requestForSelftest() -> ScanSession.Request? { request }
    var isFolderScanForSelftest: Bool { isFolderScan }
    var thresholdForSelftest: Double { threshold }
    var imageThresholdForSelftest: Int { imageThreshold }
    var includesVideoForSelftest: Bool { videoToggle.state == .on }
    var isVideoToggleVisibleForSelftest: Bool { !videoToggle.isHidden }

    func setIncludesVideoForSelftest(_ on: Bool) {
        videoToggle.state = on ? .on : .off
    }

    func chooseSimilarDetectorForSelftest() {
        detectorPopup.selectItem(at: 2)
        detectorChanged(nil)
    }

    func chooseFolderDetectorForSelftest() {
        detectorPopup.selectItem(at: 1)
        detectorChanged(nil)
    }

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
