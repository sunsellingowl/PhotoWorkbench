import AppKit
import Combine

final class WorkbenchModel: ObservableObject {
    @Published var items: [PhotoItem] = []
    @Published var selection = Set<UUID>()
    @Published var busy = false
    @Published var scanning = false
    @Published var summary = "Drop images or folders to begin."
    @Published var notice: String?
    @Published var previewURL: URL?
    // 每个数组是一批成功的改名，撤销时按批次和批内顺序逆序执行。
    @Published var undoBatches: [[RenameChange]] = []
    @Published var style: NamingStyle {
        didSet { defaults.set(style.rawValue, forKey: "NamingStyle"); refreshPreviews() }
    }
    let defaults: UserDefaults
    private var jobs: [UUID: PWJob] = [:]
    private var compressor: PWCompression?
    private var activeIDs = Set<UUID>()
    private var flag = StopFlag()
    private var timer: Timer?
    private var done = 0, skipped = 0, failed = 0, total = 0
    var afterFinish: (() -> Void)?
    var canRestore: Bool { jobs.values.contains { $0.canRevert } }
    var selectedURLs: [URL] { items.filter { selection.contains($0.id) }.map(\.url) }

    static let defaultSettings: [String: Any] = [
        "LossyEnabled": false, "JpegOptimMaxQuality": 80, "PngMinQuality": 80,
        "AdvPngLevel": 2, "AdvPngEnabled": false, "JpegOptimEnabled": true, "JpegTranEnabled": true,
        "OptiPngEnabled": true, "PngOutEnabled": false, "ZopfliEnabled": false, "PngCrush2Enabled": false,
        "GuetzliEnabled": false, "JpegTranStripAll": false, "PngOutRemoveChunks": false,
        "PreserveDates": true, "PreservePermissions": true, "RunLowPriority": false,
        "GifsicleEnabled": false, "SvgoEnabled": false, "SvgcleanerEnabled": false
    ]
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: Self.defaultSettings)
        style = NamingStyle(rawValue: defaults.string(forKey: "NamingStyle") ?? "") ?? .timestamp
    }
    func addPanel() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = true
        panel.allowsMultipleSelection = true; panel.prompt = "Add"
        panel.begin { response in if response == .OK { self.add(panel.urls) } }
    }
    func add(_ urls: [URL]) {
        scanning = true
        let existing = Set(items.compactMap { PWFileIdentity($0.url) })
        DispatchQueue.global(qos: .userInitiated).async {
            let (loaded, errors) = PhotoCore.scan(urls, excluding: existing)
            DispatchQueue.main.async {
                var now = Set(self.items.compactMap { PWFileIdentity($0.url) })
                self.items.append(contentsOf: loaded.filter { item in
                    guard let identity = PWFileIdentity(item.url) else { return false }
                    return now.insert(identity).inserted
                })
                self.scanning = false; self.refreshPreviews()
                if !self.busy { self.summary = "\(self.items.count) images ready." }
                if !errors.isEmpty { self.notice = errors.prefix(12).joined(separator: "\n") }
            }
        }
    }
    func refreshPreviews() {
        let snapshot = items, naming = style
        DispatchQueue.global(qos: .userInitiated).async {
            let plans = PhotoCore.plan(snapshot, style: naming)
            DispatchQueue.main.async {
                guard self.style == naming else { return }
                for plan in plans {
                    if let index = self.items.firstIndex(where: { $0.id == plan.item.id && $0.url == plan.item.url }) {
                        self.items[index].preview = plan.target?.lastPathComponent ?? "Original name unavailable"
                    }
                }
            }
        }
    }
    private func update(_ item: PhotoItem) {
        if let index = items.firstIndex(where: { $0.id == item.id }) { items[index] = item }
        jobs[item.id]?.filePath = item.url
    }
    private func error(_ id: UUID, _ error: Error) {
        failed += 1
        if let index = items.firstIndex(where: { $0.id == id }) {
            items[index].status = "Failed"; items[index].detail = error.localizedDescription
        }
        progress()
    }
    private func progress() { summary = "\(done + skipped + failed)/\(total) · \(done) completed · \(skipped) skipped · \(failed) failed" }
    private func begin(_ snapshot: [PhotoItem]) {
        busy = true; flag = StopFlag(); done = 0; skipped = 0; failed = 0
        activeIDs = Set(snapshot.map(\.id)); total = snapshot.count
        for index in items.indices where activeIDs.contains(items[index].id) { items[index].status = "Waiting"; items[index].detail = "" }
        progress()
    }
    private func finish() {
        timer?.invalidate(); timer = nil; compressor = nil
        for index in items.indices where activeIDs.contains(items[index].id) && items[index].status == "Waiting" {
            items[index].status = "Stopped"; skipped += 1
        }
        busy = false; activeIDs = []; progress(); refreshPreviews()
        let callback = afterFinish; afterFinish = nil; callback?()
    }
    func stop() { flag.stop(); compressor?.stop(); summary = "Stopping safely…" }
    func rename() {
        guard !busy, !items.isEmpty else { return }
        let snapshot = items, naming = style
        begin(snapshot)
        let stop = flag
        DispatchQueue.global(qos: .userInitiated).async {
            var changes: [RenameChange] = []
            for plan in PhotoCore.plan(snapshot, style: naming) {
                if stop.stopped { break }
                do {
                    let item = try PhotoCore.rename(plan)
                    let changed = item.url != plan.item.url
                    if changed { changes.append(RenameChange(id: item.id, from: plan.item.url, to: item.url)) }
                    DispatchQueue.main.async {
                        self.update(item); if changed { self.done += 1 } else { self.skipped += 1 }; self.progress()
                    }
                } catch { DispatchQueue.main.async { self.error(plan.item.id, error) } }
            }
            let batch = changes
            DispatchQueue.main.async {
                if !batch.isEmpty { self.undoBatches.append(batch) }
                self.finish()
            }
        }
    }
    func undoRename() {
        guard !busy, let batch = undoBatches.last else { return }
        let ids = Set(batch.map(\.id)), snapshot = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        begin(items.filter { ids.contains($0.id) })
        let stop = flag
        DispatchQueue.global(qos: .userInitiated).async {
            var remaining = batch
            for change in batch.reversed() {
                if stop.stopped { break }
                // 移出列表时已经清理撤销记录；批次执行期间列表中的原有行不会被移除。
                let item = snapshot[change.id]!
                do {
                    let result = try PhotoCore.undo(change, item: item)
                    remaining.removeAll { $0.id == change.id }
                    DispatchQueue.main.async { self.update(result); self.done += 1; self.progress() }
                } catch { DispatchQueue.main.async { self.error(item.id, error) } }
            }
            let pending = remaining
            DispatchQueue.main.async {
                self.undoBatches.removeLast()
                if !pending.isEmpty { self.undoBatches.append(pending) }
                self.finish()
            }
        }
    }
    func compress() {
        guard !busy, !items.isEmpty else { return }
        let snapshot = items
        begin(snapshot)
        // 格式筛选和设置校验只在这里准备一次；收尾直接使用已准备的任务。
        var runnable: [(PhotoItem, PWJob)] = []
        for item in snapshot {
            guard compressionExtensions.contains(item.url.pathExtension.lowercased()) else {
                var copy = item; copy.status = "Skipped"; copy.detail = "This format supports renaming only."
                update(copy); skipped += 1; continue
            }
            // A fresh Job loses upstream repeat optimizations; retain it through this session.
            let job = jobs[item.id] ?? PWJob(url: item.url)
            job.filePath = item.url
            job.expectedUserSignature = item.signature
            jobs[item.id] = job
            do { try job.prepare(with: defaults); runnable.append((item, job)) }
            catch { self.error(item.id, error) }
        }
        progress()
        compressor = PWCompression()
        let batch = runnable
        timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in self?.pollCompression(batch) }
        compressor?.start(batch.map { $0.1 }, defaults: defaults) { [weak self] in
            guard let self else { return }
            self.pollCompression(batch, finished: true)
            self.finish()
        }
    }
    private func pollCompression(_ batch: [(PhotoItem, PWJob)], finished: Bool = false) {
        var updated = items, changed = false
        for (original, job) in batch where activeIDs.contains(original.id) {
            let index = updated.firstIndex { $0.id == original.id }!
            if !finished && (!job.wasStarted || job.isBusy()) {
                let status = job.wasStarted ? job.statusText ?? "Compressing…" : "Waiting"
                if updated[index].status != status { updated[index].status = status; changed = true }
                continue
            }
            var result = original
            if job.isFailed { result.status = "Failed"; result.detail = job.recoveryNote ?? job.statusText ?? "Compression failed."; failed += 1 }
            else if !job.wasStarted || !job.isDone { result.status = "Stopped"; result.detail = "No changes saved for this job."; skipped += 1 }
            else {
                result.status = job.savedInBatch ? "Compressed" : "Unchanged"
                result.detail = [job.statusText, job.validationNote].compactMap { $0 }.joined(separator: "\n")
                if job.savedInBatch { done += 1 } else { skipped += 1 }
            }
            if job.savedInBatch {
                // Use our committed snapshot; a later outside edit must still fail the next operation's check.
                result.signature = job.committedSignature ?? original.signature
                result.size = job.byteSizeOptimized.int64Value
            }
            if let percent = job.percentOptimized { result.savings = String(format: "%.1f%%", percent.doubleValue) }
            updated[index] = result; activeIDs.remove(original.id); changed = true
        }
        if changed { items = updated; progress() }
    }
    func restore() {
        guard !busy else { return }
        let snapshot = items, batchJobs = jobs
        begin(snapshot)
        let stop = flag
        DispatchQueue.global(qos: .userInitiated).async {
            for original in snapshot {
                if stop.stopped { break }
                guard let job = batchJobs[original.id], job.canRevert else {
                    DispatchQueue.main.async { var item = original; item.status = "Skipped"; item.detail = "No original available in this session."; self.update(item); self.skipped += 1; self.progress() }; continue
                }
                do {
                    try job.restore()
                    var item = original
                    let fresh = try signature(item.url)
                    guard fresh == job.committedSignature else { throw PhotoError("File changed after restoration.") }
                    item.signature = fresh; item.size = fileSize(item.url)
                    item.status = "Restored"; item.detail = "Original content restored; current name preserved."; item.savings = "—"
                    DispatchQueue.main.async { self.update(item); self.done += 1; self.progress() }
                } catch { DispatchQueue.main.async { self.error(original.id, error) } }
            }
            DispatchQueue.main.async { self.finish() }
        }
    }
    func remove(_ ids: Set<UUID>) {
        guard !busy else { return }
        items.removeAll { ids.contains($0.id) }; ids.forEach { jobs.removeValue(forKey: $0) }
        // Removed items cannot safely participate in later undo batches.
        undoBatches = undoBatches.map { $0.filter { !ids.contains($0.id) } }.filter { !$0.isEmpty }
        selection.subtract(ids); summary = "\(items.count) images ready."; refreshPreviews()
    }
    func reveal() { NSWorkspace.shared.activateFileViewerSelecting(selectedURLs) }
    func preview() { previewURL = selectedURLs.first ?? items.first?.url }
}
