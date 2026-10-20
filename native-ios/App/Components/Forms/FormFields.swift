import SwiftUI
import InventoryAppModels
import InventoryCore
import InventoryStrings

/// The fields of the item details, in focus order.
enum ItemDetailsField: Hashable, Sendable {
    case category, tags, notes
}

/// Category, Tags and Notes: the details under "More details" in the Add sheet and the Edit
/// details form (RN `ItemDetailsFields`, 07 §4.6). Put it in a `Form` section.
///
/// Return moves Category → Tags → Notes with the keyboard up; in Notes it starts a new line.
/// While Category is focused, up to six recent categories show as chips; a chip fills the field
/// only when tapped, then moves on to Tags, so a suggestion never lands while someone types.
struct ItemDetailsFields: View {
    @Binding var values: ItemFormValues
    /// The categories `CategoryMemory` suggests for what is typed (the Add sheet's
    /// `categorySuggestions`); shown only while Category is focused.
    let suggestions: [String]
    var focus: FocusState<ItemDetailsField?>.Binding

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            LabeledTextField(
                label: L10n.Forms.categoryLabel,
                text: $values.category,
                placeholder: L10n.Forms.categoryPlaceholder,
                input: LabeledFieldInput(submitLabel: .next, onSubmit: { focus.wrappedValue = .tags }),
                identifier: "item-category",
                focus: focus,
                field: .category
            )
            if focus.wrappedValue == .category && !suggestions.isEmpty {
                WrappingHStack(horizontalSpacing: 8, verticalSpacing: 8) {
                    ForEach(Array(suggestions.enumerated()), id: \.offset) { index, category in
                        TagChip(label: category, identifier: "item-category-chip-\(index)") {
                            values.category = category
                            focus.wrappedValue = .tags
                        }
                    }
                }
            }
        }
        LabeledTextField(
            label: L10n.Forms.tagsLabel,
            text: $values.tags,
            placeholder: L10n.Forms.tagsPlaceholder,
            hint: L10n.Forms.tagsHint,
            input: LabeledFieldInput(submitLabel: .next, onSubmit: { focus.wrappedValue = .notes }),
            identifier: "item-tags",
            focus: focus,
            field: .tags
        )
        LabeledTextField(
            label: L10n.Forms.notesLabel,
            text: $values.notes,
            isMultiline: true,
            identifier: "item-notes",
            focus: focus,
            field: .notes
        )
    }
}

/// The space form's focusable field.
enum SpaceFieldsFocus: Hashable, Sendable {
    case name
}

/// Name, icon and colour of a space, shared by New space and Edit space (RN `SpaceFields`,
/// 07 §4.17). Sections for a `Form`.
///
/// The icons are drawn in the chosen colour, and a live row shows the space as the Spaces tab
/// will, so the tint is seen before saving. The preview is a picture of the fields above, so
/// VoiceOver skips it.
struct SpaceFields: View {
    @Binding var values: SpaceFormValues
    /// "Give the space a name." under the name.
    var nameError: String?
    /// Return saves, as the form's primary button does.
    let onSubmit: () -> Void
    /// The preview's second line ("New space", or the real counts); nil hides the preview while
    /// the counts load rather than show wrong numbers.
    var previewMeta: String?
    /// The preview's name while the field is empty: an example for a new space, the stored name
    /// for one being edited.
    var previewFallbackName: String = L10n.SpaceForm.previewName
    var focus: FocusState<SpaceFieldsFocus?>.Binding
    /// A prominent heading over the fields ("Your own" under New space's presets); none by default.
    var heading: String?

    var body: some View {
        if let heading {
            Section {
                nameField
            } header: {
                Text(verbatim: heading).accessibilityAddTraits(.isHeader)
            }
            .headerProminence(.increased)
        } else {
            Section { nameField }
        }
        Section {
            EmojiPicker(label: L10n.SpaceForm.iconLabel, value: $values.icon, color: values.color)
        }
        Section {
            SwatchPicker(label: L10n.SpaceForm.colourLabel, value: $values.color)
        }
        if let previewMeta {
            Section {
                HStack(spacing: 12) {
                    SpaceTile(icon: values.icon, color: values.color, size: 56)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: SpacePalette.previewName(values.name, fallback: previewFallbackName))
                            .textRole(.name)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(verbatim: previewMeta)
                            .textRole(.meta)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .accessibilityHidden(true)
                .accessibilityIdentifier("space-row-preview")
            } header: {
                Text(verbatim: L10n.SpaceForm.previewLabel)
                    .accessibilityHidden(true)
            }
        }
    }

    private var nameField: some View {
        LabeledTextField(
            label: L10n.SpaceForm.nameLabel,
            text: $values.name,
            placeholder: L10n.SpaceForm.namePlaceholder,
            error: nameError,
            isRequired: true,
            input: LabeledFieldInput(submitLabel: .done, onSubmit: onSubmit, capitalization: .sentences),
            identifier: "space-name",
            focus: focus,
            field: .name
        )
    }
}

/// The frame of the space and container sheets (RN `FormLayout`, 07 §4.14): a failed save's
/// notice above the form, the fields scrolling, and the primary action in a bar at the bottom
/// that the keyboard pushes up rather than covers.
///
/// The notice stays pinned above the fields (``SwiftUI/View/pinnedNotice(_:)``), so it is seen
/// and announced however far the form was scrolled; at the largest text sizes a long one takes
/// at most part of the height and scrolls within it, so the fields and the bar stay on screen.
/// An optional notice that is nil adds nothing.
struct FormLayout<Notice: View, Content: View, BottomBar: View>: View {
    @ViewBuilder var notice: Notice
    @ViewBuilder var content: Content
    @ViewBuilder var bottomBar: BottomBar

