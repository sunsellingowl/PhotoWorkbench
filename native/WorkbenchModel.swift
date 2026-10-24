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
    @Published var undoBatches: [RenameBatch] = []
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
        "AdvPngLevel": 4, "AdvPngEnabled": true, "JpegOptimEnabled": true, "JpegTranEnabled": true,
        "OptiPngEnabled": true, "PngOutEnabled": true, "ZopfliEnabled": true, "PngCrush2Enabled": false,
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
    private func begin(ids: Set<UUID>? = nil) -> [PhotoItem] {
        busy = true; flag = StopFlag(); done = 0; skipped = 0; failed = 0; total = items.count
        let snapshot = items.filter { ids == nil || ids!.contains($0.id) }; activeIDs = Set(snapshot.map(\.id)); total = snapshot.count
        for index in items.indices where activeIDs.contains(items[index].id) { items[index].status = "Waiting"; items[index].detail = "" }
        progress(); return snapshot
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
        let snapshot = begin(), naming = style, stop = flag
        DispatchQueue.global(qos: .userInitiated).async {
            var changes: [RenameChange] = []
            for plan in PhotoCore.plan(snapshot, style: naming) {
                if stop.stopped { break }
                if plan.target == nil {
                    DispatchQueue.main.async {
                        var item = plan.item; item.status = "Skipped"; item.detail = plan.reason ?? ""
                        self.update(item); self.skipped += 1; self.progress()
                    }; continue
                }
                do {
                    let item = try PhotoCore.rename(plan)
                    let changed = item.url != plan.item.url
                    if changed { changes.append(RenameChange(id: item.id, from: plan.item.url, to: item.url)) }
                    DispatchQueue.main.async {
                        self.update(item); if changed { self.done += 1 } else { self.skipped += 1 }; self.progress()
                    }
                } catch { DispatchQueue.main.async { self.error(plan.item.id, error) } }
            }
            let batch = RenameBatch(changes: changes)
            DispatchQueue.main.async {
                if !batch.changes.isEmpty { self.undoBatches.append(batch) }
                self.finish()
            }
        }
    }
    func undoRename() {
        guard !busy, let batch = undoBatches.last else { return }
        let snapshot = begin(ids: Set(batch.changes.map(\.id))), stop = flag; total = batch.changes.count
        DispatchQueue.global(qos: .userInitiated).async {
            var remaining = batch.changes
            for change in batch.changes.reversed() {
                if stop.stopped { break }
                guard let item = snapshot.first(where: { $0.id == change.id }) else {
                    DispatchQueue.main.async { self.error(change.id, PhotoError("File was removed from the list.")) }; continue
                }
                do {
                    let result = try PhotoCore.undo(change, item: item)
                    remaining.removeAll { $0.id == change.id }
                    DispatchQueue.main.async { self.update(result); self.done += 1; self.progress() }
                } catch { DispatchQueue.main.async { self.error(item.id, error) } }
            }
            let pending = remaining
            DispatchQueue.main.async {
                self.undoBatches.removeLast()
                if !pending.isEmpty { self.undoBatches.append(RenameBatch(changes: pending)) }
                self.activeIDs = Set(batch.changes.map(\.id)); self.finish()
            }
        }
    }
    func compress() {
        guard !busy, !items.isEmpty else { return }
        if defaults.bool(forKey: "GuetzliEnabled") && defaults.bool(forKey: "LossyEnabled") &&
            (!defaults.bool(forKey: "JpegTranStripAll") || defaults.integer(forKey: "JpegOptimMaxQuality") < 85) {
            notice = "Guetzli requires JPEG metadata removal and JPEG quality of at least 85. Change these settings explicitly, or turn Guetzli off."; return
        }
        let snapshot = begin()
        var runnable: [PWJob] = []
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
            do { try job.prepare(with: defaults); runnable.append(job) }
            catch { self.error(item.id, error) }
        }
        progress()
        compressor = PWCompression()
        timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in self?.pollCompression() }
        compressor?.start(runnable, defaults: defaults) { [weak self] in
            guard let self else { return }
            self.pollCompression()
            self.finalizeCompression(snapshot: snapshot)
        }
    }
    private func pollCompression() {
        for index in items.indices where activeIDs.contains(items[index].id) && items[index].status != "Skipped" && items[index].status != "Failed" {
            guard let job = jobs[items[index].id] else { continue }
            if job.isBusy() { items[index].status = job.statusText ?? "Compressing…" }
        }
    }
    private func finalizeCompression(snapshot: [PhotoItem]) {
        // Hashing large batches belongs off the UI thread, including post-save identity refresh.
        let batchJobs = jobs
        DispatchQueue.global(qos: .userInitiated).async {
            var results: [(PhotoItem, Bool)] = []
            for original in snapshot {
                guard let job = batchJobs[original.id], compressionExtensions.contains(original.url.pathExtension.lowercased()) else { continue }
                var result = original
                let wasSaved = job.savedInBatch
                if job.isFailed { result.status = "Failed"; result.detail = job.recoveryNote ?? job.statusText ?? "Compression failed." }
                else if !job.wasStarted || !job.isDone { result.status = "Stopped"; result.detail = "No changes saved for this job." }
                else {
                    result.status = wasSaved ? "Compressed" : "Unchanged"
                    result.detail = [job.statusText, job.validationNote].compactMap { $0 }.joined(separator: "\n")
                }
                if let fresh = try? signature(result.url) {
                    // Accept only our own completed save. External edits must remain detectable by Undo.
                    if wasSaved && fresh == job.committedSignature { result.signature = fresh }
                    result.size = fileSize(result.url)
                }
                if let percent = job.savingsPercent { result.savings = String(format: "%.1f%%", percent.doubleValue) }
                results.append((result, wasSaved))
            }
            DispatchQueue.main.async {
                for (result, saved) in results {
                    guard let current = self.items.first(where: { $0.id == result.id }), current.status != "Failed", current.status != "Skipped" else { continue }
                    self.update(result)
                    if result.status == "Failed" { self.failed += 1 }
                    else if saved && result.status == "Compressed" { self.done += 1 } else { self.skipped += 1 }
                }
                self.finish()
            }
        }
    }
    func restore() {
        guard !busy else { return }
        let snapshot = begin(), batchJobs = jobs, stop = flag
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
        undoBatches = undoBatches.map { RenameBatch(changes: $0.changes.filter { !ids.contains($0.id) }) }.filter { !$0.changes.isEmpty }
        selection.subtract(ids); summary = "\(items.count) images ready."; refreshPreviews()
    }
    func reveal() { NSWorkspace.shared.activateFileViewerSelecting(selectedURLs) }
    func preview() { previewURL = selectedURLs.first ?? items.first?.url }
}
