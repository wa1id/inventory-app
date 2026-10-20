#if DEBUG
import SwiftUI
import InventoryAppModels
import InventoryCore
import InventoryStrings

/// Debug builds only: `PlacePickerHost` in each mode over the seeded preview inventory, for
/// screenshots and UI tests (`-gallery foundation -galleryPage N`). No route shows the host until
/// the screen wave builds Move, Add, bind and Scan, so this is where it can be looked at. The
/// bar under the title shows the last pick (`foundation-picked`). The forms it opens have no
/// modal presentation here.
struct FoundationGallery: View {
    let page: Int

    var body: some View {
        let current = FoundationGalleryPage(rawValue: page) ?? .move
        ShellPreviewHost(seed: current != .nothingAtAll) {
            NavigationStack {
                FoundationGalleryPicker(page: current)
            }
        }
        .measuresLayoutWindowWidth()
    }
}

/// The gallery's pages, by number.
enum FoundationGalleryPage: Int, CaseIterable {
    /// Move the Cordless drill: Tool chest is "Here now"; two recent places.
    case move
    /// File from the drop zone.
    case file
    /// Where a new item goes: the drop zone first, Top drawer chosen.
    case choose
    /// Which container a new label belongs to.
    case bind
    /// Open a container by its code: the filter focused, characters capitalised.
    case open
    /// A move saving into Red bin, with a notice: the list locked and dimmed.
    case moveBusy
    /// No spaces at all: the "make a space" empty state.
    case nothingAtAll
    /// A filter that matches nothing: "Make a new container" in each space.
    case noMatch

    var title: String {
        switch self {
        case .move: "Move"
        case .file: "File"
        case .choose: "Choose"
        case .bind: "Bind"
        case .open: "Open by code"
        case .moveBusy: "Move, busy"
        case .nothingAtAll: "Nothing at all"
        case .noMatch: "No match"
        }
    }

    var mode: PlacePickerMode {
        switch self {
        case .move, .moveBusy: .move
        case .file, .nothingAtAll: .file
        case .choose, .noMatch: .choose
        case .bind: .bind
        case .open: .open
        }
    }
}

private struct FoundationGalleryPicker: View {
    let page: FoundationGalleryPage

    @Environment(AppContainer.self) private var app
    @State private var ids: [String: String]?
    @State private var picked: String?

    var body: some View {
        Group {
            if let ids {
                host(ids)
            } else {
                ProgressView()
            }
        }
        .navigationTitle(Text(verbatim: "\(page.rawValue). \(page.title)"))
        .navigationBarTitleDisplayMode(.inline)
        // Not the title: iOS hides it while the search field is active.
        .safeAreaInset(edge: .top) {
            if let picked {
                Text(verbatim: "Picked \(picked)")
                    .font(.footnote)
                    .padding(6)
                    .frame(maxWidth: .infinity)
                    .background(.bar)
                    .accessibilityIdentifier("foundation-picked")
            }
        }
        .task {
            // The seeded containers by name, and two recent places, before the host reads them.
            let rows = (try? await app.repositories.containers.listAllWithSpace()) ?? []
            var byName: [String: String] = [:]
            for row in rows { if let name = row.container.name { byName[name] = row.container.id } }
            for name in ["Tool chest", "Top drawer"] { if let id = byName[name] { app.recentPlaces.remember(id) } }
            ids = byName
        }
    }

    @ViewBuilder
    private func host(_ ids: [String: String]) -> some View {
        let onPick: (PickedPlace) -> Void = { place in
            switch place {
            case .dropZone: picked = L10n.Picker.dropZone
            case .container(let option): picked = PlacePickerRules.optionLabel(option)
            }
        }
        switch page {
        case .move:
            PlacePickerHost(mode: .move, currentContainerId: ids["Tool chest"], onPick: onPick)
        case .file, .nothingAtAll:
            PlacePickerHost(mode: .file, currentContainerId: DropZone.containerId, onPick: onPick)
        case .choose:
            PlacePickerHost(mode: .choose, selectedContainerId: ids["Top drawer"], showsDropZone: true, onPick: onPick)
        case .bind:
            PlacePickerHost(mode: .bind, onPick: onPick)
        case .open:
            PlacePickerHost(mode: .open, placeholder: L10n.Scan.codePlaceholder, onPick: onPick)
        case .moveBusy:
            PlacePickerHost(mode: .move, currentContainerId: ids["Tool chest"], busyId: ids["Red bin"]) {
                BannerView(tone: .warning, title: L10n.Errors.Offline.title, message: L10n.Move.failed, live: .off)
            } onPick: { place in onPick(place) }
        case .noMatch:
            PlacePickerHost(mode: .choose, showsDropZone: true, initialQuery: "zzz", onPick: onPick)
        }
    }
}

#Preview("Move") { FoundationGallery(page: 0) }
#Preview("Open") { FoundationGallery(page: 4) }
#endif
