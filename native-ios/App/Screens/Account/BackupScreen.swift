import SwiftUI
import InventoryAppModels
import InventoryCore
import InventoryStrings

/// Off-device backup (RN app/backup.tsx; 03 §9): opt-in, no account, a 26-character recovery
/// code as the only key. Laid out by state, one thing to do at a time: turn it on or restore;
/// write the code down; see that it is on (``BackupScreenModel/body``).
///
/// A failed backup is said plainly with Try again, never "in progress…"; restoring asks before it
/// replaces what is on this phone; a restore that fails leaves backup off. Natively also: a
/// keychain that cannot be read offers Try again instead of Turn on and Restore (03 B8), and an
/// empty phone over existing backups offers to restore the saved copy (03 B12).
struct BackupScreen: View {
    @Environment(AppContainer.self) private var app
    @State private var model: BackupScreenModel?
    /// Whether this phone's database holds anything beyond the drop zone, for the Restore offer.
    @State private var hasRows: InventoryQuery<Bool>?
    @State private var ticker = NowTicker()
    /// The part VoiceOver moves to when the page changes from one state to another (Turn on,
    /// "I have saved it", Show recovery code, a restore): the button pressed goes with the old one.
    @AccessibilityFocusState private var focusedPart: BackupFocusPart?
    #if DEBUG
    @Environment(\.accountDemoBackupAction) private var previewAction
    #endif

    var body: some View {
        ScreenFrame(.detail) {
            if let model, let hasRows {
                form(model, hasRows)
                    .inventoryQuery(hasRows)
                    .nowTicker(ticker)
                    // A finished backup is said once; the line itself is not announced as it ticks.
                    .onChange(of: app.sync.status) { old, new in
                        if let text = model.statusAnnouncement(from: old, to: new, now: ticker.now) {
                            app.platform.announce(text)
                        }
                    }
                    .onChange(of: BackupFocusPart(model.body)) { _, part in
                        guard let part else { return }
                        Task { @MainActor in
                            // Once the new part is on screen.
                            try? await Task.sleep(for: .milliseconds(150))
                            focusedPart = part
                        }
                    }
            } else {
                // Never an empty view: SwiftUI does not run onAppear on one.
                Color.clear
            }
        }
        .navigationTitle(L10n.Backup.title)
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("screen-backup")
        .onAppear(perform: setUp)
    }

    private func setUp() {
        guard model == nil else { return }
        let made = app.makeBackupScreenModel()
        model = made
        let app = app
        hasRows = InventoryQuery(key: "backup-local-has-rows", revision: app.database.revision) {
            try await app.localInventoryHasUserRows()
        }
        #if DEBUG
        runDemoAction(previewAction ?? AccountDemo.takeBackupAction(), on: made)
        #endif
    }

    #if DEBUG
    private func runDemoAction(_ action: AccountDemo.BackupAction?, on model: BackupScreenModel) {
        guard let action else { return }
        let sync = app.sync
        Task {
            switch action {
            case .showCode:
                for _ in 0..<50 where sync.status.account == nil {
                    try? await Task.sleep(for: .milliseconds(100))
                }
                model.showCode()
            case .turnOn:
                await model.turnOn()
            }
        }
    }
    #endif

    private func form(_ model: BackupScreenModel, _ hasRows: InventoryQuery<Bool>) -> some View {
        Form {
            if app.household.session != nil {
                Section {
                    BannerView(tone: .info, message: L10n.Backup.pairedNote, chrome: .row, identifier: "backup-paired-note")
                }
            }
            switch model.body {
            case .unavailable:
                Section {
                    BannerView(tone: .info, message: L10n.Backup.unavailable, chrome: .row, identifier: "backup-unavailable")
                }
            case .revealed(let code):
                BackupRevealedSection(code: code, focus: $focusedPart) { model.saved() }
            case .on:
                BackupOnSections(
                    model: model,
                    now: ticker.now,
                    showsRestoreOffer: model.showsRestoreOffer(localInventoryHasRows: hasRows.data),
                    focus: $focusedPart
                )
            case .unreadable:
                Section {
                    BannerView(
                        tone: .warning,
                        title: L10n.Backup.Unreadable.title,
                        message: L10n.Backup.Unreadable.body,
                        primary: BannerAction(
                            label: L10n.Common.tryAgain,
                            accessibilityHint: L10n.Backup.Unreadable.retryHint,
                            isLoading: model.isRetryingAccountLoad,
                            identifier: "backup-unreadable-retry"
                        ) { Task { await model.retryAccountLoad() } },
                        chrome: .row,
                        identifier: "backup-unreadable"
                    )
                }
            case .off:
                BackupOffSections(model: model, focus: $focusedPart)
            }
        }
        .scrollDismissesKeyboard(.interactively)
    }
}

