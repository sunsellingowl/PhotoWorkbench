import Foundation
import AppKit

@main
struct NativeChecks {
    static var count = 0
    static var preferenceDomains: [String] = []
    static func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !condition() { throw PhotoError("CHECK FAILED: \(message)") }; count += 1
    }
    static func spin(until predicate: () -> Bool, timeout: TimeInterval = 90) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !predicate() && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
        try check(predicate(), "operation completed before timeout")
    }
    static func validate(_ a: URL, _ b: URL, lossless: Bool = true, keep: Bool = true) throws -> Bool {
        var error: NSError?
        return PWValidateImage(try Data(contentsOf: a), try Data(contentsOf: b), lossless, keep, &error)
    }
    static func settings() -> UserDefaults {
        let domain = "local.cc.PhotoWorkbench.tests.\(UUID().uuidString)"
        preferenceDomains.append(domain)
        let d = UserDefaults(suiteName: domain)!
        d.register(defaults: WorkbenchModel.defaultSettings)
        // Low effort keeps tests short; production defaults remain at 4.
        d.set(0, forKey: "AdvPngLevel")
        return d
    }
    static func run(_ jobs: [PWJob], defaults: UserDefaults, stop: Bool = false) throws {
        for job in jobs { try job.prepare(with: defaults) }
        let backend = PWCompression(); var finished = false
        backend.start(jobs, defaults: defaults) { finished = true }
        if stop { backend.stop() }
        try spin(until: { finished })
    }
    static func main() {
        do { try execute() } catch { fputs("\(error.localizedDescription)\n", stderr); exit(1) }
    }
    static func expectFailure(_ message: String, _ work: () throws -> Void) throws {
        var rejected = false
        do { try work() } catch { rejected = true }
        try check(rejected, message)
    }
    static func execute() throws {
        defer { for domain in preferenceDomains { UserDefaults.standard.removePersistentDomain(forName: domain) } }
        let fm = FileManager.default
        let fixtures = URL(fileURLWithPath: CommandLine.arguments[1])
        let baseline = URL(fileURLWithPath: CommandLine.arguments[2])
        var comparisons: [[String: Any]] = []
        let root = fm.temporaryDirectory.appendingPathComponent("PhotoWorkbench-tests-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: root) }
        let creationFormatter = DateFormatter()
        creationFormatter.locale = Locale(identifier: "en_US_POSIX")
        creationFormatter.calendar = Calendar(identifier: .gregorian)
        creationFormatter.timeZone = .current
        creationFormatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        let creation = creationFormatter.date(from: "2020:01:02 03:04:05")!
        func copy(_ name: String, _ to: String? = nil) throws -> URL {
            let destination = root.appendingPathComponent(to ?? UUID().uuidString + "-" + name)
            try fm.copyItem(at: fixtures.appendingPathComponent(name), to: destination)
            try fm.setAttributes([.creationDate: creation, .modificationDate: Date(timeIntervalSince1970: 1700000000)], ofItemAtPath: destination.path)
            return destination
        }
        print("Checking native metadata, renaming, collisions and undo…")
        let jpeg = try copy("capture.JPG", "中文 image.JPG")
        let item = try PhotoCore.load(jpeg)
        try check(item.timestamp == "200102030405", "file creation time is used")
        let digitized = try PhotoCore.timestamp(copy("digitized.jpg"))
        let dated = try PhotoCore.timestamp(copy("dated.jpg"))
        try check(digitized.0 == "200102030405", "EXIF digitized time does not override creation time")
        try check(dated.0 == "200102030405", "TIFF date does not override creation time")
        let fallback = try PhotoCore.load(copy("fallback.webp"))
        try check(fallback.timeSource.contains("creation") && fallback.timestamp == "200102030405", "creation time is used even without EXIF")
        try fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1800000000)], ofItemAtPath: fallback.url.path)
        let afterModification = try PhotoCore.timestamp(fallback.url)
        try check(afterModification.0 == fallback.timestamp, "later modification does not change naming time")
        try expectFailure("missing file does not silently use a made-up date") { _ = try PhotoCore.timestamp(root.appendingPathComponent("missing.jpg")) }
        let bytes = try Data(contentsOf: jpeg), initialSignature = item.signature
        let collision = root.appendingPathComponent("200102030405.JPG"); try bytes.write(to: collision)
        let first = PhotoCore.plan([item], style: .timestamp)[0]
        try check(first.target?.lastPathComponent == "200102030405_001.JPG", "collision suffix and extension case")
        let renamed = try PhotoCore.rename(first)
        let renamedBytes = try Data(contentsOf: renamed.url)
        try check(renamedBytes == bytes && renamed.signature == initialSignature, "rename preserves contents, identity and modification date")
        let repeatPlan = PhotoCore.plan([renamed], style: .timestamp)[0]
        try check(repeatPlan.target == renamed.url, "repeat rename is idempotent")
        let second = PhotoCore.plan([renamed], style: .originalAndTimestamp)[0]
        let switched = try PhotoCore.rename(second)
        try check(switched.url.lastPathComponent == "中文 image_200102030405.JPG", "format switching remembers original")
        let undoSecond = try PhotoCore.undo(RenameChange(id: item.id, from: renamed.url, to: switched.url), item: switched)
        let undone = try PhotoCore.undo(RenameChange(id: item.id, from: jpeg, to: renamed.url), item: undoSecond)
        try check(undone.url == jpeg, "multi-batch reverse order undo")
        let legacy = try PhotoCore.load(copy("capture.JPG", "2001020304.JPG"))
        try check(legacy.originalBase == nil, "old minute-only name recognized")
        try check(PhotoCore.plan([legacy], style: .originalAndTimestamp)[0].target == nil, "lost original name is skipped")
        let originalLegacy = try PhotoCore.load(copy("capture.JPG", "Camera_2001020304_001.JPG"))
        try check(originalLegacy.originalBase == "Camera", "old suffix removed without duplication")
        let oldPlan = PhotoCore.plan([originalLegacy], style: .originalAndTimestamp)[0]
        try check(oldPlan.target?.lastPathComponent == "Camera_200102030405.JPG", "old suffix upgraded to seconds")
        let conflict = try PhotoCore.rename(oldPlan)
        try bytes.write(to: originalLegacy.url)
        try expectFailure("undo conflict is rejected") { _ = try PhotoCore.undo(RenameChange(id: conflict.id, from: originalLegacy.url, to: conflict.url), item: conflict) }
        try check(fm.fileExists(atPath: conflict.url.path), "undo conflict retains current file")
        let externallyEdited = try PhotoCore.load(copy("plain.jpg"))
        var changedBytes = try Data(contentsOf: externallyEdited.url); changedBytes.append(0)
        try changedBytes.write(to: externallyEdited.url)
        try expectFailure("external edit is rejected") { _ = try PhotoCore.rename(PhotoCore.plan([externallyEdited], style: .timestamp)[0]) }
        try check(fm.fileExists(atPath: externallyEdited.url.path), "external edit retains file")
        try fm.createSymbolicLink(at: root.appendingPathComponent("link.jpg"), withDestinationURL: jpeg)
        _ = try copy("capture.JPG", ".hidden.jpg")
        let scan = PhotoCore.scan([root, jpeg], excluding: [])
        try check(scan.0.filter { PWFileIdentity($0.url) == PWFileIdentity(jpeg) }.count == 1, "deduplicated repeated inputs: \(scan.0.map { $0.url.path }) \(scan.1)")
        try check(!scan.0.contains { $0.url.lastPathComponent == "link.jpg" || $0.url.lastPathComponent == ".hidden.jpg" }, "hidden and symlink skipped")

        print("Checking strict PNG precision, hidden RGB and protected metadata…")
        for depth in [8, 16] {
            let png = fixtures.appendingPathComponent("rgba\(depth).png")
            let changed = fixtures.appendingPathComponent("rgba\(depth)-changed.png")
            let stripped = fixtures.appendingPathComponent("rgba\(depth)-stripped.png")
            let identity = try validate(png, png)
            let pixelChange = try validate(png, changed)
            let lossyAllowed = try validate(png, changed, lossless: false)
            let metadataChange = try validate(png, stripped)
            let strippingAllowed = try validate(png, stripped, keep: false)
            try check(identity, "\(depth)-bit PNG self validation")
            try check(!pixelChange, "\(depth)-bit hidden RGB change rejected")
            try check(lossyAllowed, "explicit lossy mode allows pixel change")
            try check(!metadataChange, "EXIF and ICC stripping rejected")
            try check(strippingAllowed, "explicit metadata removal allows stripped result")
        }
        try check(!(try validate(fixtures.appendingPathComponent("animated.png"), fixtures.appendingPathComponent("animated.png"))), "APNG is safely rejected")
        for name in ["oversized.jpg", "oversized.png"] {
            let oversized = fixtures.appendingPathComponent(name)
            try check(!(try validate(oversized, oversized)), "oversized declared dimensions are rejected before pixel allocation")
        }
        print("Checking bundled engines, original preservation and restore…")
        let defaults = settings()
        for name in ["rgba8.png", "rgba16.png", "capture.JPG"] {
            let url = try copy(name)
            let original = try Data(contentsOf: url)
            var renamedItem = try PhotoCore.load(url)
            let plan = PhotoCore.plan([renamedItem], style: .timestamp)[0]
            renamedItem = try PhotoCore.rename(plan)
            let job = PWJob(url: renamedItem.url); job.expectedUserSignature = renamedItem.signature
            try run([job], defaults: defaults)
            try check(!job.isFailed, "compression successful: \(name), \(job.statusText ?? "") \(job.recoveryNote ?? "")")
            let output = try Data(contentsOf: renamedItem.url)
            var err: NSError?
            try check(PWValidateImage(original, output, true, true, &err), "compressed pixels and metadata preserved: \(name)")
            try check(output.count <= original.count, "no larger output")
            let baselineData = try Data(contentsOf: baseline.appendingPathComponent(name))
            let baselineStrict = PWValidateImage(original, baselineData, true, true, &err)
            comparisons.append(["file":name,"originalBytes":original.count,"nativeBytes":output.count,"upstreamBytes":baselineData.count,"upstreamPassesStrictValidation":baselineStrict,"upstreamPreservesPixels":PWValidateImage(original,baselineData,true,false,&err),"upstreamPreservesMetadata":PWValidateImage(original,baselineData,false,true,&err)])
            if name.hasSuffix("JPG") { try check(output.count == baselineData.count && baselineStrict, "JPEG matches upstream baseline at the same settings") }
            if name.hasSuffix("png") { try check(output.count < original.count && job.canRevert, "PNG compression saved a smaller result and retained original") }
            renamedItem.signature = try signature(renamedItem.url)
            let next = PhotoCore.plan([renamedItem], style: .originalAndTimestamp)[0]
            let after = try PhotoCore.rename(next); job.filePath = after.url
            if job.canRevert {
                try job.restore()
                let restored = try Data(contentsOf: after.url)
                try check(restored == original, "restore preserves current name and original contents")
                var restoredItem = after; restoredItem.signature = try signature(after.url)
                let back = try PhotoCore.undo(RenameChange(id: after.id, from: renamedItem.url, to: after.url), item: restoredItem)
                try check(back.url == renamedItem.url, "undo after compression and restore")
            }
        }
        let report = try JSONSerialization.data(withJSONObject: comparisons, options: [.prettyPrinted, .sortedKeys])
        try report.write(to: fixtures.deletingLastPathComponent().appendingPathComponent("comparison.json"))
        print(String(data: report, encoding: .utf8)!)
        let corrupt = PWJob(url: try copy("corrupt.png")); try run([corrupt], defaults: defaults)
        try check(corrupt.isFailed, "corrupt input reported as failed")
        let stopped = (0..<6).map { _ in PWJob(url: try! copy("rgba8.png")) }
        let beforeStop = try stopped.map { try Data(contentsOf: $0.filePath) }
        try run(stopped, defaults: defaults, stop: true)
        for (i, job) in stopped.enumerated() {
            let data = try Data(contentsOf: job.filePath)
            var err: NSError?
            try check(PWValidateImage(beforeStop[i],data,true,true,&err), "Stop retains valid image")
        }
        print("Checking failure recovery, lossy opt-in and full-list batch behavior…")
        let readonly = try copy("rgba8.png")
        try fm.setAttributes([.posixPermissions: 0o444], ofItemAtPath: readonly.path)
        let readJob = PWJob(url: readonly); let readData = try Data(contentsOf: readonly)
        try run([readJob], defaults: defaults)
        try check(readJob.isFailed && (try Data(contentsOf: readonly)) == readData, "read-only input stays intact")
        try fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: readonly.path)
        let failedURL = try copy("rgba8.png"), failedData = try Data(contentsOf: failedURL)
        let failingJob = PWFailingTrashJob(url: failedURL)
        try run([failingJob], defaults: defaults)
        try check(failingJob.isFailed && (try Data(contentsOf: failedURL)) == failedData, "Trash failure rolls back replacement")
        let crash = PWJob(url: try copy("plain.jpg")); PWProbeEngineFailure(crash)
        try check(crash.isFailed, "engine nonzero exit is surfaced")
        let disabled = settings()
        for key in ["OptiPngEnabled", "PngOutEnabled", "ZopfliEnabled", "AdvPngEnabled", "PngCrush2Enabled"] { disabled.set(false, forKey: key) }
        let noEngine = PWJob(url: try copy("rgba8.png")); try run([noEngine], defaults: disabled)
        try check(noEngine.isFailed, "all engines disabled is a clear failure")
        let missingOriginal = PWJob(url: try copy("rgba8.png")); try run([missingOriginal], defaults: defaults)
        try check(missingOriginal.canRevert, "restore source exists before deletion test")
        let backup = missingOriginal.value(forKey: "restoreURL") as! URL
        try fm.removeItem(at: backup) // Only this generated fixture's exact returned Trash URL.
        let kept = try Data(contentsOf: missingOriginal.filePath)
        try expectFailure("missing Trash original blocks restore") { try missingOriginal.restore() }
        try check((try Data(contentsOf: missingOriginal.filePath)) == kept, "failed restore leaves current file intact")
        let externalRestore = PWJob(url: try copy("rgba8.png")); try run([externalRestore], defaults: defaults)
        let external = try Data(contentsOf: fixtures.appendingPathComponent("rgba16.png"))
        try external.write(to: externalRestore.filePath)
        try expectFailure("external content change blocks restore") { try externalRestore.restore() }
        try check((try Data(contentsOf: externalRestore.filePath)) == external, "external replacement is not overwritten")
        let lossy = settings(); lossy.set(true, forKey: "LossyEnabled"); lossy.set(true, forKey: "JpegTranStripAll")
        lossy.set(60, forKey: "JpegOptimMaxQuality")
        let lossyURL = try copy("plain.jpg"), lossyOriginal = try Data(contentsOf: lossyURL)
        let lossyJob = PWJob(url: lossyURL); try run([lossyJob], defaults: lossy)
        try check(!lossyJob.isFailed && lossyJob.hasSavedOutput, "explicit lossy JPEG mode saves smaller output")
        let lossyData = try Data(contentsOf: lossyURL); var error: NSError?
        try check(PWValidateImage(lossyOriginal, lossyData, false, false, &error), "lossy output still decodes correctly")
        try check(!PWValidateImage(lossyOriginal, lossyData, true, false, &error), "lossy quality changes require explicit opt-in")
        lossy.set(true, forKey: "GuetzliEnabled"); lossy.set(false, forKey: "JpegTranStripAll")
        try expectFailure("Guetzli settings conflict does not silently strip metadata") { try PWJob(url: lossyURL).prepare(with: lossy) }
        let pngEngineKeys = ["OptiPngEnabled", "PngOutEnabled", "ZopfliEnabled", "AdvPngEnabled", "PngCrush2Enabled"]
        for enabled in pngEngineKeys {
            let isolated = settings(); isolated.set(true, forKey: "PngOutRemoveChunks")
            for key in pngEngineKeys { isolated.set(key == enabled, forKey: key) }
            // PNGOUT is intentionally bypassed by upstream when effort < 4 and Zopfli is enabled.
            let engineURL = try copy("rgba8.png"), engineOriginal = try Data(contentsOf: engineURL)
            let engineJob = PWJob(url: engineURL); try run([engineJob], defaults: isolated)
            let engineData = try Data(contentsOf: engineURL)
            try check(!engineJob.isFailed, "bundled engine works: \(enabled): \(engineJob.statusText ?? "")")
            try check(PWValidateImage(engineOriginal, engineData, true, false, &error), "engine respects pixel validation: \(enabled)")
        }
        let pngLossy = settings(); pngLossy.set(true, forKey: "LossyEnabled"); pngLossy.set(true, forKey: "PngOutRemoveChunks"); pngLossy.set(40, forKey: "PngMinQuality")
        for key in pngEngineKeys { pngLossy.set(false, forKey: key) }
        let pngLossyURL = try copy("rgba8.png"), pngLossyOriginal = try Data(contentsOf: pngLossyURL)
        let quant = PWJob(url: pngLossyURL); try run([quant], defaults: pngLossy)
        let quantData = try Data(contentsOf: pngLossyURL)
        try check(!quant.isFailed && PWValidateImage(pngLossyOriginal, quantData, false, false, &error), "pngquant lossy mode produces a valid image")
        let repeatURL = try copy("plain.jpg"), repeatOriginal = try Data(contentsOf: repeatURL)
        let repeatJob = PWJob(url: repeatURL); try run([repeatJob], defaults: defaults)
        let firstSize = fileSize(repeatURL)
        let changedSettings = settings(); changedSettings.set(true, forKey: "LossyEnabled"); changedSettings.set(true, forKey: "JpegTranStripAll"); changedSettings.set(50, forKey: "JpegOptimMaxQuality")
        repeatJob.expectedUserSignature = try signature(repeatURL)
        try run([repeatJob], defaults: changedSettings)
        try check(!repeatJob.isFailed && fileSize(repeatURL) < firstSize, "settings changes invalidate per-worker skip state")
        try repeatJob.restore()
        try check((try Data(contentsOf: repeatURL)) == repeatOriginal, "repeated compression retains the earliest original")
        let disguisedURL = try copy("rgba8.png", "mislabelled.jpg")
        let disguisedData = try Data(contentsOf: disguisedURL)
        let disguised = PWJob(url: disguisedURL), mixedSettings = settings()
        mixedSettings.set(true, forKey: "JpegTranStripAll")
        try run([disguised], defaults: mixedSettings)
        try check(PWValidateImage(disguisedData, try Data(contentsOf: disguisedURL), true, true, &error), "metadata policy follows actual file format")
        let guetzliSettings = settings(); guetzliSettings.set(true, forKey: "LossyEnabled"); guetzliSettings.set(true, forKey: "JpegTranStripAll"); guetzliSettings.set(85, forKey: "JpegOptimMaxQuality"); guetzliSettings.set(true, forKey: "GuetzliEnabled")
        guetzliSettings.set(false, forKey: "JpegOptimEnabled"); guetzliSettings.set(false, forKey: "JpegTranEnabled")
        let guetzliURL = try copy("plain.jpg"), guetzliOriginal = try Data(contentsOf: guetzliURL)
        let guetzli = PWJob(url: guetzliURL); try run([guetzli], defaults: guetzliSettings)
        try check(!guetzli.isFailed, "Guetzli runs with explicit compatible settings")
        try check(PWValidateImage(guetzliOriginal, try Data(contentsOf: guetzliURL), false, false, &error), "Guetzli output remains a valid same-size image")
        let batchFolder = root.appendingPathComponent("batch", isDirectory: true)
        try fm.createDirectory(at: batchFolder, withIntermediateDirectories: false)
        for n in 0..<300 { try fm.copyItem(at: fixtures.appendingPathComponent("fallback.webp"), to: batchFolder.appendingPathComponent("Photo_\(n).webp")) }
        let model = WorkbenchModel(defaults: settings())
        model.add([batchFolder]); try spin(until: { !model.scanning })
        try check(model.items.count == 300 && model.items.allSatisfy { $0.status == "Ready" }, "adding 300 images does not mutate them")
        model.selection = [model.items[0].id]
        var heartbeat = 0
        let timer = Timer.scheduledTimer(withTimeInterval: 0.01, repeats: true) { _ in heartbeat += 1 }
        model.rename(); try spin(until: { !model.busy })
        timer.invalidate()
        try check(model.items.allSatisfy { $0.status == "Renamed" } && heartbeat > 0, "300-image full-list rename keeps main run loop responsive")
        model.undoRename(); try spin(until: { !model.busy })
        try check(model.items.allSatisfy { $0.url.lastPathComponent.hasPrefix("Photo_") }, "batch undo restores every name")
        model.compress(); try spin(until: { !model.busy })
        try check(model.summary.contains("300 skipped"), "unsupported compression formats are counted as skipped")
        print("Native checks passed: \(count)")
    }
}
