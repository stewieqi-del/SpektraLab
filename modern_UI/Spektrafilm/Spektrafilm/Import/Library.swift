//  Library.swift — the folder is the session. One file or one folder (no
//  subfolders), listed and sorted once.

#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif
import UniformTypeIdentifiers

enum Library {
    static func frames(at url: URL) -> [Frame] {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { return [] }
        if !isDir.boolValue {
            return ImageDecoder.openable.contains(url.pathExtension.lowercased()) ? [Frame(id: url)] : []
        }
        // Security-scoped on iOS: a folder handed over by the document picker
        // stays readable only while the scope is held, and the listing is the
        // one read that needs it. On macOS this is a no-op pair.
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let items = (try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants])) ?? []
        return items
            .filter { ImageDecoder.openable.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            .map { Frame(id: $0) }
    }

    #if canImport(AppKit)
    @MainActor
    static func chooseFilesOrFolder() -> [URL] {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.message = "Open a folder of negatives, or one or more image files."
        panel.allowedContentTypes = [.folder, .image, .rawImage, .tiff, .png, .jpeg, .heic]
        return panel.runModal() == .OK ? panel.urls : []
    }
    #endif

    /// Expand a drop / open selection into frames: folders list, files pass.
    static func frames(from urls: [URL]) -> [Frame] {
        var seen = Set<URL>()
        var out: [Frame] = []
        for u in urls {
            for f in frames(at: u) where !seen.contains(f.id) {
                seen.insert(f.id); out.append(f)
            }
        }
        return out
    }
}
