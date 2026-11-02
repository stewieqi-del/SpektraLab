//  PadExport.swift — the export sheet.
//
//  The Mac's export page is a two-column window with a recipe editor, a frame
//  picker, a live proof, an open-with picker and a naming-rule chip row. On
//  iOS the destination question mostly disappears: the app writes into its own
//  Documents folder — which Files can see, because `Info.plist` turns on
//  `UIFileSharingEnabled` — and then hands the finished files to the share
//  sheet, which is where "put it in Photos / Mail it / save it to iCloud"
//  lives on this platform.
//
//  So this sheet keeps the four decisions that change the pixels or the file
//  name — format, colour space, quality, output size — and takes the rest from
//  the recipe defaults. What it does *not* offer is the naming-rule editor, the
//  open-with list, and batch selection: those stay gaps against the Mac's page,
//  recorded in PORT-IOS.md rather than half-built here.
//
//  The export itself is `Exporter.export(session:recipe:context:sessionID:)`,
//  the same entry point the Mac's page and the agent tool call. Nothing about
//  writing a file is re-implemented for iOS.

import SwiftUI

struct PadExport: View {
    @Bindable var session: Session
    @Environment(\.dismiss) private var dismiss

    @State private var format: ExportFormat = .jpeg
    @State private var space: ExportColorSpace = .displayP3
    @State private var quality: Double = 0.95
    @State private var resizing = false
    @State private var longEdge = 4000
    @State private var busy = false
    @State private var written: [URL] = []
    @State private var note: String?
    @State private var failure: String?

    private static let spaces = ColorSpaceCatalog.builtIns

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker(L("Format", zh: "格式"), selection: $format) {
                        ForEach(ExportFormat.allCases) { f in
                            Text(f.shortLabel).tag(f)
                        }
                    }
                    Text(format.note)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } header: {
                    Text(L("File", zh: "文件"))
                }

                if format.takesColorSpace {
                    Section(L("Colour", zh: "色彩")) {
                        Picker(L("Colour Space", zh: "色彩空间"), selection: $space) {
                            ForEach(Self.spaces) { entry in
                                Text(entry.name).tag(entry.space)
                            }
                        }
                    }
                }

                if format.takesQuality {
                    Section(L("Quality", zh: "质量")) {
                        LabeledContent(String(format: "%.2f", quality)) {
                            Slider(value: $quality, in: 0.5...1, step: 0.01)
                        }
                    }
                }

                Section {
                    Toggle(L("Resize", zh: "调整尺寸"), isOn: $resizing)
                    if resizing {
                        Stepper(value: $longEdge, in: OutputSize.bounds, step: 500) {
                            LabeledContent(L("Long edge", zh: "长边")) {
                                Text("\(longEdge) px")
                            }
                        }
                    }
                } header: {
                    Text(L("Size", zh: "尺寸"))
                } footer: {
                    Text(L("Never larger than the developed frame — an upsample would invent no detail.",
                           zh: "不会放大到超过冲洗后的画面——插值不会增加细节。"))
                }

                Section {
                    LabeledContent(L("Folder", zh: "文件夹")) {
                        Text("Exports")
                    }
                    if let note {
                        Text(note).font(.footnote).foregroundStyle(.secondary)
                    }
                    ForEach(written, id: \.self) { url in
                        ShareLink(item: url) {
                            Label(url.lastPathComponent, systemImage: "doc")
                        }
                    }
                } header: {
                    Text(L("Destination", zh: "目标"))
                } footer: {
                    Text(L("Files ▸ On My iPad ▸ SpektraPad ▸ Exports shows everything this app has written.",
                           zh: "可在“文件”App 的“我的 iPad ▸ SpektraPad ▸ Exports”中看到全部输出。"))
                }
            }
            .navigationTitle(L("Export", zh: "导出"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L("Done", zh: "完成")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task { await run() }
                    } label: {
                        if busy { ProgressView() } else { Text(L("Export", zh: "导出")) }
                    }
                    .disabled(busy || session.selection == nil)
                }
            }
            .presentationDetents([.medium, .large])
            .alert(L("Export failed", zh: "导出失败"),
                   isPresented: Binding(get: { failure != nil },
                                        set: { if !$0 { failure = nil } })) {
                Button(L("OK", zh: "好")) { failure = nil }
            } message: {
                Text(failure ?? "")
            }
        }
    }

    // MARK: writing

    @MainActor private func run() async {
        guard let source = session.selection else { return }
        guard let sessionID = session.serviceSessionIDForExport else {
            failure = L("The frame is not developed yet.", zh: "这张照片还没有冲洗完成。")
            return
        }
        busy = true
        defer { busy = false }

        var recipe = ExportRecipe()
        recipe.name = "Pad"
        recipe.format = format
        recipe.colorSpace = space
        recipe.folder = .fixed(path: Self.exportDirectory.path)
        recipe.subfolder = ""
        recipe.existing = .addSuffix
        recipe.quality = quality
        recipe.outputSize = resizing ? .longEdge(longEdge) : .original

        let context = NamingRule.Context(
            originalName: source.deletingPathExtension().lastPathComponent,
            filmStock: session.params.filmStock,
            printStock: session.params.printStock,
            pixelSize: .zero, counter: 1, date: Date())

        do {
            try FileManager.default.createDirectory(at: Self.exportDirectory,
                                                    withIntermediateDirectories: true)
            switch try await Exporter.export(session: session, recipe: recipe,
                                             context: context, sessionID: sessionID) {
            case .wrote(let urls, let note, _):
                written = urls
                self.note = note
            case .skipped(let url):
                self.note = L("Already there, left alone: \(url.lastPathComponent)",
                              zh: "已存在，未覆盖：\(url.lastPathComponent)")
            }
        } catch {
            failure = error.localizedDescription
        }
    }

    /// `Exports` inside the app's Documents folder. Created on demand; the
    /// name is not localised because it is a path the user will see in Files
    /// beside folders from every other app, and a Chinese folder name beside
    /// an English one is harder to scan than two English ones.
    static var exportDirectory: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("Exports", isDirectory: true)
    }
}
