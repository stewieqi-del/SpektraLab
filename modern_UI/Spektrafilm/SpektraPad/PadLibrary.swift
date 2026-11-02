//  PadLibrary.swift — the frame list, as a native sidebar.
//
//  On a Mac the filmstrip along the bottom of the editor is the frame list and
//  there is nowhere else to see every frame at once. iOS asks for the other
//  arrangement: the list is a `NavigationSplitView` column, so the same view
//  works as a fixed sidebar beside the canvas on an iPad and as the first
//  screen of a push stack on an iPhone — which is also what a foldable needs
//  when the split collapses and expands again.
//
//  The rows go through `CropMaskedThumbnail`, the one loader the filmstrip and
//  the export page already share, and they draw `Session.framing(of:)` rather
//  than deciding for themselves which frame is open. Two lists disagreeing
//  about the selection is the defect `FrameFraming` was written to make
//  impossible; a third list that drew its own frame would reintroduce it.
//
//  What this list deliberately does not do: batch operations, pair creation,
//  and the export page's frame picker. Those are already in the material rail
//  (`Panels/LeftPanel.swift`) and the export sheet, and both are shared code.

import SwiftUI
import UniformTypeIdentifiers

struct PadLibrary: View {
    @Bindable var session: Session

    @State private var importing = false
    @State private var importError: String?
    @FocusState private var listFocused: Bool

    var body: some View {
        Group {
            if session.frames.isEmpty {
                empty
            } else {
                list
            }
        }
        .navigationTitle(session.libraryTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbar }
        .fileImporter(isPresented: $importing,
                      allowedContentTypes: Self.openable,
                      allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls):
                SecurityScopedURLs.keep(urls)
                session.open(urls: urls)
            case .failure(let error):
                importError = error.localizedDescription
            }
        }
        .alert(L("Could not open", zh: "无法打开"),
               isPresented: Binding(get: { importError != nil },
                                    set: { if !$0 { importError = nil } })) {
            Button(L("OK", zh: "好")) { importError = nil }
        } message: {
            Text(importError ?? "")
        }
        // `Session.openPanel()` is what the shared code calls when the Mac
        // would put up an NSOpenPanel; on iOS it raises this flag instead, so
        // a button inside a shared panel can still start an import.
        .onChange(of: session.importRequested) { _, requested in
            guard requested else { return }
            session.importRequested = false
            importing = true
        }
    }

    // MARK: list

    @MainActor private var list: some View {
        List {
            Section {
                ForEach(session.frames) { frame in
                    row(frame)
                        // The row is a button, not a List selection: the
                        // selection here is the *picked* set, which is a
                        // multi-frame notion, and `List`'s own selection would
                        // fight it for the same highlight.
                        .contentShape(Rectangle())
                        .onTapGesture { session.click(frame.id, command: false) }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) {
                                session.remove(frame.id)
                            } label: {
                                Label(L("Remove", zh: "移除"), systemImage: "trash")
                            }
                        }
                }
            } header: {
                Text(session.frames.count == 1 ? L("1 frame", zh: "1 张")
                     : L("\(session.frames.count) frames", zh: "\(session.frames.count) 张"))
            } footer: {
                if session.picked.count > 1 {
                    Text(L("\(session.picked.count) frames will be written together.",
                         zh: "将一起输出 \(session.picked.count) 张。"))
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .background(.background)
    }

    @MainActor private func row(_ frame: Frame) -> some View {
        let framing = session.framing(of: frame.id)
        return HStack(spacing: 10) {
            CropMaskedThumbnail(url: frame.id,
                                geometry: session.thumbnailGeometry(for: frame.id),
                                maxPixel: 160) { image in
                ZStack {
                    Rectangle().fill(.quaternary)
                    if let image {
                        Image(decorative: image, scale: 1)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    }
                }
            }
            .frame(width: 46, height: 46)
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .strokeBorder(.primary, lineWidth: framing.lineWidth)
                    .opacity(framing.opacity)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(frame.name)
                    .font(.subheadline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(subtitle(frame))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(framing == .open ? .isSelected : AccessibilityTraits())
    }

    @MainActor private func subtitle(_ frame: Frame) -> String {
        switch session.frameStates[frame.id] {
        case .processed?: frame.isRAW ? L("RAW · developed", zh: "RAW · 已冲洗") : L("developed", zh: "已冲洗")
        case .stale?: L("needs developing", zh: "需要重新冲洗")
        case .unprocessed?, .none: frame.isRAW ? "RAW" : L("unread", zh: "未读取")
        }
    }

    // MARK: empty

    @MainActor private var empty: some View {
        ContentUnavailableView {
            Label(L("No Frames", zh: "没有照片"), systemImage: "photo.on.rectangle.angled")
        } description: {
            Text(L("Open a RAW file, a finished picture, or a folder of them.",
                       zh: "打开 RAW、成品图片，或包含它们的文件夹。"))
        } actions: {
            Button(L("Open…", zh: "打开…")) { importing = true }
                .buttonStyle(.borderedProminent)
        }
    }

    // MARK: toolbar

    @ToolbarContentBuilder
    @MainActor private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Button {
                importing = true
            } label: {
                Label(L("Open", zh: "打开"), systemImage: "folder.badge.plus")
            }
        }
    }

    /// The Mac's open panel filters with `ImageDecoder.openable`; iOS filters by
    /// type, so this has to name the same set. `.rawImage` covers every RAW
    /// UTType an iPhone or iPad can encounter; the concrete types are named
    /// because a folder is not an image and Files only offers a directory when
    /// a directory type is in the list.
    static let openable: [UTType] = {
        var types: [UTType] = [.image, .rawImage, .tiff, .png, .jpeg, .heic]
        types.append(.folder)
        return types
    }()
}

/// Files hands out security-scoped URLs, and the engine decodes a frame long
/// after the importer's closure has returned, so the scope has to outlive it.
/// Keeping it for the life of the process is deliberate: the alternative is a
/// timer that guesses when the last lazy decode is done, and getting that
/// wrong fails a frame in the middle of an export instead of at import.
@MainActor
enum SecurityScopedURLs {
    private static var held: [URL] = []

    static func keep(_ urls: [URL]) {
        for url in urls where url.startAccessingSecurityScopedResource() {
            held.append(url)
        }
    }
}
