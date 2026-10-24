import Foundation

let supportedExtensions: Set<String> = ["jpg", "jpeg", "png", "heic", "heif", "webp"]
let compressionExtensions: Set<String> = ["jpg", "jpeg", "png"]

enum NamingStyle: String, CaseIterable, Identifiable {
    case timestamp, originalAndTimestamp
    var id: String { rawValue }
    var title: String { self == .timestamp ? "Timestamp" : "Original + timestamp" }
}
struct PhotoItem: Identifiable {
    let id: UUID
    var url: URL
    let originalBase: String?
    let timestamp: String
    let timeSource: String
    var signature: String
    var size: Int64
    var preview = ""
    var status = "Ready"
    var detail = ""
    var savings = "—"
}
struct RenameChange { let id: UUID; let from: URL; let to: URL }
struct RenameBatch { var changes: [RenameChange] }
struct RenamePlan { let item: PhotoItem; let target: URL?; let reason: String? }
struct PhotoError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
    init(_ message: String) { self.message = message }
}
final class StopFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func stop() { lock.lock(); value = true; lock.unlock() }
    var stopped: Bool { lock.lock(); defer { lock.unlock() }; return value }
}
func signature(_ url: URL) throws -> String {
    var error: NSError?
    guard let result = PWFileSignature(url, &error) else { throw error ?? PhotoError("Cannot read file.") as NSError }
    return result
}
func moveExclusive(_ source: URL, _ target: URL) throws {
    var error: NSError?
    guard PWMoveExclusive(source, target, &error) else { throw error ?? PhotoError("Rename failed.") as NSError }
}
func fileSize(_ url: URL) -> Int64 { (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0 }

struct PhotoCore {
    static func timestamp(_ url: URL) throws -> (String, String) {
        let output = DateFormatter()
        output.locale = Locale(identifier: "en_US_POSIX"); output.calendar = Calendar(identifier: .gregorian)
        output.dateFormat = "yyMMddHHmmss"
        output.timeZone = .current
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let date = attributes[.creationDate] as? Date else {
            throw PhotoError("File creation time is unavailable; file was not renamed.")
        }
        return (output.string(from: date), "File creation time (local time)")
    }
    static func originalBase(_ stem: String) -> String? {
        if stem.range(of: #"^(?:\d{10}|\d{12})(?:_\d{3,})?$"#, options: .regularExpression) != nil { return nil }
        return stem.replacingOccurrences(of: #"_(?:\d{10}|\d{12})(?:_\d{3,})?$"#, with: "", options: .regularExpression)
    }
    static func load(_ url: URL) throws -> PhotoItem {
        let before = try signature(url)
        let (time, source) = try timestamp(url)
        guard try signature(url) == before else { throw PhotoError("File changed while reading metadata.") }
        return PhotoItem(id: UUID(), url: url, originalBase: originalBase(url.deletingPathExtension().lastPathComponent), timestamp: time, timeSource: source, signature: before, size: fileSize(url))
    }
    static func scan(_ inputs: [URL], excluding identities: Set<String>) -> ([PhotoItem], [String]) {
        let fm = FileManager.default
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .isHiddenKey, .isPackageKey]
        var seen = identities, files: [URL] = [], errors: [String] = []
        func inspect(_ url: URL) {
            do {
                let values = try url.resourceValues(forKeys: keys)
                guard values.isSymbolicLink != true, values.isHidden != true, values.isPackage != true else { return }
                if values.isRegularFile == true, supportedExtensions.contains(url.pathExtension.lowercased()),
                   let identity = PWFileIdentity(url), seen.insert(identity).inserted { files.append(url) }
            } catch { errors.append("\(url.lastPathComponent): \(error.localizedDescription)") }
        }
        for input in inputs {
            let url = input.standardizedFileURL
            do {
                let values = try url.resourceValues(forKeys: keys)
                guard values.isSymbolicLink != true, values.isHidden != true, values.isPackage != true else { continue }
                if values.isDirectory == true {
                    if let iterator = fm.enumerator(at: url, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles, .skipsPackageDescendants], errorHandler: { path, error in
                        errors.append("\(path.lastPathComponent): \(error.localizedDescription)"); return true
                    }) {
                        for case let file as URL in iterator {
                            if (try? file.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true { iterator.skipDescendants(); continue }
                            inspect(file)
                        }
                    }
                } else { inspect(url) }
            } catch { errors.append("\(url.lastPathComponent): \(error.localizedDescription)") }
        }
        let items = files.sorted { $0.path < $1.path }.compactMap { url -> PhotoItem? in
            do { return try load(url) } catch { errors.append("\(url.lastPathComponent): \(error.localizedDescription)"); return nil }
        }
        return (items, errors)
    }
    static func plan(_ items: [PhotoItem], style: NamingStyle) -> [RenamePlan] {
        var reserved = Set<String>()
        return items.sorted { $0.url.path < $1.url.path }.map { item in
            if style == .originalAndTimestamp && item.originalBase == nil {
                return RenamePlan(item: item, target: nil, reason: "Original name is unavailable in this session.")
            }
            let base = style == .timestamp ? item.timestamp : "\(item.originalBase!)_\(item.timestamp)"
            let current = item.url.deletingPathExtension().lastPathComponent
            let pattern = "^" + NSRegularExpression.escapedPattern(for: base) + #"(?:_\d{3,})?$"#
            if current.range(of: pattern, options: .regularExpression) != nil {
                reserved.insert(item.url.path.lowercased())
                return RenamePlan(item: item, target: item.url, reason: "Name already matches.")
            }
            let directory = item.url.deletingLastPathComponent()
            var suffix = 0
            var target: URL
            repeat {
                let name = base + (suffix == 0 ? "" : String(format: "_%03d", suffix))
                target = directory.appendingPathComponent(name).appendingPathExtension(item.url.pathExtension)
                suffix += 1
            } while FileManager.default.fileExists(atPath: target.path) || reserved.contains(target.path.lowercased())
            reserved.insert(target.path.lowercased())
            return RenamePlan(item: item, target: target, reason: nil)
        }
    }
    static func rename(_ plan: RenamePlan) throws -> PhotoItem {
        guard let target = plan.target else { throw PhotoError(plan.reason ?? "No target name.") }
        var item = plan.item
        guard try signature(item.url) == item.signature else { throw PhotoError("File changed outside PhotoWorkbench. Remove and add it again.") }
        if target != item.url { try moveExclusive(item.url, target) }
        item.url = target; item.signature = try signature(target); item.size = fileSize(target)
        item.status = target == plan.item.url ? "Skipped" : "Renamed"
        item.detail = plan.reason ?? "Renamed without changing image content."
        return item
    }
    static func undo(_ change: RenameChange, item: PhotoItem) throws -> PhotoItem {
        guard item.url == change.to, try signature(item.url) == item.signature else { throw PhotoError("File changed outside PhotoWorkbench; rename was not undone.") }
        try moveExclusive(item.url, change.from)
        var result = item; result.url = change.from; result.signature = try signature(result.url)
        result.status = "Rename undone"; result.detail = ""; return result
    }
}
