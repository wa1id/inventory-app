import SwiftUI
import UIKit
import InventoryAppModels
import InventoryCore
import InventoryServices
import InventoryStrings

/// The Add sheet (06 §10, 07 §3.1; RN `app/item/new.tsx`): add an item fast, a name is enough.
///
/// The place defaults to the drop zone; the container the sheet was opened for and the last few
/// places are one tap each under "Where it goes", and "Somewhere else…" swaps the sheet to the
/// full place picker (`PlacePickerHost` in `choose` mode, with Back). Return in the name field
/// saves. A photo is optional: recognition runs in the background, only fills blanks and never
/// blocks saving; the suggestion banner says how it went. Nothing typed is lost to a stray
/// swipe: the draft keeps it, and the next plain open restores it.
///
/// Everything it does is `AddSheetModel`, built once with `AppContainer.makeAddSheetModel`
/// (the router for the camera and closing, the shell's dialogs, the app's stores). The sheet
/// draws its own Cancel (`add-cancel`), which asks through the sheet's close guard
/// (`AddSheetModel.confirmCancel()`) before discarding; a swipe-down keeps the draft, except
/// while saving and in the place step, where the sheet resists it.
struct AddSheet: View {
    let params: AddParams

    @Environment(AppContainer.self) private var app
    @Environment(\.screenAddress) private var address
    @State private var model: AddSheetModel?

    init(params: AddParams) {
        self.params = params
    }

    /// The UI tests find the sheet by it. It sits on each step's list, not around the whole
    /// screen: there it would also replace the identifiers outside the list (the bottom bar's
    /// `item-save`, the notice's `add-save-problem`).
    static let screenIdentifier = "screen-add"

    var body: some View {
        Group {
            if let model {
                AddSheetContent(model: model)
            } else {
                // One frame, until `onAppear` has made the model.
                ScreenFrame(.modal) { Color.clear }
                    .navigationTitle(L10n.Add.title)
                    .navigationBarTitleDisplayMode(.inline)
            }
        }
        .onAppear {
            guard model == nil else { return }
            let made = app.makeAddSheetModel(params: params, address: address)
            model = made
            made.start()
            // A swipe-down, the removed-phone layer or a replacement: the draft keeps the rest.
            if let address { app.router.onRemoval(of: address) { made.sheetClosed() } }
            #if DEBUG
            AddDemo.sheetMade(made)
            #endif
        }
    }
}

/// The sheet once its model exists: the form or the place step, the toolbar, the reads and
/// the focus moves.
private struct AddSheetContent: View {
    @Bindable var model: AddSheetModel

    @Environment(AppContainer.self) private var app
    @Environment(\.screenAddress) private var address
    @Environment(\.isScreenFocused) private var isScreenFocused
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var nameFocus: NameField?
    @FocusState private var detailsFocus: ItemDetailsField?

    /// The name field, the only one the sheet moves focus to.
    enum NameField: Hashable {
        case name
    }

    /// When the places are read: whenever the sheet is in front with a new revision (RN
    /// `useInventoryQuery` re-ran on focus and on every invalidation).
    private struct PlacesTrigger: Hashable {
        var revision: Int
        var focused: Bool
    }

    /// The form's first row, scrolled back to after "Save and add another".
    private static let topAnchor = "add-top"
    /// The form's last row.
    private static let endAnchor = "add-end"