/// The part of the Backup page that leads each of its states, where VoiceOver goes when the page
/// changes to that state.
enum BackupFocusPart: Hashable {
    /// "Keep a copy off this phone" (off).
    case keep
    /// "Write this code down" (the code shown).
    case writeDown
    /// "Backup is on".
    case on

    /// The part leading `body`, or nil for a state with no part (a notice only).
    init?(_ body: BackupScreenBody) {
        switch body {
        case .off: self = .keep
        case .revealed: self = .writeDown
        case .on: self = .on
        case .unavailable, .unreadable: return nil
        }
    }
}

/// A titled block of the page: a heading, its sentences, then its actions (RN `Part`).
private struct BackupPart<Content: View>: View {
    let title: String
    var spacing: CGFloat = 12
    /// The page's focus and this part's place in it, for a part that leads a state.
    var focus: AccessibilityFocusState<BackupFocusPart?>.Binding?
    var part: BackupFocusPart?
    @ViewBuilder var content: Content

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: spacing) {
                heading
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 6)
        }
    }

    @ViewBuilder private var heading: some View {
        let text = Text(verbatim: title).textRole(.heading, header: true)
        if let focus, let part {
            text.accessibilityFocused(focus, equals: part)
        } else {
            text
        }
    }
}

/// A sentence of a part, in the secondary colour.
private struct BackupParagraph: View {
    let text: String

