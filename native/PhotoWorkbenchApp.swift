import SwiftUI
import AppKit
import QuickLook
import UniformTypeIdentifiers

final class ApplicationDelegate: NSObject, NSApplicationDelegate {
    weak var model: WorkbenchModel?
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model, model.busy else { return .terminateNow }
        model.afterFinish = { sender.reply(toApplicationShouldTerminate: true) }
        model.stop(); return .terminateLater
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
struct WindowSetup: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { view.window?.setFrameAutosaveName("PhotoWorkbench.Main") }
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}
@main
struct PhotoWorkbenchApp: App {
    @NSApplicationDelegateAdaptor(ApplicationDelegate.self) private var delegate
    @StateObject private var model = WorkbenchModel()
    @State private var settings = false
    var body: some Scene {
        Window("PhotoWorkbench", id: "main") {
            WorkbenchView(model: model, settings: $settings)
                .background(WindowSetup())
                .onAppear { delegate.model = model }
                .sheet(isPresented: $settings) { SettingsView().frame(width: 530, height: 500) }
        }
        .defaultSize(width: 660, height: 460)
        .commands {
            CommandGroup(replacing: .newItem) { Button("Add Images or Folders…", action: model.addPanel).keyboardShortcut("o") }
            CommandGroup(replacing: .appSettings) { Button("Settings…") { settings = true }.keyboardShortcut(",").disabled(model.busy) }
            CommandGroup(replacing: .undoRedo) {
                Button("Undo Rename", action: model.undoRename).keyboardShortcut("z").disabled(model.busy || model.undoBatches.isEmpty)
                Button("Restore Originals", action: model.restore).disabled(model.busy || !model.canRestore)
                Divider()
                Button("Quick Look", action: model.preview).keyboardShortcut(.space, modifiers: []).disabled(model.items.isEmpty || settings)
            }
        }
    }
}
struct WorkbenchView: View {
    @ObservedObject var model: WorkbenchModel
    @Binding var settings: Bool
    @State private var targeted = false
    @State private var info = false
    @AppStorage("LossyEnabled") private var lossy = false
    @AppStorage("JpegTranStripAll") private var stripJPEG = false
    @AppStorage("PngOutRemoveChunks") private var stripPNG = false
    @AppStorage("PreserveDates") private var keepDates = true
    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Table(model.items, selection: $model.selection) {
                    TableColumn("Name") { item in Text(item.url.lastPathComponent).help(item.url.path) }.width(min: 110, ideal: 150)
                    TableColumn("Rename Preview") { item in Text(item.preview).foregroundStyle(.secondary).help("\(item.timeSource)\n\(item.preview)") }.width(min: 125, ideal: 175)
                    TableColumn("Size") { item in Text(ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file)).monospacedDigit() }.width(75)
                    TableColumn("Saved") { item in Text(item.savings).monospacedDigit() }.width(55)
                    TableColumn("Status") { item in
                        Text(item.status).lineLimit(1).truncationMode(.tail)
                            .foregroundStyle(item.status == "Failed" ? Color.red : Color.primary)
                            .help([item.status, item.detail].filter { !$0.isEmpty }.joined(separator: "\n"))
                    }.width(95)
                }
                .contextMenu(forSelectionType: UUID.self) { ids in
                    Button("Quick Look") { model.selection = ids; model.preview() }.disabled(ids.isEmpty)
                    Button("Reveal in Finder") { model.selection = ids; model.reveal() }.disabled(ids.isEmpty)
                    Divider()
                    Button("Remove from List") { model.remove(ids) }.disabled(model.busy || ids.isEmpty)
                } primaryAction: { ids in model.selection = ids; model.preview() }
                .onKeyPress(.space) { model.preview(); return .handled }
                .quickLookPreview($model.previewURL, in: model.items.map(\.url))
                if model.items.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "photo.stack").font(.system(size: 40)).foregroundStyle(.secondary)
                        Text("Drop images or folders here").font(.title3)
                        Text("Add first, then choose Rename or Compress.").foregroundStyle(.secondary)
                        Button("Add Images…", action: model.addPanel)
                    }.allowsHitTesting(true)
                }
            }
            .overlay { if targeted { RoundedRectangle(cornerRadius: 6).stroke(Color.accentColor, lineWidth: 3).padding(3).allowsHitTesting(false) } }
            .onDrop(of: [.fileURL], isTargeted: $targeted) { providers in
                let group = DispatchGroup(), lock = NSLock()
                var urls: [URL] = []
                for provider in providers {
                    group.enter()
                    provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                        let url = (item as? URL) ?? (item as? Data).flatMap { URL(dataRepresentation: $0, relativeTo: nil) }
                        if let url { lock.lock(); urls.append(url); lock.unlock() }; group.leave()
                    }
                }
                group.notify(queue: .main) { model.add(urls) }; return true
            }
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    if model.busy || model.scanning { ProgressView().controlSize(.small) }
                    Text(model.scanning && !model.busy ? "Reading images…" : model.summary).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if model.busy { Button("Stop", action: model.stop) }
                }
                HStack(spacing: 8) {
                    Picker("Name format", selection: $model.style) {
                        ForEach(NamingStyle.allCases) { Text($0.title).tag($0) }
                    }.labelsHidden().frame(width: 170).disabled(model.busy)
                    Button("Rename", action: model.rename).disabled(model.busy || model.items.isEmpty)
                    Button("Compress", action: model.compress).disabled(model.busy || model.items.isEmpty)
                    Button { info.toggle() } label: { Image(systemName: "info.circle") }.buttonStyle(.plain).help("Compression behavior")
                    Spacer(minLength: 0)
                    Button("Add…", action: model.addPanel)
                    Button("Clear") { model.remove(Set(model.items.map(\.id))) }.disabled(model.busy || model.items.isEmpty)
                    Button { settings = true } label: { Image(systemName: "gearshape") }.disabled(model.busy).help("Settings")
                }.controlSize(.small)
                HStack {
                    Button("Undo Rename", action: model.undoRename).disabled(model.busy || model.undoBatches.isEmpty)
                    Button("Restore Originals", action: model.restore).disabled(model.busy || !model.canRestore)
                    Spacer()
                    Text("Actions apply to the whole list").font(.caption).foregroundStyle(.secondary)
                }.controlSize(.small)
                if info {
                    Text("\(lossy ? "Lossy compression enabled" : "Strict lossless compression") · JPEG metadata \(stripJPEG ? "removal allowed" : "preserved") · PNG metadata \(stripPNG ? "removal allowed" : "preserved") · Dates \(keepDates ? "preserved" : "may change"). Smaller results replace files; originals go to Trash. Restore is available during this session.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }.padding(12)
        }
        .frame(minWidth: 620, minHeight: 380)
        .alert("PhotoWorkbench", isPresented: Binding(get: { model.notice != nil }, set: { if !$0 { model.notice = nil } })) {
            Button("OK") { model.notice = nil }
        } message: { Text(model.notice ?? "") }
    }
}
struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var section = SettingsSection.general
    @AppStorage("LossyEnabled") private var lossy = false
    @AppStorage("JpegOptimMaxQuality") private var jpegQuality = 80
    @AppStorage("PngMinQuality") private var pngQuality = 80
    @AppStorage("AdvPngLevel") private var effort = 4
    @AppStorage("JpegTranStripAll") private var stripJPEG = false
    @AppStorage("PngOutRemoveChunks") private var stripPNG = false
    @AppStorage("PreserveDates") private var dates = true
    @AppStorage("PreservePermissions") private var permissions = true
    @AppStorage("RunLowPriority") private var lowPriority = false
    @AppStorage("GuetzliEnabled") private var guetzli = false
    private func engine(_ title: String, _ key: String) -> some View {
        EngineSwitch(title: title, key: key)
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack { Text("Settings").font(.headline); Spacer() }.padding([.top, .horizontal], 16)
            Picker("Settings section", selection: $section) {
                ForEach(SettingsSection.allCases) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented).labelsHidden().padding(16)
            Divider()
            Group {
                switch section {
                case .general:
                Form {
                    Section("File handling") {
                        Toggle("Preserve file dates", isOn: $dates)
                        Toggle("Preserve file permissions", isOn: $permissions)
                        Toggle("Allow JPEG metadata removal", isOn: $stripJPEG)
                        Toggle("Allow PNG metadata removal", isOn: $stripPNG)
                        Text("Metadata can contain capture time, orientation, camera details and color profiles. Originals are moved to Trash only when a smaller result is saved.").font(.caption).foregroundStyle(.secondary)
                    }
                    Section("JPEG engines") {
                        engine("JPEGOptim", "JpegOptimEnabled"); engine("Jpegtran / MozJPEG", "JpegTranEnabled")
                        Toggle("Guetzli (lossy only)", isOn: $guetzli)
                        if guetzli { Text("Requires lossy mode, JPEG quality ≥ 85 and JPEG metadata removal. These options are never changed automatically.").font(.caption).foregroundStyle(.orange) }
                    }
                }.formStyle(.grouped)
                case .quality:
                Form {
                    Toggle("Enable lossy compression", isOn: $lossy)
                    Text("Off: decoded pixels must remain identical, including hidden RGB in transparent PNG pixels. On: selected quality settings may change pixels.").font(.caption).foregroundStyle(.secondary)
                    Stepper("JPEG quality: \(jpegQuality)", value: $jpegQuality, in: 50...99).disabled(!lossy)
                    Stepper("PNG minimum quality: \(pngQuality)", value: $pngQuality, in: 40...100).disabled(!lossy)
                    Text("Metadata preservation still applies in lossy mode. A result that loses protected metadata is rejected.").font(.caption).foregroundStyle(.secondary)
                }.formStyle(.grouped)
                case .speed:
                Form {
                    Stepper("Optimization effort: \(effort) / 6", value: $effort, in: 0...6)
                    Text("Higher effort can save more space but takes longer. ImageOptim's engine-specific scheduling and parameter mappings are retained.").font(.caption).foregroundStyle(.secondary)
                    Toggle("Run at low priority", isOn: $lowPriority)
                    Section("PNG engines") {
                        engine("OxiPNG", "OptiPngEnabled"); engine("PNGOUT", "PngOutEnabled")
                        engine("ZopfliPNG", "ZopfliEnabled"); engine("AdvPNG", "AdvPngEnabled")
                        engine("PNGCrush", "PngCrush2Enabled")
                        Text("AdvPNG runs when PNG metadata removal is allowed, matching ImageOptim.").font(.caption).foregroundStyle(.secondary)
                    }
                }.formStyle(.grouped)
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }.padding(12)
        }
    }
}
private enum SettingsSection: String, CaseIterable, Identifiable {
    case general = "General", quality = "Quality", speed = "Optimization Speed"
    var id: Self { self }
}
private struct EngineSwitch: View {
    let title: String
    @AppStorage private var enabled: Bool
    init(title: String, key: String) {
        self.title = title
        _enabled = AppStorage(wrappedValue: false, key)
    }
    var body: some View { Toggle(title, isOn: $enabled) }
}