    /// Decided by type, never by value, so a notice that comes and goes keeps the form's
    /// identity (and its focus). A nil optional notice measures zero, so it adds nothing.
    private var hasNotice: Bool { !(Notice.self == EmptyView.self) }

    var body: some View {
        Form {
            content
        }
        .modifier(PinnedNoticeInset(isEmpty: !hasNotice, notice: notice))
        .modifier(FormLayoutBottomBar(hasBar: !(BottomBar.self == EmptyView.self)) {
            bottomBar
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .readableContentWidth()
        })
    }
}

extension FormLayout where BottomBar == EmptyView {
    /// Without a bar of its own: inside the app, put the form in `ScreenFrame(.modal)` and pass
    /// the shell's `BottomBar` as the frame's `bottomBar`, which also lifts toasts above it and
    /// stacks its buttons at large sizes.
    init(@ViewBuilder notice: () -> Notice, @ViewBuilder content: () -> Content) {
        self.init(notice: notice, content: content, bottomBar: { EmptyView() })
    }
}

extension View {
    /// Pins `notice` (a failed save, a conflict, a move that did not happen) above this
    /// scrolling content, outside it, as RN's `FormLayout` and the Move sheet did: a list row
    /// would scroll away, and a row off screen is neither seen nor announced, since SwiftUI
    /// builds list rows lazily. A long notice at the largest text sizes takes at most
    /// ``PinnedNoticeInset/heightShare`` of the height and scrolls within it, so the content and
    /// the bottom bar stay on screen. An optional notice that is nil adds nothing.
    func pinnedNotice<Notice: View>(@ViewBuilder _ notice: () -> Notice) -> some View {
        modifier(PinnedNoticeInset(isEmpty: Notice.self == EmptyView.self, notice: notice()))
    }
}

/// See ``SwiftUI/View/pinnedNotice(_:)``.
struct PinnedNoticeInset<Notice: View>: ViewModifier {
    /// The most of the content's height a pinned notice takes before it scrolls.
    static var heightShare: CGFloat { 0.4 }

    let isEmpty: Bool
    let notice: Notice

    /// The notice's own height, and the height of the content and the notice together.
    @State private var noticeHeight: CGFloat = 0
    @State private var contentHeight: CGFloat = 0

    func body(content: Content) -> some View {
        if isEmpty {
            content
        } else {
            content
                .safeAreaInset(edge: .top, spacing: 0) { pinned }
                // Measured outside the inset, which shrinks the content by the notice's height.
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
        }
    }

    private var cap: CGFloat {
        contentHeight > 0 ? (contentHeight * Self.heightShare).rounded() : .infinity
    }

    private var pinned: some View {
        // Always the same scroll view, so the banner keeps its identity (and is announced
        // once) when its height crosses the cap; it scrolls only when it must.
        ScrollView {
            VStack(spacing: 0) {
                notice
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
            }
            .readableContentWidth()
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { noticeHeight = $0 }
        }
        .scrollBounceBehavior(.basedOnSize)
        .scrollDisabled(noticeHeight <= cap)
        // Shows that a capped notice scrolls.
        .scrollIndicatorsFlash(trigger: noticeHeight > cap)
        .frame(height: min(noticeHeight, cap))
        .background(Color(uiColor: .systemGroupedBackground))
    }
}

/// The form's own bottom bar, when it has one.
private struct FormLayoutBottomBar<Bar: View>: ViewModifier {
    let hasBar: Bool
    @ViewBuilder let bar: () -> Bar

    func body(content: Content) -> some View {
        if hasBar {
            content.safeAreaBar(edge: .bottom) { bar() }
        } else {
            content
        }
    }
}

/// Why a save did not happen, in plain words, never the raw message; what was typed stays in
/// the form (RN `SaveNotice`). A warning banner, announced at once.
struct SaveNotice: View {
    let copy: SaveNoticeCopy
    var action: BannerAction?
    var identifier: String?

    var body: some View {
        BannerView(tone: .warning, title: copy.title, message: copy.message, primary: action, live: .assertive, identifier: identifier)
    }
}

/// The drop zone's space and container cannot be renamed, moved or deleted; this answers a
/// stale link to their forms (RN `DropZoneLocked`, 07 §0.1).
struct DropZoneLocked: View {
    let onGoToDropZone: () -> Void

    var body: some View {
        EmptyStateView(
            title: L10n.Errors.DropZoneLocked.title,
            message: L10n.Errors.DropZoneLocked.body,
            glyph: .inbox,
            primary: StateAction(label: L10n.Errors.DropZoneLocked.action, action: onGoToDropZone)
        )
    }
}

#if DEBUG
#Preview("Item details") {
    @Previewable @State var values = ItemFormValues(name: "Drill", category: "To")
    @Previewable @FocusState var focus: ItemDetailsField?
    Form {
        Section { ItemDetailsFields(values: $values, suggestions: ["Tools", "Toys"], focus: $focus) }
    }
}

#Preview("Space form") {
    @Previewable @State var values = SpaceFormValues(name: "", icon: SpacePalette.icons[0], color: SpacePalette.colors[0])
    @Previewable @FocusState var focus: SpaceFieldsFocus?
    FormLayout {
        SaveNotice(copy: SaveNoticeCopy(cause: CocoaError(.fileWriteUnknown), subject: .space))
    } content: {
        SpaceFields(values: $values, nameError: nil, onSubmit: {}, previewMeta: L10n.SpaceForm.previewNew, focus: $focus)
    } bottomBar: {
        LoadingButton(label: L10n.SpaceForm.create, fullWidth: true, action: {})
    }
}

#Preview("Drop zone locked") {
    DropZoneLocked(onGoToDropZone: {})
}
#endif
