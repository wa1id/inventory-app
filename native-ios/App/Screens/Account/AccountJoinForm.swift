import SwiftUI
import InventoryAppModels
import InventoryCore
import InventoryStrings

/// Joining the household (RN `JoinForm`, 04 §12.3): the household code, a name for this phone and
/// "Join household" in the bottom bar. Shared by Settings › Household and onboarding's Join step,
/// which each put their own heading above the fields.
///
/// The code forgives small letters, missing hyphens and the look-alikes I, L and O; both fields
/// are checked on press. A failure keeps what was typed: a refused code is said under the code,
/// no answer or any other failure in a banner above the fields (announced). The caller runs the
/// join in a task the form does not own, since pairing swaps Household to its paired view before
/// the join has finished.
struct AccountJoinForm<Header: View>: View {
    let model: JoinFormModel
    /// The connection banner: on for Household, off in onboarding (RN had no frame there).
    var showsConnectionBanner = true
    /// A narrower column than the screen frame's 640 pt on iPad: onboarding's 480 pt (RN
    /// `MAX_WIDTH`). Nil keeps the frame's.
    var columnWidth: CGFloat?
    /// Starts the join, from the button or the name field's Go key.
    let onJoin: () -> Void
    @ViewBuilder var header: Header

    @FocusState private var focus: AccountJoinField?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ScreenFrame(.detail, banner: showsConnectionBanner) {
            ScrollViewReader { proxy in
                form
                    // The form scrolls a focused field above the keyboard, but not above the bar
                    // that rises with it (Join): the name field, the last one, stayed under the
                    // button. Once the keyboard is up, bring it to the middle of what shows.
                    .onChange(of: focus) { _, field in
                        guard let field else { return }
                        Task { @MainActor in
                            try? await Task.sleep(for: .milliseconds(350))
                            guard focus == field else { return }
                            withAnimation(reduceMotion ? nil : .default) {
                                proxy.scrollTo(field, anchor: .center)
                            }
                        }
                    }
            }
            .frame(maxWidth: columnWidth ?? .infinity)
        } bottomBar: {
            BottomBar {
                LoadingButton(
                    label: model.isJoining ? L10n.Join.busy : L10n.Join.submit,
                    isLoading: model.isJoining,
                    fullWidth: true,
                    identifier: "join-submit",
                    action: submit
                )
                .frame(maxWidth: columnWidth ?? .infinity)
            }
        }
    }

    private var form: some View {
        Form {
            Section {
                header
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 4, leading: 4, bottom: 4, trailing: 4))
            }
            if let failure = model.failure {
                Section {
                    BannerView(
                        tone: .warning,
                        message: failure == .offline ? L10n.Join.offline : L10n.Join.other,
                        live: .assertive,
                        chrome: .row,
                        identifier: "join-failure"
                    )
                }
            }
            Section {
                CodeInput(
                    label: L10n.Join.codeLabel,
                    value: Binding(get: { model.code }, set: { model.updateCode($0) }),
                    hint: L10n.Join.codeHint,
                    error: model.errors.code,
                    identifier: "join-code"
                )
                LabeledTextField(
                    label: L10n.Join.nameLabel,
                    text: Binding(get: { model.name }, set: { model.updateName($0) }),
                    placeholder: L10n.Join.namePlaceholder,
                    error: model.errors.name,
                    hint: L10n.Join.nameHint,
                    isRequired: true,
                    input: LabeledFieldInput(
                        submitLabel: .go,
                        onSubmit: submit,
                        capitalization: .words,
                        disablesAutocorrection: true
                    ),
                    identifier: "join-name",
                    focus: $focus,
                    field: .name
                )
                .id(AccountJoinField.name)
            } footer: {
                Text(verbatim: model.serverCaption)
                    .textRole(.caption)
            }
        }
        .scrollDismissesKeyboard(.interactively)
    }

    private func submit() {
        focus = nil
        onJoin()
    }
}

/// The join form's name field, so Join can put the keyboard away (the code field keeps its own
/// focus: its Return closes the keyboard, as RN's did).
enum AccountJoinField: Hashable {
    case name
}

#if DEBUG
#Preview("Join form") {
    AccountPreviewHost(.unpaired) {
        AccountJoinFormPreview()
    }
}

private struct AccountJoinFormPreview: View {
    @Environment(AppContainer.self) private var app
    @State private var model: JoinFormModel?

    var body: some View {
        NavigationStack {
            if let model {
                AccountJoinForm(model: model, onJoin: { Task { _ = await model.join() } }) {
                    Text(verbatim: L10n.Household.joinHeading).textRole(.heading, header: true)
                }
                .navigationTitle(L10n.Household.screenTitle)
                .navigationBarTitleDisplayMode(.inline)
            }
        }
        .onAppear { model = model ?? app.makeJoinForm() }
    }
}
#endif