    var body: some View {
        Text(verbatim: text)
            .textRole(.body)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Off

/// Backup is off: turn it on, or bring a backup onto this phone with its code (RN `BackupOff`).
private struct BackupOffSections: View {
    let model: BackupScreenModel
    let focus: AccessibilityFocusState<BackupFocusPart?>.Binding

    var body: some View {
        BackupPart(title: L10n.Backup.keepTitle, focus: focus, part: .keep) {
            BackupParagraph(text: L10n.Backup.keepBody)
            BackupParagraph(text: L10n.Backup.keepCode)
            if let failure = model.enableFailure {
                BannerView(tone: .warning, message: failure, identifier: "backup-enable-failure")
            }
            LoadingButton(
                label: L10n.Backup.turnOn,
                isLoading: model.isTurningOn,
                isDisabled: model.turnOnDisabled,
                fullWidth: true,
                accessibilityHint: L10n.Backup.turnOnHint,
                identifier: "backup-enable"
            ) { Task { await model.turnOn() } }
        }

        BackupPart(title: L10n.Backup.restoreTitle) {
            BackupParagraph(text: L10n.Backup.restoreBody)
            CodeInput(
                label: L10n.Backup.codeLabel,
                value: Binding(get: { model.code }, set: { model.updateCode($0) }),
                hint: L10n.Backup.codeHint,
                error: model.codeError,
                identifier: "backup-code-input"
            )
            LoadingButton(
                label: L10n.Backup.restore,
                variant: .secondary,
                isLoading: model.isRestoringFromCode,
                isDisabled: model.restoreDisabled,
                fullWidth: true,
                identifier: "backup-restore"
            ) { Task { await model.restore() } }
        }
    }
}

// MARK: - Revealed code

/// The code, once: write it down or share it somewhere safe (RN `RevealedCode`).
private struct BackupRevealedSection: View {
    let code: BackupRevealedCode
    let focus: AccessibilityFocusState<BackupFocusPart?>.Binding
    let onSaved: () -> Void

    var body: some View {
        BackupPart(title: L10n.Backup.writeDownTitle, focus: focus, part: .writeDown) {
            BackupParagraph(text: L10n.Backup.writeDownBody)
            if code.keptExistingCode {
                BannerView(tone: .info, message: L10n.Backup.keptExistingCode, identifier: "backup-kept-code")
            }
            BackupCodeText(code: code)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .padding(.horizontal, 12)
                .background(
                    RoundedRectangle(cornerRadius: DesignMetrics.cardRadius, style: .continuous)
                        .fill(Color(uiColor: .tertiarySystemFill))
                )
                // Spelt out, so it can be written down letter by letter.
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(verbatim: code.spoken))
                .accessibilityIdentifier("backup-code")
            // The share sheet, so it can go to Notes or a password manager.
            ShareLink(item: code.formatted) {
                // Laid out as `LoadingButton`'s label: a `Label` here kept its title to one line
                // inside the bordered button, cut short at the largest sizes.
                HStack(spacing: 8) {
                    Image(glyph: .share)
                    Text(verbatim: L10n.Backup.share)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
            }
            .buttonVariant(.secondary)
            .accessibilityLabel(Text(verbatim: L10n.Backup.share))
            .accessibilityIdentifier("backup-share-code")
            LoadingButton(label: L10n.Backup.saved, fullWidth: true, identifier: "backup-saved", action: onSaved)
        }
    }
}

/// The code in its groups of five, broken only between groups: on one line when it fits, else
/// in two even lines, else a group a line (the largest text sizes), so no line starts with a
/// hyphen or splits a group the reader is copying.
private struct BackupCodeText: View {
    let code: BackupRevealedCode

    var body: some View {
        let lines = code.formattedLines
        ViewThatFits(in: .horizontal) {
            text(lines.one)
            text(lines.two)
            text(lines.each)
        }
    }

    private func text(_ value: String) -> some View {
        Text(verbatim: value)
            .textRole(.code)
            .multilineTextAlignment(.center)
            .fixedSize()
            .textSelection(.enabled)
    }
}

// MARK: - On

/// Backup has an account: when it last ran, run it now, and the way back to the code
/// (RN `BackupOn`).
private struct BackupOnSections: View {
    let model: BackupScreenModel
    let now: Int64
    let showsRestoreOffer: Bool
    let focus: AccessibilityFocusState<BackupFocusPart?>.Binding

    var body: some View {
        if let reason = model.errorReason {
            // Above the card, never "in progress…" for a failure. A failed Back up now lands here
            // too, through backup's status.
            Section {
                BannerView(
                    tone: .warning,
                    title: L10n.Backup.errorTitle,
                    message: reason,
                    primary: BannerAction(
                        label: L10n.Common.tryAgain,
                        isLoading: model.isBackingUp,
                        identifier: "backup-try-again"
                    ) { Task { await model.backUpNow() } },
                    chrome: .row,
                    identifier: "backup-error"
                )
            }
        }

        if showsRestoreOffer {
            Section {
                BannerView(
                    tone: .info,
                    title: L10n.Backup.RestoreOffer.title,
                    message: L10n.Backup.RestoreOffer.body,
                    primary: BannerAction(
                        label: L10n.Backup.RestoreOffer.action,
                        accessibilityHint: L10n.Backup.RestoreOffer.actionHint,
                        isLoading: model.busy == .restoreOffer,
                        identifier: "backup-restore-offer"
                    ) { Task { await model.restoreSavedCopy() } },
                    chrome: .row,
                    identifier: "backup-restore-offer-notice"
                )
                if let failure = model.restoreOfferFailure {
                    BannerView(
                        tone: .warning,
                        title: L10n.Backup.RestoreOffer.failedTitle,
                        message: failure,
                        live: .assertive,
                        chrome: .row,
                        identifier: "backup-restore-offer-failure"
                    )
                }
            }
        }

        if let notice = model.notice {
            Section {
                BannerView(tone: .info, message: notice, onDismiss: { model.dismissNotice() }, chrome: .row, identifier: "backup-notice")
            }
        }

        BackupPart(title: L10n.Backup.onTitle, spacing: 8, focus: focus, part: .on) {
            if let line = model.lastLine(now: now) {
                Text(verbatim: line)
                    .textRole(.meta)
                    .accessibilityIdentifier("backup-last-line")
            }
            BackupParagraph(text: L10n.Backup.automatic)
            if model.showsBackUpNow {
                LoadingButton(
                    label: L10n.Backup.backUpNow,
                    variant: .secondary,
                    isLoading: model.isBackingUp,
                    fullWidth: true,
                    identifier: "backup-now"
                ) { Task { await model.backUpNow() } }
                .padding(.top, 4)
            }
        }

        BackupPart(title: L10n.Backup.codeTitle) {
            BackupParagraph(text: L10n.Backup.codeBody)
            LoadingButton(
                label: L10n.Backup.showCode,
                variant: .secondary,
                fullWidth: true,
                identifier: "backup-show-code"
            ) { model.showCode() }
        }
    }
}

#if DEBUG
#Preview("Off") {
    AccountPreviewHost(.backupOff) { NavigationStack { BackupScreen() } }
}

#Preview("On") {
    AccountPreviewHost(.backupOn) { NavigationStack { BackupScreen() } }
}

#Preview("Failing") {
    AccountPreviewHost(.backupFailing) { NavigationStack { BackupScreen() } }
}

#Preview("Code shown") {
    AccountPreviewHost(.backupReveal) {
        NavigationStack { BackupScreen() }
            .environment(\.accountDemoBackupAction, .showCode)
    }
}

#Preview("Keychain unreadable") {
    AccountPreviewHost(.backupUnreadable) { NavigationStack { BackupScreen() } }
}

#Preview("Restore offered") {
    AccountPreviewHost(.backupRestoreOffer) { NavigationStack { BackupScreen() } }
}

#Preview("Unavailable") {
    AccountPreviewHost(.backupUnavailable) { NavigationStack { BackupScreen() } }
}
#endif
