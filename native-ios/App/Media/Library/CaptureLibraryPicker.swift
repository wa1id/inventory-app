import CoreTransferable
import InventoryAppModels
import InventoryServices
import InventoryStrings
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

extension View {
    /// The photo library picker for the capture screen (05 §4.8): `PhotosPicker`, images only, one
    /// photo, the original encoding (`.current`, so a HEIC stays HEIC), and no Photos permission
    /// prompt (the picker runs out of process).
    ///
    /// Every presentation is answered exactly once through `onFinish`, which is what
    /// `CaptureModel.beginLibraryPick()` / `finishLibraryPick(_:)` require: `.picked(.file(url))`
    /// with a private copy of the photo (deleted once `onFinish` returns), `.cancelled` when the
    /// picker closes without a choice (or the screen goes away with it open), `.failed` when the
    /// photo cannot be loaded (`strings.capture.libraryFailed`).
    ///
    /// Attach it once, to the screen's root: the camera's library button and the permission
    /// screen's "Choose a photo instead" both set the same flag, and a picker attached to a button
    /// that goes away (fast mode, the permission screen giving way to the camera) would close with
    /// it.
    ///
    /// ```swift
    /// Button(L10n.Capture.library) { if model.beginLibraryPick() { picking = true } }
    /// …
    /// screen.captureLibraryPicker(isPresented: $picking) { await model.finishLibraryPick($0) }
    /// ```
    func captureLibraryPicker(
        isPresented: Binding<Bool>,
        onFinish: @escaping @MainActor (CaptureLibraryPick) async -> Void
    ) -> some View {
        modifier(CaptureLibraryPickerModifier(isPresented: isPresented, onFinish: onFinish))
    }
}

/// One answer per presentation: opened by the picker appearing, closed by the first answer.
struct CaptureLibraryPickGate: Equatable {
    private(set) var isOpen = false

    /// The picker was presented.
    mutating func opened() {
        isOpen = true
    }

    /// The picker went away; true the first time only, so the presentation is answered once.
    mutating func close() -> Bool {
        defer { isOpen = false }
        return isOpen
    }
}

private struct CaptureLibraryPickerModifier: ViewModifier {
    @Binding var isPresented: Bool
    let onFinish: @MainActor (CaptureLibraryPick) async -> Void

    @State private var selection: PhotosPickerItem?
    @State private var gate = CaptureLibraryPickGate()

    func body(content: Content) -> some View {
        content
            .photosPicker(
                isPresented: $isPresented,
                selection: $selection,
                matching: .images,
                preferredItemEncoding: .current
            )
            .onChange(of: isPresented, initial: true) { _, presented in
                if presented {
                    gate.opened()
                } else {
                    // Closed. A pick usually writes the selection in the same update; give it a
                    // turn, so a pick that lands just after the dismissal is not taken for a
                    // cancel. The selection handler below answers a pick directly.
                    Task {
                        await Task.yield()
                        finish(with: selection)
                    }
                }
            }
            .onChange(of: selection) { _, item in
                // A choice answers at once, whichever of the selection and the dismissal comes
                // first; the gate keeps it to one answer.
                guard let item else { return }
                finish(with: item)
            }
            .onDisappear {
                finish(with: nil)
            }
    }

    /// Answers the open presentation once: with the picked item, or `.cancelled` without one.
    private func finish(with item: PhotosPickerItem?) {
        guard gate.close() else { return }
        selection = nil
        Task { await answer(item) }
    }

    private func answer(_ item: PhotosPickerItem?) async {
        guard let item else {
            await onFinish(.cancelled)
            return
        }
        let picked: CaptureLibraryFile?
        do {
            picked = try await item.loadTransferable(type: CaptureLibraryFile.self)
        } catch {
            MediaLog.camera.error("library photo did not load: \(String(describing: type(of: error)), privacy: .public)")
            picked = nil
        }
        guard let picked else {
            await onFinish(.failed)
            return
        }
        await onFinish(.picked(.file(picked.url)))
        // The image store never deletes its source; the copy is ours (05 §9.2).
        try? FileManager.default.removeItem(at: picked.url)
    }
}

/// A picked photo loaded as a file, never as `Data` (a 48 MP photo would sit in memory twice).
/// The picker's file is removed when the import closure returns, so it is copied to a private
/// temporary file first.
struct CaptureLibraryFile: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .image) { received in
            CaptureLibraryFile(url: try copyToTemporary(received.file))
        }
    }

    /// Copies `source` to `tmp/library-pick-<uuid>.<ext>`, keeping the extension for the record
    /// (the image store sniffs the content, never the name).
    static func copyToTemporary(_ source: URL, in directory: URL = FileManager.default.temporaryDirectory) throws -> URL {
        let ext = source.pathExtension.isEmpty ? "image" : source.pathExtension
        let destination = directory.appending(path: "library-pick-\(UUID().uuidString.lowercased()).\(ext)", directoryHint: .notDirectory)
        try FileManager.default.copyItem(at: source, to: destination)
        return destination
    }
}

#Preview("Library button") {
    @Previewable @State var picking = false
    @Previewable @State var outcome = "–"
    VStack(spacing: 16) {
        Button(L10n.Capture.library, systemImage: "photo.on.rectangle") { picking = true }
            .buttonStyle(.bordered)
            .captureLibraryPicker(isPresented: $picking) { result in
                outcome = switch result {
                case .cancelled: "cancelled"
                case .failed: "failed"
                case .picked: "picked"
                }
            }
        Text(verbatim: outcome)
    }
}
