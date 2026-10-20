/**
 * Native-only copy for the account area (Settings, Household, Backup, Privacy,
 * Onboarding): states only the native app has. generate.mjs merges this tree
 * into the strings.ts tree, so `backup.unreadable.title` becomes
 * `L10n.Backup.Unreadable.title`. Never copy these into src/i18n/strings.ts
 * (DECISIONS U9); see native-ios/scripts/strings/README.md.
 */
export const strings = {
  backup: {
    /**
     * 03 B8: the keychain refused to read this phone's recovery code (often
     * while the phone is locked). Turn on and Restore stay hidden until a read
     * works; Try again (`common.tryAgain`) reads it again.
     */
    unreadable: {
      title: 'Backup cannot be checked right now',
      body: 'This phone could not read its recovery code just now. This can happen while the phone is locked. Nothing has been changed or lost.',
      /** VoiceOver hint on Try again. */
      retryHint: 'Reads the recovery code again',
    },
    /**
     * 03 B12: this phone's inventory is empty while its backup account already
     * has backups, so no backup is uploaded over them. Neutral on purpose: a
     * new user whose only backup is of an empty inventory sees it too.
     */
    restoreOffer: {
      title: 'Nothing to back up yet',
      body: 'This phone’s inventory is empty, so backup keeps the copy it already has instead of replacing it, and carries on once something is added. If that copy has things you want on this phone, restore it.',
      action: 'Restore the saved copy…',
      /** VoiceOver hint on the action. */
      actionHint: 'Replaces what is on this phone with the newest backup',
      /** The status line while the saved copy is being restored. */
      working: 'Restoring…',
      /** Banner title when restoring the saved copy failed; its message is a `backup.reasons` sentence. */
      failedTitle: 'The restore did not finish',
    },
    /**
     * Turn on found a recovery code already on this phone (one it could not
     * read earlier) and uses it instead of making a new one; shown above the
     * revealed code.
     */
    keptExistingCode: 'This phone already had a recovery code, so backup carries on with it instead of making a new one.',
    /** A restore stopped because this phone already backs up under a different recovery code. */
    accountAlreadyOnThisPhone:
      'This phone already backs up under another recovery code, so nothing was restored or changed. Show the recovery code to see which one.',
    /** A restore worked, but the keychain refused to keep the code, so backup is off. */
    restoredCodeNotKept:
      'Your inventory is back. This phone could not keep its recovery code, so backup is off until it is turned on again.',
  },
};
