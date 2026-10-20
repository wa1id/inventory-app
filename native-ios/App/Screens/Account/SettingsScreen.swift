import SwiftUI
import InventoryAppModels
import InventoryStrings

/// Settings (RN app/settings.tsx; 06 §12), pushed on Home's stack from its gear: where this
/// phone's household, backup, help and version live. Every row says its current state, and
/// VoiceOver hears it with the label. Nothing here writes, except How it works, which replays
/// onboarding (the gate swaps to it by itself).
struct SettingsScreen: View {
    @Environment(AppContainer.self) private var app
    @State private var showsTechnical = false

    var body: some View {
        let content = app.accountSettings
        ScreenFrame(.detail) {
            Form {
                Section(L10n.Settings.household) {
                    AccountSettingsLink(
                        label: L10n.Settings.household,
                        value: content.householdValue,
                        glyph: .server,
                        identifier: "settings-household"
                    ) { app.router.push(.household) }
                }

                if let backup = content.backupRow {
                    Section(L10n.Settings.onThisPhone) {
                        if backup.opensScreen {
                            AccountSettingsLink(
                                label: L10n.Settings.backup,
                                value: backup.value,
                                tone: backup.tone == .signal ? .signal : .normal,
                                glyph: .backup,
                                identifier: "settings-backup"
                            ) { app.router.push(.backup) }
                        } else {
                            // A build without a backup service has nothing to open: a static row
                            // says so, rather than a page with one notice on it.
                            SettingsRow(label: L10n.Settings.backup, value: backup.value, glyph: .backup, identifier: "settings-backup")
                        }
                    }
                }

                Section(L10n.Settings.help) {
                    AccountSettingsLink(label: L10n.Settings.howItWorks, glyph: .info, identifier: "settings-replay") {
                        app.onboarding.replay()
                    }
                    AccountSettingsLink(label: L10n.Settings.privacy, glyph: .shield, identifier: "settings-privacy") {
                        app.router.push(.privacy)
                    }
                }

                Section(L10n.Settings.about) {
                    SettingsRow(label: L10n.Settings.version, value: content.version, glyph: .phone, identifier: "settings-version")
                    // RN `animateNextLayout`: the expand animates unless Reduce Motion is on.
                    DisclosureGroup(isExpanded: $showsTechnical.animation(expandAnimation)) {
                        // One stop each, label then value.
                        ForEach(content.technicalFacts) { fact in
                            SettingsRow(label: fact.label, value: fact.value)
                        }
                    } label: {
                        // A plain label, not an element of its own (as `SettingsRow` is): the
                        // group's own button then reads it (RN: one button with its expanded
                        // state) rather than a separate row element beside the group's button.
                        // On the label: set on the group, the identifier lands on every fact too.
                        Label {
                            Text(verbatim: L10n.Settings.technical)
                        } icon: {
                            Image(glyph: .settings).foregroundStyle(.secondary)
                        }
                        .accessibilityIdentifier("settings-technical")
                    }
                }
            }
        }
        .navigationTitle(L10n.Settings.title)
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("screen-settings")
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var expandAnimation: Animation? {
        HomeLayoutMotion.animation(reduceMotion: reduceMotion)
    }
}

/// A settings row that opens something (RN `SettingsRow` with `onPress`): the row's label and
/// value with a chevron, the whole row one button that reads "<label>, <value>".
private struct AccountSettingsLink: View {
    let label: String
    var value: String?
    var tone: SettingsRow.Tone = .normal
    let glyph: Glyph
    let identifier: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                SettingsRow(label: label, value: value, tone: tone, glyph: glyph)
                Image(glyph: .chevronRight)
                    .font(.footnote.weight(.semibold))
                    .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
        }
        .foregroundStyle(.primary)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: FeedbackText.settingsAccessibilityLabel(label: label, value: value)))
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier(identifier)
    }
}

#if DEBUG
#Preview("This phone only") {
    AccountPreviewHost(.backupOff) { NavigationStack { SettingsScreen() } }
}

#Preview("Joined, backup on") {
    AccountPreviewHost(.backupPaired) { NavigationStack { SettingsScreen() } }
}

#Preview("Backup failing") {
    AccountPreviewHost(.backupFailing) { NavigationStack { SettingsScreen() } }
}

#Preview("No backup service") {
    AccountPreviewHost(.backupUnavailable) { NavigationStack { SettingsScreen() } }
}
#endif