    var body: some View {
        let trigger = PlacesTrigger(revision: app.database.revision, focused: isScreenFocused)
        ZStack {
            if model.isPickingPlace {
                placeStep
                    .transition(.opacity)
            } else {
                formStep
                    .transition(.opacity)
            }
        }
        // RN cross-faded the steps for 180 ms (ease-out), not at all with Reduce Motion.
        .animation(
            reduceMotion ? nil : .timingCurve(0.33, 1, 0.68, 1, duration: Double(Motion.duration.stepSwap) / 1000),
            value: model.isPickingPlace
        )
        .navigationTitle(model.isPickingPlace ? model.placeStepTitle : model.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                if model.isPickingPlace {
                    Button {
                        model.closePlaceStep()
                    } label: {
                        Label(L10n.Add.back, glyph: .back)
                    }
                    .accessibilityIdentifier("add-back")
                } else {
                    Button(L10n.Common.cancel) { cancel() }
                        .accessibilityIdentifier("add-cancel")
                }
            }
        }
        // Mid-save the sheet stays put (the item will own the photo the draft holds), and in the
        // place step a swipe never closes the whole sheet: Back returns to the form.
        .interactiveDismissDisabled(model.interactiveDismissDisabled || model.isPickingPlace)
        .sheetCloseGuard { await model.confirmCancel() }
        .task(id: trigger) {
            guard trigger.focused else { return }
            await model.loadPlaces()
        }
        .task { await focusNameOnArrival() }
        .onChange(of: model.nameFocusRequest) { _, _ in nameFocus = .name }
    }

    // MARK: Form step

    private var formStep: some View {
        ScreenFrame(.modal) {
            ScrollViewReader { proxy in
                FormLayout(contentIdentifier: AddSheet.screenIdentifier) {
                    // Above the fields, so it is seen whatever was scrolled to. A 404 here means
                    // the container went, not the item.
                    if let problem = model.problem {
                        // A new notice per save, so a second failure in the same words is
                        // announced again (RN remounted it).
                        SaveNotice(copy: problem, identifier: "add-save-problem")
                            .id(model.saveAttempts)
                    }
                } content: {
                    formSections
                }
                .onChange(of: model.scrollToTopRequest) { _, _ in
                    // Centring the first row asks for an offset above the top, which the list
                    // clamps to its very top (section spacing included); `.top` would push the
                    // row up under the bar.
                    withAnimation(reduceMotion ? nil : .default) {
                        proxy.scrollTo(Self.topAnchor, anchor: .center)
                    }
                }
                #if DEBUG
                // `-demoState details`: the form's lower half, for screenshots.
                .onChange(of: AddDemoSignals.shared.scrollToEnd) { _, _ in
                    proxy.scrollTo(Self.endAnchor, anchor: .bottom)
                }
                #endif
            }
        } bottomBar: {
            BottomBar(primaryFit: true) {
                LoadingButton(
                    label: L10n.Add.saveAndAnother,
                    variant: .secondary,
                    isLoading: model.saving == .another,
                    isDisabled: model.saving == .save,
                    fullWidth: true,
                    identifier: "item-save-and-add"
                ) {
                    Task { await model.save(andAnother: true) }
                }
            } primary: {
                LoadingButton(
                    label: L10n.Add.save,
                    isLoading: model.saving == .save,
                    isDisabled: model.saving == .another,
                    fullWidth: true,
                    accessibilityLabel: model.saveAccessibilityLabel,
                    identifier: "item-save"
                ) {
                    Task { await model.save(andAnother: false) }
                }
            }
            // Pinned chrome caps its text (as the connection banner does): uncapped, the two
            // stacked buttons and the keyboard leave no room for the form at AX5, and the
            // secondary label was cut short instead of wrapping.
            .dynamicTypeSize(...DynamicTypeSize.accessibility2)
        }
    }

    @ViewBuilder
    private var formSections: some View {
        if model.restored {
            Section {
                BannerView(
                    tone: .info,
                    message: L10n.Add.draft,
                    primary: BannerAction(label: L10n.Add.clearDraft, identifier: "add-draft-clear") { model.clearRestored() },
                    chrome: .row,
                    identifier: "add-draft"
                )
            }
        }

        Section {
            nameField
                .id(Self.topAnchor)
        }

        // Under the field, so the field itself does not move while typing.
        if model.savedNext {
            Section {
                // A new banner per save: said again after each "Save and add another".
                BannerView(tone: .info, glyph: .check, message: L10n.Add.savedNext, chrome: .row, identifier: "add-saved-next")
                    .id(model.saveAttempts)
            }
        }

        if let banner = model.suggestionBanner, banner.bannerCopy != nil {
            Section {
                SuggestionBannerView(
                    state: banner,
                    onRetry: { model.retrySuggestion() },
                    onRefresh: model.staleName == nil ? nil : { model.refreshSuggestion() },
                    chrome: .row
                )
            }
        }

        Section {
            // Never a silent short list: without the read, the container it was opened for and
            // the recent places are missing.
            if model.showsPlacesFailed {
                BannerView(
                    tone: .info,
                    message: L10n.Add.placesFailed,
                    primary: BannerAction(label: L10n.Common.tryAgain, identifier: "add-places-retry") {
                        Task { await model.loadPlaces() }
                    },
                    chrome: .row
                )
            }
            ForEach(model.entries) { entry in
                whereRow(entry)
            }
            elsewhereRow
        } header: {
            Text(verbatim: L10n.Add.`where`)
                .accessibilityAddTraits(.isHeader)
        }

        Section {
            AdaptiveStack(horizontalAlignment: .leading, spacing: 8) {
                Text(verbatim: L10n.Add.howMany)
                    .textRole(.label)
                    .frame(maxWidth: .infinity, alignment: .leading)
                QuantityStepper(
                    value: model.quantity,
                    onChange: { model.setQuantity($0) },
                    size: .compact,
                    itemName: model.stepperItemName,
                    // Save sits outside the scroll view, so tapping it does not leave the
                    // number: a typed count is taken as it is typed.
                    commitWhileTyping: true
                )
            }
        }

        Section {
            DisclosureGroup(isExpanded: detailsExpanded) {
                ItemDetailsFields(
                    values: Binding(get: { model.values }, set: { model.edit($0) }),
                    suggestions: model.categorySuggestions,
                    focus: $detailsFocus
                )
            } label: {
                Text(verbatim: L10n.Forms.moreDetails)
                    .accessibilityIdentifier("item-more-details")
            }
        }

        Section {
            Button {
                snapSeveral()
            } label: {
                Label(L10n.Add.snapSeveral, glyph: .layers)
            }
            .accessibilityIdentifier("item-snap-several")
            .id(Self.endAnchor)
        }
    }

    private var nameField: some View {
        LabeledTextField(
            label: L10n.Add.nameLabel,
            text: $model.name,
            placeholder: L10n.Add.namePlaceholder,
            error: model.nameError,
            // "What is it?" is read as "Name, required".
            accessibilityLabel: L10n.Add.nameA11y,
            input: LabeledFieldInput(submitLabel: .done, onSubmit: submitName, capitalization: .sentences),
            identifier: "item-name",
            focus: $nameFocus,
            field: .name
        ) {
            photoAccessory
        }
    }

    @ViewBuilder
    private var photoAccessory: some View {
        if let photo = model.photo {
            Thumb(
                uri: photo.thumbUri ?? photo.uri,
                // Inset from the field's edge rather than filling it.
                size: 40,
                action: showPhotoOptions,
                accessibilityLabel: L10n.Add.photoOptions,
                identifier: "item-photo-options"
            )
        } else {
            Button(action: takePhoto) {
                Image(glyph: .camera)
                    .font(.title3)
                    .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                    .frame(width: DesignMetrics.minTouchTarget, height: DesignMetrics.minTouchTarget)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(Text(verbatim: L10n.Add.addPhoto))
            .accessibilityIdentifier("item-photo-take")
        }
    }

    private func whereRow(_ entry: WhereEntry) -> some View {
        let selected = model.isChosen(entry)
        return ListRow(
            // The selected row does nothing (the model ignores it).
            action: { model.choose(entry) },
            isSelected: selected,
            minHeight: 52,
            accessibilityLabel: entry.whereAccessibilityLabel,
            identifier: entry.whereIdentifier
        ) {
            if let type = entry.whereVisualType {
                TypeTile(type: type, size: 40)
            } else {
                TypeTile(type: .other, size: 40, glyph: .inbox)
            }
        } content: {
            if let place = entry.wherePlace {
                LocationLine(place: place, size: .row)
                    // The separator starts where the text column does (at the pip), as under the
                    // drop zone's name; the list would otherwise start it at the space name.
                    .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
            } else {
                Text(verbatim: L10n.Add.dropZone).textRole(.name)
                Text(verbatim: L10n.Add.sortLater).textRole(.meta).foregroundStyle(.secondary)
            }
        } aside: {
            if selected {
                Image(glyph: .check)
                    .font(.body.weight(.semibold))
                    .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                    .foregroundStyle(Color.accentColor)
                    .accessibilityHidden(true)
            }
        }
    }

    private var elsewhereRow: some View {
        ListRow(
            action: showPlaceStep,
            showsChevron: true,
            minHeight: 52,
            accessibilityLabel: L10n.Add.elsewhere,
            accessibilityHint: L10n.Add.elsewhereHint,
            identifier: "item-where-more"
        ) {
            // A glyph in a slot the width of the tiles above: one text column for the list.
            Image(glyph: .search)
                .font(.body)
                .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                .foregroundStyle(.secondary)
                .frame(width: 40, height: 40)
        } content: {
            Text(verbatim: L10n.Add.elsewhere)
                .textRole(.name)
                .fontWeight(.medium)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// "More details": open when opened by hand or when the details hold something that was not
    /// closed over (a suggestion that fills them opens it again).
    private var detailsExpanded: Binding<Bool> {
        Binding(
            get: { model.detailsShown },
            set: { shown in
                if shown != model.detailsShown { model.toggleDetails() }
            }
        )
    }

    // MARK: Place step

    private var placeStep: some View {
        ScreenFrame(.modal) {
            // A container made from here comes back as picked, with no re-read.
            PlacePickerHost(mode: .choose, selectedContainerId: model.place.id, showsDropZone: true) { place in
                model.pickPlace(place)
            }
            .accessibilityIdentifier(AddSheet.screenIdentifier)
        }
        // VoiceOver's escape (two-finger scrub) goes back to the form, as RN's Back and swipe
        // did (app/item/new.tsx:327-331); the sheet resists the swipe here, so escape would
        // otherwise do nothing.
        .accessibilityAction(.escape) { model.closePlaceStep() }
    }

    // MARK: Actions

    /// Return in the name field saves, and the keyboard stays up while it does (RN
    /// `submitBehavior="submit"`): the field gets focus back after the system lets it go.
    private func submitName() {
        Task {
            nameFocus = .name
            await model.save(andAnother: false)
        }
    }

    private func cancel() {
        Task {
            if let address {
                // Through the close guard: "Discard this item?" when there is anything to lose.
                await app.router.requestClose(address)
            } else {
                await model.cancel()
            }
        }
    }

    private func takePhoto() {
        dismissKeyboard()
        Task { await model.takePhoto() }
    }

    private func showPhotoOptions() {
        dismissKeyboard()
        guard let sheet = model.photoOptionsSheet() else { return }
        app.platform.actionSheets.showActionSheet(sheet)
    }

    private func showPlaceStep() {
        dismissKeyboard()
        model.showPlaceStep()
    }

    private func snapSeveral() {
        dismissKeyboard()
        model.snapSeveral()
    }

    /// The cursor waits in "What is it?" once the sheet is up (focusing during the slide makes
    /// the keyboard fight it), only without a photo (the suggestion may name it), and only if
    /// the sheet is still in front: not under the camera or a form.
    private func focusNameOnArrival() async {
        guard model.focusesNameOnArrival else { return }
        try? await Task.sleep(for: .milliseconds(500))
        guard !Task.isCancelled, !model.isPickingPlace else { return }
        if let address, !app.router.isFocused(address) { return }
        nameFocus = .name
    }

    /// Lets go of whichever field has the keyboard, the stepper's number included.
    private func dismissKeyboard() {
        nameFocus = nil
        detailsFocus = nil
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }
}

#if DEBUG
#Preview("Plain open") {
    ShellPreviewHost { NavigationStack { AddSheet(params: AddParams()) } }
}

#Preview("From search, no containers") {
    ShellPreviewHost(seed: false) { NavigationStack { AddSheet(params: AddParams(name: "AA batteries")) } }
}

#Preview("Suggestion offered") {
    AddSheetPreview(.offered)
}

#Preview("Suggestion stale") {
    AddSheetPreview(.stale)
}

#Preview("Suggestion failed") {
    AddSheetPreview(.failed)
}

#Preview("Place step") {
    AddSheetPreview(.place)
}

#Preview("Save problem") {
    AddSheetPreview(.saveProblem)
}

#Preview("Restored draft") {
    AddSheetPreview(.draft)
}
#endif
