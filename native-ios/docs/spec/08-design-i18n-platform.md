# 08: Copy and i18n, formatting, brand tokens, icons, haptics, motion, accessibility

Porting spec for the native iOS app (Swift 6, SwiftUI, iOS 26+, bundle id `com.wystudio.inventory`).
This area is the app's cross-cutting design layer: what it says, how it formats numbers and times, which colours and emoji are data, which icons it draws, how it vibrates and moves, and how it talks to VoiceOver.

All `path:line` citations are relative to `/home/walid/inventory-app/`. Copy is referenced by its key in `src/i18n/strings.ts`, written as `strings.<path>`.

---

## 0. Sources read

| File | Lines | Role |
|---|---|---|
| `src/i18n/strings.ts` | 1075 | All user-facing copy (537 static leaves, 157 function-valued) |
| `src/i18n/format.ts` | 55 | `plural`, `sentenceList`, `ago`, `longDate` |
| `src/ui/theme.ts` | 117 | Space palette, space icons, presets, `onColor`, `TYPE_ICON`, `MIN_TOUCH_TARGET`, `useTheme` |
| `src/ui/tokens.ts` | 179 | Colour tokens (light/dark), fixed colours, camera chrome, spacing, radii, sizes |
| `src/ui/color.ts` | 94 | `safeColor`, `rgb`, `toHex`, `mixHex`, `spaceTint`, `withAlpha`, `luminance`, `contrast` |
| `src/ui/typography.ts` | 127 | Type scale, Bold Text bump, font families |
| `src/ui/fontContext.ts` | 27 | Font-ready and Bold Text context |
| `src/ui/motion.ts` | 111 | Durations, delays, easings, reduce motion |
| `src/ui/haptics.ts` | 34 | Every haptic event |
| `src/ui/a11y.ts` | 47 | `spellCode`, `whereSpoken`, `quantitySpoken` |
| `src/ui/icons/glyphs.tsx` | 245 | 47 line glyphs |
| `src/ui/components/Icon.tsx`, `AppText.tsx`, `Button.tsx`, `IconButton.tsx`, `PressFeedback.tsx` | | Primitive components |
| `src/providers/FontProvider.tsx` | 79 | Atkinson font loading, Bold Text listener |
| `src/hooks/useLayoutScale.ts`, `useSpreadGap.ts` | 21, 34 | Large-text stacking, inline icon scale, tile gap maths |
| `assets/icon.png`, `assets/splash-icon.png`, `app.json` | | App icon, splash, Info.plist strings |

Also read where they matter: `src/db/migrations.ts:28-34,115-140`, `src/db/types.ts:56-67`, `src/db/constants.ts:26-27`, `src/ui/components/{SpaceTile,SpacePip,Tape,Mark,LocationLine,TabBar,QuantityStepper,Banner,TextField,CodeInput}.tsx`, `src/ui/components/pickers/{SwatchPicker,EmojiPicker,TypeGrid}.tsx`, `src/providers/ToastProvider.tsx`, `src/ui/container/containerRules.ts`, `src/ui/placeMatch.ts`, `app/_layout.tsx`, and every `haptics.*` call site.

---

## 1. Summary: what survives, what goes

| Concern | Keep (behaviour-bearing) | Drop or replace with stock iOS |
|---|---|---|
| Copy | Every string, word for word (en-GB spelling, curly quotes, `…`, `×`, `·`, NBSP) | `strings.ts` object becomes `Localizable.xcstrings` plus a typed Swift `L10n` facade |
| Formatting | `ago()` bucketing, `plural` one/other, en-GB `sentenceList` (no serial comma), en-GB long date | Hermes workarounds. Foundation exists, but `RelativeDateTimeFormatter` buckets differently (section 3.3) |
| Colours | Space palette hexes, drop-zone teal, fallback grey, `safeColor`, `onColor`, 24 % tint, QR black-on-white, brand tape yellow, ink as tint | The plaster/sheet/rule/graphite surface tokens become system semantic colours |
| Emoji | The 12 space emoji (exact code points) and their spoken names, the drop zone's `📥`, rendering whatever string is stored | |
| Icons | Container `visual_type` maps to an icon (data) | All 47 SVG glyphs become SF Symbols (section 5) |
| Type | Semantic roles (header, tabular digits, "where is never smaller than the name") | Atkinson Hyperlegible Next, `FontProvider`, manual Bold Text bump. The system font is used |
| Haptics | 9 named events and when they fire | `expo-haptics` becomes `.sensoryFeedback` or `UIFeedbackGenerator` |
| Motion | Reduce-motion semantics; timing delays (debounce, skeleton, toast life) | Most custom durations and easings. Use system animations |
| A11y | Labels, spelled codes, announcements, custom actions, focus moves, stacking at large text | RN live-region and TalkBack workarounds |

---

## 2. Copy: `strings.ts` to a String Catalog

### 2.1 Inventory

`strings` is a frozen nested object (`src/i18n/strings.ts:10-1075`, `as const`). It is English only and routed through one file "so adding a locale later is a data change" (`strings.ts:3-9`).

| Namespace | Line | Static | Functions | Namespace | Line | Static | Functions |
|---|---|---|---|---|---|---|---|
| `common` | 12 | 14 | 0 | `containerForm` | 468 | 13 | 11 |
| `tabs` | 28 | 8 | 1 | `container` | 514 | 8 | 4 |
| `boot` | 39 | 3 | 0 | `qr` | 531 | 20 | 6 |
| `a11y` | 45 | 9 | 5 | `link` | 575 | 5 | 8 |
| `entities` | 63 | 29 | 4 | `item` | 595 | 18 | 15 |
| `rows` | 117 | 5 | 9 | `editItem` | 643 | 6 | 0 |
| `where` | 141 | 4 | 0 | `move` | 653 | 12 | 7 |
| `quantity` | 148 | 12 | 5 | `photo` | 677 | 2 | 1 |
| `picker` | 172 | 10 | 4 | `add` | 683 | 30 | 5 |
| `forms` | 192 | 15 | 3 | `dropZone` | 728 | 5 | 1 |
| `errors` | 212 | 22 | 0 | `capture` | 739 | 20 | 9 |
| `connection` | 253 | 7 | 0 | `review` | 780 | 15 | 8 |
| `revoked` | 262 | 4 | 0 | `scan` | 820 | 10 | 0 |
| `permissions` | 268 | 13 | 0 | `deepLink` | 833 | 6 | 4 |
| `suggestions` | 285 | 18 | 2 | `settings` | 852 | 23 | 2 |
| `camera` | 310 | 5 | 1 | `household` | 883 | 20 | 12 |
| `home` | 318 | 22 | 3 | `join` | 926 | 12 | 2 |
| `search` | 370 | 5 | 8 | `backup` | 946 | 40 | 2 |
| `spaces` | 398 | 9 | 3 | `privacy` | 1006 | 28 | 1 |
| `spaceForm` | 416 | 19 | 10 | `onboarding` | 1059 | 11 | 1 |

The static count includes the lookup maps (`entities.typeNames` 8, `entities.colourNames` 6, `entities.iconNames` 12, `suggestions.failedBody` 9) and the array `onboarding.facts` (3).

Only `strings.entities.items` (`strings.ts:103`) has no caller in `src/` or `app/`. Every other key is used. Some keys are reached indirectly, so a plain grep for `strings.<key>` misses them:

- Aliases: `const copy = strings.privacy` (`app/privacy.tsx:41`), `const copy = strings.backup.reasons` (`src/ui/household/status.ts:52`) and `const copy = strings.settings.backupSummary` (`src/ui/household/status.ts:23`).
- Object spread: `src/ui/errors.ts` spreads whole groups into its result, `{ kind: 'conflict', ...strings.errors.conflict }` (`:49`), and the same for `errors.revoked` (`:66`), `errors.photo` (`:72`) and `errors.server` (`:74`). The code depends on these groups having the shape `{ title, body }`. The Swift facade should expose them as `(title: String, body: String)` pairs, for example `L10n.Errors.conflict`.

### 2.2 Key mapping

1. **Catalog key = the dotted TS path**, for example `tabs.home`, `entities.typeNames.box`, `onboarding.facts.0`. Keys stay stable, Jest assertions translate one to one, and grepping for a key finds both codebases.
2. **Source language**: `en`, with the British spellings kept as they are ("recognised", "colour"). Keep `CFBundleDevelopmentRegion = en`.
3. **Swift access**: a hand-written (or generated) `enum L10n` that mirrors the TS tree. Each member returns `String` via `String(localized: "tabs.home", defaultValue: "Home", comment: "...")` (`init(localized:defaultValue:table:bundle:locale:comment:)`, iOS 16+). Function-valued strings become `static func`s with the same parameter names, for example `L10n.Rows.itemA11y(name:where:quantity:)`. `where` works as an argument label, but it is a keyword, so give the parameter an internal name: `func itemA11y(name: String, where place: String, quantity: String)`. Xcode 26 can also generate Swift symbols for manually added catalog strings; verify the build setting, and either approach is fine.
4. **Return `String`, show with `Text(verbatim:)` or `Text(someString)`**. Do not pass copy that has user content in it through `LocalizedStringKey`. SwiftUI parses Markdown in `LocalizedStringKey` text, and names such as `*Spare* keys` must render literally.
5. **Lookup maps** (`typeNames`, `colourNames`, `iconNames`, `failedBody`) become one key per entry: `entities.typeNames.box`, `entities.colourNames.5B8DEF` (key on the upper-case hex without `#`), `entities.iconNames.sofa` (key on a slug, see section 4.3), `suggestions.failedBody.rate_limited` (keep the wire code as the suffix). Keep a Swift dictionary from data value to key, with the same fallbacks as TS (section 2.6).
6. **Arrays**: `onboarding.facts` becomes `onboarding.facts.0`, `.1`, `.2`, in that order (`strings.ts:1063-1067`). The matching icons are `['search', 'plus', 'scan']` (`app/onboarding.tsx:18`).
7. **Boolean-switched functions** (`offline`, `hasLabel`, `on`, `expanded`) become **two keys**: `<key>.offline` and `<key>.other`, or `<key>.withLabel` and `<key>`. String Catalogs can vary by plural and device, not by Bool.
8. **Format specifiers**: TS `number` becomes `%lld` (Swift `Int`), TS `string` becomes `%@`. Use positional `%1$@`, `%2$lld` when there is more than one argument. Counts are never grouped in TS (`${count}`), and neither is `%lld`, so "1234 items" stays "1234 items". Never use `.formatted()` for counts.
9. **Plurals**: `plural(count, one, other)` (`format.ts:10-12`) is `count === 1 ? one : other` with the number prefixed. English CLDR `one` matches exactly the integer 1, so String Catalog plural variations `one` and `other` are output-identical. Zero takes `other` ("0 items") in both. Do **not** rely on a `zero` variation for the special zero sentences. Branch in code (section 2.6).
10. **Several counts in one sentence** use String Catalog *substitutions*. Example for `home.summary`:

```json
"home.summary" : {
  "localizations" : { "en" : {
    "stringUnit" : { "state" : "translated", "value" : "%#@spaces@, %#@containers@ and %#@items@." },
    "substitutions" : {
      "spaces" : { "argNum" : 1, "formatSpecifier" : "lld", "variations" : { "plural" : {
        "one" :   { "stringUnit" : { "state" : "translated", "value" : "%arg space" } },
        "other" : { "stringUnit" : { "state" : "translated", "value" : "%arg spaces" } } } } },
      "containers" : { "argNum" : 2, "formatSpecifier" : "lld", "variations" : { "plural" : {
        "one" :   { "stringUnit" : { "state" : "translated", "value" : "%arg container" } },
        "other" : { "stringUnit" : { "state" : "translated", "value" : "%arg containers" } } } } },
      "items" : { "argNum" : 3, "formatSpecifier" : "lld", "variations" : { "plural" : {
        "one" :   { "stringUnit" : { "state" : "translated", "value" : "%arg item" } },
        "other" : { "stringUnit" : { "state" : "translated", "value" : "%arg items" } } } } }
    }
  } }
}
```

11. **`sentenceList`** (`format.ts:15-18`): `[]` gives `""`, `[a]` gives `a`, `[a, b]` gives `a and b`, `[a, b, c]` gives `a, b and c`. There is never a serial comma (en-GB). Every caller has a fixed number of parts, so bake the joiner into the format string ("`%#@a@ and %#@b@`", "`%#@a@, %#@b@ and %#@c@`"). If a runtime list is ever needed, use `items.formatted(.list(type: .and).locale(Locale(identifier: "en_GB")))`. With `en_US` it would add an Oxford comma, so pin the locale until real localisation lands.
12. **Generate the catalog with a script, not by hand.** Transpile `strings.ts` (TypeScript is in `node_modules`), walk the object, and emit `Localizable.xcstrings`: static leaves as `stringUnit` values, and function leaves from the tables below. Hand-copying 694 strings will introduce drift. Keep the script in `native-ios/tools/` and re-run it while RN Android and web still edit `strings.ts`. **Both apps share this copy until Android is ported**, so `strings.ts` stays the source of truth (open question Q1).

### 2.3 Characters that must survive byte-for-byte

Measured over `strings.ts`:

| Char | Code point | Count | Notes |
|---|---|---|---|
| `…` | U+2026 | 43 | Ellipsis on "opens a dialog" labels, e.g. `strings.rows.file`, `strings.item.delete` |
| `“` `”` | U+201C/D | 29 each | Around user names and queries (`strings.item.deleteTitle`) |
| `’` | U+2019 | 15 | Apostrophes (`strings.join.nameHint`) |
| `·` | U+00B7 | 6 | Separators (`strings.rows.separator` = `' · '`) |
| `×` | U+00D7 | 3 | `strings.rows.times`, `strings.search.total` |
| NBSP | U+00A0 | 2 | Only in `strings.where.notFiledYet` = `" · not filed yet"` (`strings.ts:145`). This keeps a wrapped line from starting or ending with the dot. Xcode's editor hides it, so check the JSON. |
| emoji | | 12 keys | `entities.iconNames` keys (section 4.3) |

`—` and `✓` appear only in comments.

### 2.4 Function-valued strings: simple templates (114)

These are plain interpolations with no branching. The catalog value is the exact English output with placeholders. Line numbers are in `src/i18n/strings.ts`.

| Key | Line | TS params | Catalog value (en) |
|---|---|---|---|
| `tabs.waitingA11y` | :37 | `count: number` | `%lld waiting` |
| `a11y.labelCode` | :47 | `spelled: string` | `label %@` |
| `a11y.labelCodeTitle` | :48 | `spelled: string` | `Label code %@` |
| `a11y.inPlace` | :49 | `space: string, container: string, spelled: string` | `In %1$@, %2$@, label %3$@` |
| `a11y.inSpace` | :51 | `space: string, spelled: string` | `In %1$@, label %2$@` |
| `a11y.availableAction` | :61 | `label: string` | `%@ available` |
| `rows.itemA11y` | :118 | `name: string, where: string, quantity: string` | `%1$@. %2$@. %3$@.` |
| `rows.quantity` | :119 | `count: number` | `Quantity %lld` |
| `rows.times` | :121 | `count: number` | `×%lld` |
| `rows.added` | :122 | `ago: string` | `Added %@` |
| `rows.spaceA11y` | :127 | `name: string, counts: string` | `%1$@. %2$@.` |
| `rows.fileA11y` | :137 | `name: string` | `File “%@”…` |
| `rows.deleteA11y` | :138 | `name: string` | `Delete “%@”` |
| `quantity.decrease` | :151 | `name: string` | `Decrease quantity of %@` |
| `quantity.increase` | :152 | `name: string` | `Increase quantity of %@` |
| `quantity.field` | :156 | `name: string` | `Quantity of %@` |
| `quantity.chipA11y` | :160 | `name: string, value: string` | `Quantity of %1$@, %2$@` |
| `picker.hereNowA11y` | :179 | `label: string` | `%@, here now` |
| `picker.optionA11y` | :180 | `label: string, space: string, spelled: string` | `%1$@, in %2$@, label %3$@` |
| `picker.newContainerIn` | :182 | `space: string` | `New container in %@…` |
| `picker.noMatch` | :185 | `query: string` | `No container matches “%@”.` |
| `forms.errorA11y` | :199 | `error: string` | `error: %@` |
| `forms.codeCounter` | :210 | `count: number, total: number` | `%1$lld of %2$lld characters` |
| `suggestions.refreshed` | :290 | `name: string` | `Details updated for “%@”` |
| `suggestions.stale` | :291 | `name: string` | `Title changed to “%@”` |
| `home.empty.paired.titleIn` | :358 | `household: string` | `Nothing is stored in %@ yet` |
| `search.total` | :383 | `name: string, count: number, places: number` | `“%1$@”: ×%2$lld in %3$lld places` |
| `search.totalNone` | :385 | `name: string, places: number` | `“%1$@”: none left in any of %2$lld places` |
| `search.totalName` | :387 | `name: string` | `“%@”:` |
| `search.totalIn` | :388 | `places: number` | `in %lld places` |
| `search.totalNoneIn` | :389 | `places: number` | `in any of %lld places` |
| `search.none.title` | :391 | `query: string` | `Nothing called “%@”` |
| `search.none.add` | :393 | `query: string` | `Add “%@”…` |
| `spaces.edit` | :408 | `name: string` | `Edit %@` |
| `spaces.noContainers.title` | :411 | `name: string` | `No containers in %@ yet` |
| `spaceForm.presetA11y` | :424 | `name: string` | `%@. Creates the space straight away.` |
| `spaceForm.presetAddedA11y` | :425 | `name: string` | `%@. Already added.` |
| `spaceForm.deleteTitle` | :441 | `name: string` | `Delete %@?` |
| `spaceForm.deleted` | :448 | `name: string` | `%@ was deleted.` |
| `spaceForm.alreadyDeleted` | :450 | `name: string` | `%@ was already deleted, probably on another phone.` |
| `spaceForm.created` | :458 | `name: string` | `%@ was added.` |
| `containerForm.inSpace` | :473 | `space: string` | `In %@` |
| `containerForm.codeStays` | :480 | `code: string` | `The label code stays %@, because it is printed on the label.` |
| `containerForm.deleteTitle` | :488 | `label: string` | `Delete %@?` |
| `containerForm.deleted` | :493 | `label: string` | `%@ was deleted.` |
| `containerForm.alreadyDeleted` | :495 | `label: string` | `%@ was already deleted, probably on another phone.` |
| `containerForm.created` | :503 | `label: string` | `%@ was added.` |
| `container.edit` | :515 | `label: string` | `Edit %@` |
| `container.crumbA11y` | :516 | `space: string` | `In %@. Opens the space.` |
| `qr.cardA11y` | :533 | `label: string, spelled: string` | `QR label for %1$@, label %2$@` |
| `qr.shareMessage` | :536 | `label: string, code: string` | `%1$@ (%2$@)` |
| `qr.none.title` | :553 | `label: string` | `No QR label on %@ yet` |
| `link.title` | :576 | `label: string` | `Scan the sticker for %@` |
| `link.replaceTitle` | :579 | `label: string` | `Replace the label on %@?` |
| `link.replaceBody` | :580 | `label: string` | `%@ already has a label. Its old sticker will stop opening it.` |
| `link.moveTitle` | :583 | `label: string` | `Move this sticker to %@?` |
| `link.moveBody` | :584 | `from: string, to: string` | `It opens %1$@ now. After this it opens %2$@ instead.` |
| `link.linked` | :587 | `label: string` | `Sticker linked to %@.` |
| `link.already` | :588 | `label: string` | `This sticker already opens %@.` |
| `link.notLinked` | :592 | `label: string` | `The sticker was not linked to %@. Try again.` |
| `item.photoA11y` | :596 | `name: string` | `Photo of %@. Opens it full screen.` |
| `item.nameIt.justNamed` | :609 | `name: string` | `It was just named “%@”.` |
| `item.nameIt.namedMeanwhile` | :611 | `name: string` | `It was just named “%@”. Save name again to keep yours.` |
| `item.nameIt.useName` | :613 | `name: string` | `Use “%@”` |
| `item.moveA11y` | :616 | `name: string` | `Move “%@”…` |
| `item.fileItA11y` | :619 | `name: string` | `File “%@”…` |
| `item.editDetailsA11y` | :622 | `name: string` | `Edit details of “%@”` |
| `item.stampAdded` | :623 | `date: string` | `Added %@.` |
| `item.stampChanged` | :624 | `ago: string` | `Last changed %@.` |
| `item.deleteA11y` | :626 | `name: string` | `Delete “%@”…` |
| `item.deleteTitle` | :627 | `name: string` | `Delete “%@”?` |
| `item.deleted` | :632 | `name: string` | `“%@” was deleted.` |
| `item.alreadyDeleted` | :634 | `name: string` | `“%@” was already deleted, probably on another phone.` |
| `move.titleMove` | :654 | `name: string` | `Move “%@”` |
| `move.titleFile` | :655 | `name: string` | `File “%@”` |
| `move.movedTo` | :658 | `container: string, space: string` | `Moved to %1$@ (%2$@).` |
| `move.filedIn` | :659 | `container: string, space: string` | `Filed in %1$@ (%2$@).` |
| `move.filedLast` | :661 | `container: string, space: string` | `Filed in %1$@ (%2$@). Everything is filed.` |
| `move.undoA11y` | :663 | `name: string` | `Undo moving %@` |
| `move.alreadyMoved` | :666 | `container: string` | `Someone already moved it to %@ on another device.` |
| `photo.a11y` | :679 | `name: string` | `Photo of %@` |
| `add.titleTo` | :686 | `container: string` | `Add to %@` |
| `add.saveA11y` | :709 | `container: string, space: string` | `Save in %1$@, %2$@` |
| `add.savedIn` | :711 | `container: string, space: string` | `Saved in %1$@ (%2$@).` |
| `add.undoA11y` | :716 | `name: string` | `Undo adding %@` |
| `capture.identified` | :749 | `count: number` | `%lld identified` |
| `capture.identifying` | :750 | `count: number` | `Identifying %lld…` |
| `capture.identifiedPartly` | :752 | `identified: number, unnamed: number` | `%1$lld identified · %2$lld to name` |
| `capture.intoContainerA11y` | :760 | `container: string, space: string, spelled: string` | `Photos go into %1$@, in %2$@, label %3$@` |
| `capture.intoSpaceA11y` | :762 | `space: string, spelled: string` | `Photos go into the container in %1$@, label %2$@` |
| `review.savedTo` | :783 | `count: number, container: string` | `%1$lld saved to %2$@` |
| `review.savedToDropZone` | :784 | `count: number` | `%lld saved to the drop zone` |
| `review.pending` | :788 | `count: number` | `Saving %lld more…` |
| `deepLink.replaceTitle` | :839 | `label: string` | `Replace the label on %@?` |
| `deepLink.replaceBody` | :840 | `label: string` | `%@ already has a label. Its old sticker will stop opening it.` |
| `deepLink.linked` | :843 | `label: string` | `Label linked to %@.` |
| `settings.joinedAs` | :856 | `name: string` | `Joined as “%@”` |
| `settings.schemaValue` | :868 | `version: number` | `v%lld` |
| `household.thisPhoneIs` | :888 | `name: string` | `This phone is “%@”` |
| `household.partOf` | :889 | `household: string` | `Part of %@.` |
| `household.lastUsed` | :892 | `ago: string` | `Last used %@` |
| `household.phoneA11y` | :895 | `name: string, meta: string` | `%1$@, %2$@` |
| `household.removeA11y` | :897 | `name: string` | `Remove %@` |
| `household.removeTitle` | :898 | `name: string` | `Remove “%@”?` |
| `household.removed` | :902 | `name: string` | `%@ was removed.` |
| `household.removeOffline` | :903 | `name: string` | `“%@” was not removed. Check the internet connection and try again.` |
| `household.joined` | :923 | `household: string` | `This phone is now part of %@.` |
| `household.server` | :924 | `host: string` | `Home server: %@` |
| `join.badChars` | :935 | `chars: string` | `That code has a character it never uses (%@). Check it with whoever set up the home server.` |
| `join.wrongLength` | :939 | `count: number` | `The code has 26 letters and numbers. This one has %lld.` |
| `backup.badChars` | :965 | `chars: string` | `That code has a character it never uses (%@). Check it against where you wrote it down.` |
| `backup.lastBackup` | :979 | `ago: string` | `Last backup %@` |
| `privacy.photosResized` | :1039 | `maxDimension: number` | `Importing a photo copies it; the original is left untouched. Each photo is resized to at most %lld pixels on its long edge and re-encoded as a WebP image before it is saved, alongside a small thumbnail used in lists.` |
| `onboarding.joinedBody` | :1073 | `household: string` | `Everything stored in %@ is on this phone now.` |

Notes on the simple ones:

- `search.total`, `search.totalNone`, `search.totalIn` and `search.totalNoneIn` always say "places". That is safe because a total only exists for a name kept in **two or more** places (`src/ui/home/__tests__/homeList.test.ts` "counts places, not items, and needs a second place"). Use a plural variation anyway when localising.
- `join.badChars` and `backup.badChars` receive the bad characters joined with a single space, each listed once, in order of first appearance. `invalidCodeChars` is `[...new Set([...normalised].filter(c => !/^[0-9A-HJKMNP-TV-Z]$/.test(c)))]` (`src/ui/code.ts:11,23-25`; `src/ui/household/join.ts:24`; `app/backup.tsx:151`). Test vector: `normaliseCode('MMWKU-M2H7%')` gives chars `U %` (`src/ui/household/__tests__/join.test.ts` "names characters no code uses before complaining about the length").
- `privacy.photosResized` is called with `MAX_IMAGE_DIMENSION = 1400` (`src/services/capture/imageScaling.ts:22`, `app/privacy.tsx:75`).
- `settings.schemaValue` is called with `LATEST_SCHEMA_VERSION` (`app/settings.tsx:122`).
- `join.wrongLength` hard-codes "26", the household code length.

### 2.5 Function-valued strings with logic (43)

Each row gives the exact English behaviour and the catalog plan. "Plural X" means a substitution with `one` and `other` variations on a `%lld` argument.

| Key (line) | Params | Exact English behaviour | Catalog plan |
|---|---|---|---|
| `entities.unnamedContainer` (:76) | `typeName: string` | `"Unnamed " + typeName.toLowerCase()`. Input is always `typeNames[visualType] ?? typeNames.other`, so "Unnamed box" … "Unnamed container" | **One key per visual type**: `entities.unnamedContainer.box` = `Unnamed box`, … `.other` = `Unnamed container`. Do not lowercase at runtime (this breaks languages with capitalised nouns). Callers: `containerRules.ts:32`, `WhereList.tsx:28`, `PlacePicker.tsx:84`, `PlaceRows.tsx:85` |
| `entities.items` (:103) | `count` | Plural "%lld item" / "%lld items" | Plural. Unused today, but keep as the shared building block |
| `entities.contents` (:105) | `count` | `0` gives `Empty`, otherwise plural item(s) | `entities.contents.empty` (static) plus `entities.items`. Branch in code |
| `entities.spaceCounts` (:107) | `containers, items` | `containers==0` gives `No containers yet` (items ignored). Else `items==0` gives `1 container, empty` or `N containers, all empty`. Else `N container(s) and M item(s)` | 3 keys: `.none` (static); `.empty` plural on containers (one `%lld container, empty`, other `%lld containers, all empty`); `.some` = `%#@containers@ and %#@items@` |
| `rows.addedShort` (:124) | `ago: string` | First character upper-cased: `just now` → `Just now`, `yesterday` → `Yesterday`, `5 minutes ago` unchanged | Have the relative-time formatter return a sentence-start variant (section 3.3, `capitalized: true`). Do not upper-case at runtime once localised. For now `prefix(1).uppercased() + dropFirst()` is identical for ASCII |
| `rows.containerA11y` (:128) | `label, type, spelled, items: string, hasLabel: bool` | `"<label>, <type>, label <spelled>. <items>" + (hasLabel ? ". Has a QR label" : "") + "."` | 2 keys: `rows.containerA11y` = `%1$@, %2$@, label %3$@. %4$@.`; `rows.containerA11y.withLabel` = `%1$@, %2$@, label %3$@. %4$@. Has a QR label.` |
| `quantity.notSavedNamed` (:166) | `name, offline` | offline: `The quantity of “<name>” was not saved. Check the connection and try again.`; else `… was not saved. Try again.` | `.offline` / `.other` |
| `forms.moreDetailsA11y` (:201) | `expanded` | `More details, expanded` / `More details, collapsed` | **RN workaround**: a native `DisclosureGroup` announces expanded or collapsed itself. Use `strings.forms.moreDetails` as the label. If the control stays custom, use 2 keys |
| `camera.torchState` (:312) | `on` | `Torch, on` / `Torch, off` | Prefer a `Toggle` labelled "Torch" (VoiceOver reads the state). Otherwise 2 keys `.on` / `.off` |
| `home.summary` (:321) | `spaces, containers, items` | `"<N space(s)>, <N container(s)> and <N item(s)>."` | Substitutions (example in 2.2) |
| `home.dropZone.title` (:336) | `count` | 1: `1 item is waiting in the drop zone`; else `<N> items are waiting in the drop zone` | Plural (one/other full sentences) |
| `search.summary` (:371) | `items, places` | Both 0: `Nothing found`. Else the non-zero parts joined by `sentenceList`, then ` found`: `3 items and 1 place found`, `1 item found`, `2 places found` | 4 keys: `.none`; `.items` plural `%lld item found` / `%lld items found`; `.places` plural; `.both` = `%#@items@ and %#@places@ found`. Pick in code |
| `spaces.count` (:400) | `spaces` | Plural `%lld space` / `%lld spaces` | Plural |
| `spaceForm.deleteBody` (:442) | `containers, items, labels` | `This also deletes <N container(s)> and <N item(s)>` + (labels ? `, and unlinks <N QR label(s)>` : ``) + `. This cannot be undone.` Both counts always appear, even 0. Callers use `deleteEmpty` when all three are 0 (`src/ui/spaces/spaceSetup.ts:64-72`) | 2 keys with substitutions: `.noLabels` = `This also deletes %#@containers@ and %#@items@. This cannot be undone.`; `.withLabels` = `This also deletes %#@containers@ and %#@items@, and unlinks %#@labels@. This cannot be undone.` (labels: `%arg QR label` / `%arg QR labels`) |
| `spaceForm.deleteFailed` (:451) | `name, offline` | `<name> was not deleted. Check the connection and try again.` / `… Try again.` | `.offline` / `.other` |
| `spaceForm.notCreated` (:459) | `name, offline` | `<name> was not added. …` | `.offline` / `.other` |
| `spaceForm.notSaved` (:463) | `name, offline` | `Changes to <name> were not saved. …` | `.offline` / `.other` |
| `containerForm.deleteBody` (:489) | `items, hasLabel` | `This also deletes <N item(s)>` + (hasLabel ? ` and unlinks its QR label` : ``) + `. This cannot be undone.` Used only when items > 0 (`spaceSetup.ts:75-79`) | 2 keys, plural items |
| `containerForm.deleteEmpty` (:491) | `hasLabel` | `This container is empty.` + (hasLabel ? ` Its QR label will be unlinked.` : ``) | 2 keys |
| `containerForm.deleteFailed` (:496) | `label, offline` | `<label> was not deleted. …` | `.offline` / `.other` |
| `containerForm.notCreated` (:504) | `offline` | `The container was not added. …` | `.offline` / `.other` |
| `containerForm.notSaved` (:508) | `label, offline` | `Changes to <label> were not saved. …` | `.offline` / `.other` |
| `container.sub` (:518) | `type: string, items` | `<type> · <N item(s)>`. The only caller shows the bare type name, not `sub`, once the loaded list is empty. `count` is the number of item rows, not the summed quantity: `items ? items.length : container.itemCount` (`app/container/[id]/index.tsx:263,282`) | `%1$@ · %2$#@items@` (plural items) |
| `container.empty.title` (:527) | `type: string` | `This <type lowercased> is empty`. Input is the type name, so "This box is empty" … "This container is empty" | **One key per visual type** (as `unnamedContainer`) |
| `qr.makeFailed` (:559) | `offline` | `The label was not made. …` | `.offline` / `.other` |
| `qr.replaceFailed` (:563) | `offline` | `The label was not replaced, so the old sticker still works. …` | `.offline` / `.other` |
| `qr.removeFailed` (:567) | `offline` | `The label was not removed, so the sticker still opens this container. …` | `.offline` / `.other` |
| `item.deleteFailed` (:636) | `offline` | `The item was not deleted. …` | `.offline` / `.other` |
| `item.progress` (:641) | `waiting` | 1: `Last one waiting`; else `<N> waiting` | Plural: one `Last one waiting`, other `%lld waiting` |
| `add.undoFailed` (:718) | `offline` | `It was not removed. …` | `.offline` / `.other` |
| `dropZone.intro2` (:731) | `count` | `<N item(s)> waiting for a place. Open one to name it, then file it.` | `%#@items@ waiting for a place. Open one to name it, then file it.` |
| `capture.savedUnnamed` (:755) | `count` | `<N> saved · name it later` (1) / `… name them later` | Plural, full strings |
| `capture.failedSome` (:756) | `count` | `<N> photo could not be saved. Nothing else was lost.` (1) / `photos` | Plural, full strings |
| `capture.flash` (:766) | `on` | `Flash, on` / `Flash, off` | As `camera.torchState` |
| `capture.doneA11y` (:771) | `count` | 0: `Done`; else `Done, <N photo(s)> taken` | 0 goes to `strings.capture.done`. Else `Done, %#@photos@ taken`. Branch in code |
| `review.savingTitle` (:786) | `count` | `Saving <N photo(s)>…` | `Saving %#@photos@…` |
| `review.toName` (:789) | `count` | 1: `1 still needs a name`; else `<N> still need a name` | Plural, full strings |
| `review.doneDropZone` (:795) | `count` | 1: `1 item is in the drop zone.`; else `<N> items are in the drop zone.` | Plural |
| `review.doneContainer` (:797) | `count, container` | `<N item(s)> added to <container>.` | `%1$#@items@ added to %2$@.` |
| `review.deleteFailed` (:804) | `offline` | Same text as `item.deleteFailed` | `.offline` / `.other` |
| `deepLink.linkFailed` (:845) | `offline` | `The label was not linked. …` | `.offline` / `.other` |
| `household.importNotice` (:907) | `spaces, items` | `Before it joined, this phone had its own inventory: <N space(s)> and <N item(s)>.` | Substitutions |
| `household.copied` (:915) | `items, photos` | `Copied <N item(s)> and <N photo(s)> into the household.` | Substitutions |

Every `.offline` / `.other` pair has the same shape: the `.other` sentence is the `.offline` sentence with "Check the connection and try again." replaced by "Try again." Callers decide `offline` from the error classifier (`describeError(...).kind === 'offline'`, owned by the errors area).

### 2.6 Strings that encode logic (keep the logic in Swift, not in the catalog)

1. **Type name lookups with fallbacks.** These must be preserved exactly because they differ by call site:
   - `typeNameOf(t) = typeNames[t] ?? typeNames.other ?? t`, so an unknown type reads "Container" (`src/ui/container/containerRules.ts:24-26`, `PlaceRows.tsx:75`).
   - `TypeGrid` uses `typeNames[t] ?? t` (`pickers/TypeGrid.tsx:42`). It only shows the 8 known types.
   - **Search matching uses the English type name**: `placeMatch.ts:50` builds a haystack from `name shortCode spaceName typeName`, where `typeName = typeNames[t] ?? ''`. Once localised, typing a type name matches in the current language. Keep that by calling the same `L10n` lookup. An unknown type adds `''` here, not "Container".
   - **Lookups are exact and case-sensitive.** A stored `visual_type` of `Box` is unknown: it reads "Container" and draws the `other` icon.
   - **The unnamed-container label also differs by call site.** `titleOf` treats a whitespace-only name as unnamed (`container.name?.trim() ? name : unnamedContainer(...)`, `src/ui/container/containerRules.ts:29-33`). `PlaceRows.tsx:85`, `WhereList.tsx:25-31` and `PlacePicker.tsx:83-90` use `name ?? unnamedContainer(...)`, so only `null` counts as unnamed there and `""` renders as an empty label. `labelOf` (`containerRules.ts:19-21`) falls back to the short code instead, for sentences such as toasts.
2. **Colour names** are looked up by `safeColor(swatch)` (upper-case `#RRGGBB`). A miss falls back to `strings.entities.currentColour` (`pickers/SwatchPicker.tsx:49-52`). Palette membership uses **`safeColor` equality** (`sameColor`, `:18-20`). So a stored `#5b8def` or `5B8DEF` counts as Blue: it is shown selected, named "Blue", and **not rewritten** to `#5B8DEF`. A stored value that is not in the palette after normalising is put first, selected, and named "Current colour" (`:33-34,47,50-51`). A junk value such as `blue` therefore shows as the grey fallback swatch `#8A948D`. Tapping the selected swatch does nothing (`:57`), so the stored string survives an edit unless another swatch is picked. A pick writes the palette constant verbatim (upper-case, with `#`).
3. **Icon names** are looked up by the exact emoji string. A miss falls back to `strings.entities.currentIcon` (`pickers/EmojiPicker.tsx:47`). See section 4.3 for the code points. The choice list is `offered = SPACE_ICONS + preset icons not already in SPACE_ICONS` (`:29-32`), then `choices = offered.includes(value) || !value.trim() ? offered : [value, ...offered]` (`:33`). Two edge cases follow. Membership uses the **untrimmed** stored string, so `" 🚗"` counts as a separate stored icon and is put first. A blank or whitespace-only stored icon adds no tile, so **no tile is selected**, because `selected = icon === value` (`:46`). JS compares UTF-16 code units. Swift `==` uses canonical equivalence, which is identical for these emoji. For bit-exact parity on arbitrary stored text, compare `Array(a.unicodeScalars) == Array(b.unicodeScalars)`.
4. **Recognition failure reasons** are keyed by **wire codes** from the recognition service: `not_configured`, `offline`, `timeout`, `rate_limited`, `server_error`, `malformed_response`, `unsupported_version`, `low_confidence`, `unrecognized` (`strings.ts:297-307`). Keep the wire string as the key suffix.
5. **Backup failure reasons** use camelCase keys (`strings.backup.reasons.*`, `strings.ts:990-1003`). `backupReason(reason)` (`src/ui/household/status.ts:51-75`) maps the service codes as follows:

   | Code | Key |
   |---|---|
   | `malformed` (UI-side code validation) | `backup.reasons.malformed` |
   | `offline` | `backup.reasons.offline` |
   | `timeout` | `backup.reasons.timeout` |
   | `unauthorized` | `backup.reasons.unauthorized` |
   | `not_found` | `backup.reasons.notFound` |
   | `quota_exceeded` | `backup.reasons.quotaExceeded` |
   | `too_large` | `backup.reasons.tooLarge` |
   | `corrupted` | `backup.reasons.corrupted` |
   | `not_configured` | `backup.reasons.notConfigured` |
   | `server_error`, `malformed_response`, `no_account`, anything else | `backup.reasons.other` |

   A raw code is never shown (tests in section 11). Use an exhaustive Swift `switch` with a `default` that returns `other`.
6. **Count branches**: `entities.contents` (0), `entities.spaceCounts` (0/0, n/0), `search.summary` (zero parts dropped), `capture.doneA11y` (0), `item.progress` (1), and `home.dropZone.title`, `review.toName`, `review.doneDropZone` (is/are, needs/need). Section 2.5 has the catalog form for each.
7. **Case transforms**: `rows.addedShort` (capitalise), `entities.unnamedContainer` and `container.empty.title` (lowercase). Section 2.5 replaces them with per-type keys or variants.
8. **Composition outside `strings.ts`**. Port these exactly:
   - Tab label with badge: `"\(label), \(L10n.Tabs.waitingA11y(badge))"` when `badge > 0`, else `label` (`src/ui/components/TabBar.tsx:130`). The visible badge reads `99+` above 99 (`TabBar.tsx:144`). The spoken label always uses the full count, so 150 is spoken as "Drop zone, 150 waiting".
   - Item stamp: `stampAdded(longDate(createdAt))`, then if `updatedAt - createdAt > 60_000` append `" " + stampChanged(ago(updatedAt, now))` (`src/ui/item/itemDetails.ts:151-160`). Example: "Added 2 September 2026. Last changed 3 days ago."
   - Search total line, drawn as three runs: `totalName(name)` + `" "` + bold `×N` (or `strings.quantity.noneLeftValue` in signal colour) + `" "` + `totalIn(places)` / `totalNoneIn(places)`. Its accessibility label is the whole sentence `search.total` / `search.totalNone` (`src/ui/home/TotalLine.tsx:13-31`). Natively, build an `AttributedString` or concatenate `Text`s.
   - Toast spoken text: `"\(message), \(L10n.A11y.availableAction(actionLabel))"` when there is an action (`src/providers/ToastProvider.tsx:170-172`).
   - Fast-capture status choice, with `pending = captured - completed` and `unnamed = completed - recognized`: pending > 0 gives `identifying(pending)`; unnamed == 0 gives `identified(recognized)`; recognized == 0 gives `savedUnnamed(unnamed)`; else `identifiedPartly(recognized, unnamed)` (`src/ui/capture/captureFlow.ts:26-41`; owned by the capture area).
   - Item row second line (`src/ui/components/ItemRow.tsx:71-110`). With `line == "where"` or no line kind, it draws the location line, not text. Otherwise:
     - `lead`: nothing when `count` is absent or `count == 1`; `strings.rows.noneLeft` in signal colour when `count == 0`; else `rows.times(count)`.
     - `when = ago(createdAt, now)`.
     - `rest`: `item.category` (may be null) when `line == "detail"`; else `rows.added(when)` when `count` is absent; else the bare `when` when `lead` is drawn; else `rows.addedShort(when)`.
     - The output is `lead + (lead && rest ? rows.separator : "") + rest`. Nothing is drawn when both are empty. Example: "×30 · 28 days ago".
   - Drop-zone option spoken as one label: `"\(strings.add.dropZone), \(strings.add.sortLater)"` (`src/ui/add/WhereList.tsx:80`) and `"\(strings.picker.dropZone), \(strings.picker.sortLater)"` (`src/ui/components/PlacePicker.tsx:459`).
   - Text field spoken label: `[accessibilityLabel ?? label, required ? strings.forms.required : nil, error.map(strings.forms.errorA11y)]`, with nils dropped, joined by `", "` (`src/ui/components/TextField.tsx:80-86`). Example: "What is it?, required, error: Give the item a name." The visible label appends `" " + strings.forms.optional` in secondary colour (`TextField.tsx:103-106`). The name field of a captured item uses `"\(strings.item.nameIt.a11y), \(errorA11y(error))"` (`src/ui/item/NameItInline.tsx:231-235`).
   - Container row second line: `qrToken != nil ? "\(contents) · \(strings.rows.qrLabel)" : contents` (`src/ui/components/PlaceRows.tsx:136`). A search location hit is spoken as `"\(title). \(subtitle)"` (`PlaceRows.tsx:203`).
   - Moving a sticker that also retires the target's own label: `"\(link.moveBody(from, to)) \(link.replaceBody(label))"` (`src/ui/container/containerRules.ts:113`).
   - Banner announcement: `title != nil ? "\(title). \(message)" : message` (`src/ui/components/Banner.tsx:61`).
9. **Unnamed placeholders**: an item with an empty or whitespace name shows `strings.entities.unnamedItem` ("Needs a name") (`ItemRow.tsx:51`). Many a11y strings have `…Unnamed` static twins, e.g. `strings.item.moveA11yUnnamed`.
10. **English copy outside `strings.ts`** that reaches the screen. These are not in the catalog today. Decide with Q1 and Q4 whether to localise them:
    - Space preset names `Garage`, `Wardrobe`, `Loft`, `Cellar` (`src/ui/theme.ts:57-62`). They become stored data (section 4.3).
    - The household name fallback `'Home'`, which appears three times: `src/ui/household/JoinForm.tsx:36`, `src/services/household/client.ts:99` (pairing response without a name) and `src/services/household/session.ts:24`. The last one runs when the **persisted session** is read back without a `householdName`. It feeds `household.partOf`, `household.joined`, `onboarding.joinedBody` and `home.empty.paired.titleIn`.
    - The device name fallback `'This phone'` (`src/services/household/session.ts:23`), also applied when the persisted session is parsed.
    - The drop-zone seed rows `'Drop zone'` (`src/db/migrations.ts:129,137`). This is stored data. The UI shows `strings.where.dropZone` instead (section 4.2).

### 2.7 InfoPlist strings

Put these in `InfoPlist.xcstrings`. The texts come from `app.json`:

| Key | Value source |
|---|---|
| `CFBundleDisplayName` | `Inventory` (`app.json:3`; same as `strings.onboarding.brand`) |
| `NSCameraUsageDescription` | `app.json:16` (also the expo-camera plugin, `app.json:55`) |
| `NSPhotoLibraryUsageDescription` | `app.json:17` |

Microphone permission is explicitly off (`app.json:56`). Do not add `NSMicrophoneUsageDescription`. The local prebuild `ios/Inventory/Info.plist`, which is git-ignored, confirms that only the camera and photo-library purpose strings ship.

Native note: the RN library flow calls `ImagePicker.launchImageLibraryAsync` and shows `strings.permissions.libraryDeniedBody` only when that call throws a permission error (`app/capture/index.tsx:353-364`). SwiftUI `PhotosPicker` runs out of process and needs no photo-library permission, so `libraryDeniedBody` becomes unreachable (keep the key in the catalog while Android still uses it). **Keep `NSPhotoLibraryUsageDescription` anyway:** the QR label share sheet offers Save Image for the label PNG, which writes to the photo library (`02-device-storage-migration.md` §9.4, `07-screens-entities.md` §5.3). *(Consistency pass: this note previously called the key optional.)*

---

## 3. Formatting (`src/i18n/format.ts`)

### 3.1 `plural(count, one, other)` (`format.ts:10-12`)

Returns `"\(count) \(count == 1 ? one : other)"`. Natively: String Catalog plural variations (section 2.2, item 9).

### 3.2 `sentenceList(parts)` (`format.ts:15-18`)

Covered in section 2.2, item 11.

### 3.3 `ago(ms, now = Date.now())` (`format.ts:20-44`)

Constants: `MINUTE = 60_000`, `HOUR = 3_600_000`, `DAY = 86_400_000` ms. Algorithm, in order:

```
diff = max(0, now - ms)                                // future times (clock skew) read "just now"
diff <  MINUTE            -> "just now"
diff <  HOUR              -> "<floor(diff/MINUTE)> minute(s) ago"
diff <  DAY               -> "<floor(diff/HOUR)> hour(s) ago"
diff <  2*DAY             -> "yesterday"                 // a 24-48 h window, NOT the calendar day
days = floor(diff/DAY)
days <  30                -> "<days> day(s) ago"
days <  365               -> "<floor(days/30)> month(s) ago"
else                      -> "<floor(days/365)> year(s) ago"
```

The unit is singular when the count is 1 (`unitsAgo`, `format.ts:24-26`).

Edge cases that follow from the buckets. Port them, do not "fix" them:

- Months are 30-day blocks below 365 days, so **360 to 364 days read "12 months ago"**. 365 days reads "1 year ago".
- 30 to 59 days read "1 month ago".
- "yesterday" covers 24 h ≤ diff < 48 h, whatever the calendar day.
- A future time reads "just now", because of the `max(0, …)` clamp.

**Do not use `RelativeDateTimeFormatter` or `Date.RelativeFormatStyle` directly.** They use calendar arithmetic, emit "weeks", and treat "yesterday" as a calendar day, so outputs would differ (for example 30 days reads "4 weeks ago" instead of "1 month ago"). Port the function as a pure `static func ago(_ ms: Int64, now: Int64) -> String` in integer epoch milliseconds, the same unit as the DB `created_at` / `updated_at` and the device `lastSeenAt`. Integer division then equals JS `Math.floor` for the non-negative `diff`. Add a `Date` convenience overload if needed, but do the bucketing in `Int64`. Back it with **new catalog keys** that are not in `strings.ts` today:

| New key | en value |
|---|---|
| `format.ago.justNow` | `just now` |
| `format.ago.yesterday` | `yesterday` |
| `format.ago.minutes` | plural `%lld minute ago` / `%lld minutes ago` |
| `format.ago.hours` | plural `%lld hour ago` / `%lld hours ago` |
| `format.ago.days` | plural `%lld day ago` / `%lld days ago` |
| `format.ago.months` | plural `%lld month ago` / `%lld months ago` |
| `format.ago.years` | plural `%lld year ago` / `%lld years ago` |

Also add sentence-start variants (`Just now`, `Yesterday`) or a `capitalized:` flag for `rows.addedShort`.

Where it is used: `ItemRow.tsx:93`, `itemDetails.ts:158`, `household/status.ts:81` (`Last used …`), `app/backup.tsx:304` (`Last backup …`).

**Time source.** `useNow(intervalMs = 60_000)` re-renders every 60 s while the screen is focused and catches up immediately on refocus, with a `setTimeout(tick, 0)` on focus (`src/hooks/useNow.ts:11-28`). Only four screens tick: `app/(tabs)/drop-zone.tsx:77`, `app/backup.tsx:291`, `app/household.tsx:378` and `app/item/[id]/index.tsx:94`. Every other `ago` caller passes no `now`, so `ago` defaults to `Date.now()` at render and does not age until something else re-renders it. Examples are item rows on Home's "Recently added" and on Review. Natively, use `TimelineView(.periodic(from: .now, by: 60))` (or `.everyMinute`) around ageing text on those four screens. Elsewhere, computing at render matches today. SwiftUI pauses timelines for off-screen views, which matches "a screen in the background does not tick".

**Why it was hand-written**: "Hermes does not guarantee `Intl.RelativeTimeFormat`" (`format.ts:31`). That reason is gone natively, but bucket identity is the reason to keep it.

### 3.4 `longDate(ms)` (`format.ts:46-55`)

`Intl.DateTimeFormat('en-GB', { day: 'numeric', month: 'long', year: 'numeric' })` gives `2 September 2026`, in the **device time zone**, with the **locale pinned to en-GB**.

Swift: `Date(timeIntervalSince1970: Double(ms) / 1000).formatted(Date.FormatStyle(locale: Locale(identifier: "en_GB"), calendar: Calendar(identifier: .gregorian), timeZone: .current).day().month(.wide).year())`. **Pin the calendar as well as the locale.** `Date.FormatStyle` defaults `calendar` to `.autoupdatingCurrent`, and `.locale(_:)` does not change it. A device set to the Buddhist or Japanese calendar would otherwise print a different year or era. Hermes `Intl.DateTimeFormat('en-GB')` always uses Gregorian. Pinning en_GB is identical to today. Following the device locale ("September 2, 2026" in en_US) is a product decision (open question Q2). Only used by the item stamp (`itemDetails.ts:156`).

### 3.5 Numbers

There is no number formatting anywhere: every count is interpolated raw (`${count}`), with no grouping and no locale digits. `%lld` matches. The quantity range is 0 to 9999 (`src/core/quantity.ts:8-9`). `rows.times` gives `×12`. The tab badge caps at the literal string `99+`.

### 3.6 Codes (owned elsewhere, noted for copy)

`spellCode` (section 9.1) and `formatCode` (groups of 5 joined by `-`, `src/ui/code.ts:28-30`) shape what is shown and spoken. Household and recovery codes are Crockford base32 (`src/ui/code.ts:11`). Container short codes use `23456789ABCDEFGHJKLMNPQRSTUVWXYZ` (`src/core/shortCode.ts:7`), which has no 0, 1, I or O, so the system font is legible enough for them.

---

## 4. Colours, emoji and icons: data versus decoration

### 4.1 Brand accent

The design has **two** brand colours with distinct jobs (`src/ui/tokens.ts:1-13`, `src/ui/components/Tape.tsx:34-37`):

| Role | Light | Dark | Rule |
|---|---|---|---|
| **Ink**: the interactive tint (primary buttons, selection bars, navigation `primary`) | `#1C211E` | `#E8ECE8` | React Navigation `primary = colors.ink` (`app/_layout.tsx:46`). Primary is the only filled control (`Button.tsx:56-64`). Text on ink is `#FFFFFF` light / `#1C201E` dark (`onInk`) |
| **Tape yellow**: the label tape, the brand mark, badge, toast action, camera accent | `#FFD23F` | `#F4CA3C` | "The one loud thing in the design, so yellow is never used on a button or a selection" (`Tape.tsx:34-37`). Text on tape is always `#1D1A0E` (`tapeInk`, both schemes) |

**Recommendation**: set the asset catalog `AccentColor` to **ink** (light `#1C211E`, dark `#E8ECE8`). That reproduces today's tint and keeps `.borderedProminent` buttons legible with white or dark labels. Define a named colour **`Tape`** (`#FFD23F` / `#F4CA3C`) with `TapeInk` `#1D1A0E` for the code tape (`Tape.tsx`), the brand mark (`Mark.tsx`), the tab badge (`TabBar.tsx:143-144`), the camera selected accent and the locked scan reticle. Yellow as a SwiftUI tint would fail contrast (about 1.4:1 on white). This is open question Q3 for the user, who said "keep only the brand accent".

The camera's fixed accent is `#FFD23F` (`tokens.ts:125`). The toast action in dark mode uses `#7A5B00` for contrast on a light toast (`tokens.ts:85`).

### 4.2 Data-bearing colours (stored in `spaces.color`)

`spaces.color TEXT NOT NULL DEFAULT '#5B8DEF'` (`src/db/migrations.ts:33`). The value is any string written by this app, older builds, the desk (`home-server/src/inventory.ts:84-107` accepts any non-empty string) or the importer (fallback `'#5B8DEF'`, `home-server/src/importer.ts:33`). It must render identically.

**Palette offered** (`src/ui/theme.ts:38-45`), in this order, with spoken names (`strings.ts:78-85`):

| # | Hex | `strings.entities.colourNames` | Contrasting foreground `onColor` |
|---|---|---|---|
| 0 | `#5B8DEF` | Blue | `#12161C` (test asserts; 5.62 vs 3.23 for white) |
| 1 | `#2E9E4F` | Green | `#12161C` (5.29 vs 3.43) |
| 2 | `#E4572E` | Orange | `#12161C` (4.93 vs 3.68) |
| 3 | `#B15BEF` | Purple | `#12161C` (4.85 vs 3.74) |
| 4 | `#E0A800` | Amber | `#12161C` (8.44 vs 2.15) |
| 5 | `#0F9BB0` | Teal | `#12161C` (5.47 vs 3.31) |

All six palette entries and the fallback grey resolve to `#12161C`. These values were computed by running `onColor` from `theme.ts`, and they make good Swift test vectors.

**System colours stored as data:**

- Drop zone space: `color = '#0F9BB0'`, `icon = '📥'`, name `'Drop zone'`, `kind = 'system'`, id `drop-zone-space`. Its container is id `drop-zone`, name `'Drop zone'`, `visual_type = 'other'`, `short_code = 'DROP-ZONE'` (`migrations.ts:127-139`, `src/db/constants.ts:26-27`). **The UI never shows the stored teal or code for it.** It always draws the tray icon and the words `strings.where.dropZone` (`src/ui/components/LocationLine.tsx:89-98,113-132`), and speaks `strings.a11y.inDropZone` (`src/ui/a11y.ts:36-42`).
- Fallback for unparseable values: `#8A948D` (`color.ts:11`, mirrors `tokens.ts:102`).

**`safeColor(value)`** (`color.ts:15-23`) is pure and must match exactly:

```
s = (value ?? "").trim()                                  // JS trim: Unicode whitespace incl. NBSP and U+FEFF
match ^#?([0-9a-f]{3}|[0-9a-f]{4}|[0-9a-f]{6}|[0-9a-f]{8})$  case-insensitive
no match              -> "#8A948D"
3 or 4 hex digits     -> double each of the FIRST THREE digits (alpha dropped)
6 or 8 hex digits     -> first six digits (alpha dropped)
return "#" + uppercased
```

`Swift.trimmingCharacters(in: .whitespacesAndNewlines)` does not strip U+FEFF, but it does strip U+0085 (NEL), which JS `trim()` keeps. For identity, use the JS set exactly: U+0009, U+000A, U+000B, U+000C, U+000D, U+0020, U+00A0, U+1680, U+2000 to U+200A, U+2028, U+2029, U+202F, U+205F, U+3000 and U+FEFF. The same `jsTrim` serves `spellCode` and the space-tile glyph.

**Hex digits must be ASCII only.** JS `[0-9a-f]` with the `i` flag matches only ASCII. Swift `Character.isHexDigit` also accepts fullwidth forms such as `０`–`９` and `Ａ`–`Ｆ`, so do not use it. Match on `unicodeScalars` in `0x30...0x39`, `0x41...0x46` and `0x61...0x66`, or use a Swift `Regex` with an ASCII-only class. Extra vectors, computed from the TS: `"\u{FEFF}#5B8DEF"` gives `#5B8DEF`; `"\u{00A0}#5b8def\u{00A0}"` gives `#5B8DEF`; `"abc"` and `"ABCD"` give `#AABBCC`; `"#5B8DEFF"` (7 digits) gives `#8A948D`.

**`onColor(hex)`** (`theme.ts:64-80`): returns `"#FFFFFF"` if `contrast("#FFFFFF", hex) >= contrast("#12161C", hex)`, else `"#12161C"`. Note `#12161C` is **not** the ink token. It is used for the check mark on the selected swatch (`SwatchPicker.tsx:74`).

**Luminance and contrast** (`color.ts:80-94`): WCAG 2.x. Channel `c/255`; if `<= 0.03928` then `/12.92`, else `((c+0.055)/1.055)^2.4`. `L = 0.2126 R + 0.7152 G + 0.0722 B`. Ratio `(max+0.05)/(min+0.05)`.

**Tint and edge for space tiles** (`color.ts:46-77`, `SpaceTile.tsx:38-41`):

- Fill = `mixHex(color, surface, 0.24)`: per-channel `round(a*0.24 + b*0.76)`, clamped 0 to 255, with JS `Math.round` (half up; Swift `.rounded()` gives the same for positives). It is blended against the opaque surface the tile sits on: `surface` is `'sheet'` by default or `'plaster'` (`SpaceTile.tsx:23,35-41`). The callers that pass `plaster` are the space header (`app/space/[id]/index.tsx:152`) and taken presets (`app/space/new.tsx:114`). Natively, `Color(hex).opacity(0.24)` over an **opaque** surface gives nearly the same pixels, within about 1/255 because compositing happens in the display colour space. Over Liquid Glass or materials it does not, so tiles need an opaque backing. The system surfaces also differ from the RN ones (dark `secondarySystemGroupedBackground` is `#1C1C1E`, not `#1C201E`), so dark tints shift slightly. That is acceptable for decoration.
- Reference tints, computed from `spaceTint` (useful only if the RN surfaces are kept for a parity test):

  | Colour | on light sheet `#FFFFFF` | on light plaster `#E9ECE7` | on dark sheet `#1C201E` | on dark plaster `#141715` |
  |---|---|---|---|---|
  | `#5B8DEF` | `#D8E4FB` | `#C7D5E9` | `#2B3A50` | `#253349` |
  | `#2E9E4F` | `#CDE8D5` | `#BCD9C3` | `#203E2A` | `#1A3723` |
  | `#E4572E` | `#F9D7CD` | `#E8C8BB` | `#4C2D22` | `#46261B` |
  | `#B15BEF` | `#ECD8FB` | `#DCC9E9` | `#402E50` | `#3A2749` |
  | `#E0A800` | `#F8EAC2` | `#E7DCB0` | `#4B4117` | `#453A10` |
  | `#0F9BB0` | `#C5E7EC` | `#B5D9DA` | `#193E41` | `#13373A` |
  | `#8A948D` (fallback) | `#E3E5E4` | `#D2D7D1` | `#363C39` | `#303532` |
- Edge = `withAlpha(color, 0.45)`: `safeColor` + `byte(round(0.45*255)) = 0x73`, i.e. a 1 pt border at 45 % alpha.
- The ring on pips and swatches is `rgba(0,0,0,0.12)` light / `rgba(255,255,255,0.16)` dark (`tokens.ts:58,90`), so a white or black space stays visible.
- The cache of 256 entries (`color.ts:53-71`) is a JS performance detail. It is optional natively.

**Space pip** (`SpacePip.tsx`): a dot sized 10, 12 or 14 in `safeColor(color)` with a 1 pt ring. It is decorative; the name always follows, so colour never carries meaning alone (`SpacePip.tsx:12-18`).

### 4.3 Data-bearing emoji (stored in `spaces.icon`)

`spaces.icon TEXT NOT NULL DEFAULT 'cube'` (`migrations.ts:32`). The importer also falls back to `'cube'` (`home-server/src/importer.ts:32`). The stored value is "an emoji, several, letters, or nothing" (`SpaceTile.tsx:18-19`).

**Offered icons**: `SPACE_ICONS` (`theme.ts:47`) in order, then preset icons not already listed (`EmojiPicker.tsx:29-32`), then, if the stored value is non-empty and in neither list, **the stored value first, selected** (`EmojiPicker.tsx:33`). Exact code points (verified from source bytes):

| Order | Emoji | Code points | Spoken (`strings.entities.iconNames`) | Suggested catalog slug |
|---|---|---|---|---|
| 1 | 🛋️ | U+1F6CB U+FE0F | Sofa | `sofa` |
| 2 | 🍳 | U+1F373 | Pan | `pan` |
| 3 | 🛏️ | U+1F6CF U+FE0F | Bed | `bed` |
| 4 | 🚗 | U+1F697 | Car | `car` |
| 5 | 🧰 | U+1F9F0 | Toolbox | `toolbox` |
| 6 | 📚 | U+1F4DA | Books | `books` |
| 7 | 🧺 | U+1F9FA | Basket | `basket` |
| 8 | 🏠 | U+1F3E0 | House | `house` |
| 9 | 🪴 | U+1FAB4 | Plant | `plant` |
| 10 | 🎒 | U+1F392 | Backpack | `backpack` |
| 11 (preset only) | 👕 | U+1F455 | Shirt | `shirt` |
| 12 (preset only) | 🚪 | U+1F6AA | Door | `door` |
| (system) | 📥 | U+1F4E5 | (drop zone, never offered) | |

**Swift trap**: `"🛋️" == "🛋"` is **false** (U+FE0F is not canonically equivalent to nothing). Store, compare and look up names with the exact strings above. Never normalise them.

**Rendering rules** (`SpaceTile.tsx:35-78`):

- `glyph = (icon ?? "").trim()` with JS `trim` semantics (see `jsTrim` in 4.2). Trimming affects drawing only; the stored value is never rewritten. If non-empty, draw it as text, one line, **clipped** (not truncated with an ellipsis) when several characters are stored, **not scaled with Dynamic Type** (`allowFontScaling={false}`), in ink colour (letters need ink; emoji ignore it).
- Font size by tile size: 32 → 17, 48 → 24, 56 → 28, 64 → 34. Line height `round(size*1.2)`. Tile corner radius 7, 9, 10, 12.
- An empty glyph draws the `home` glyph (SF Symbol `house`) at half the tile size in secondary colour.
- `'cube'` (the schema default) renders literally as the letters "cube", clipped. Keep that (open question Q5).
- The tile is decorative (hidden from VoiceOver).

**Presets** (`theme.ts:57-62`), one tap to create, in order:

| Name | Icon | Colour |
|---|---|---|
| Garage | 🚗 | `#5B8DEF` |
| Wardrobe | 👕 | `#B15BEF` |
| Loft | 🏠 | `#E4572E` |
| Cellar | 🚪 | `#E0A800` |

Preset names are English literals in `theme.ts`, **not** in `strings.ts`. They become stored space names. Open question Q4: localise them or not. Defaults for a new custom space: name `''`, icon `SPACE_ICONS[0]` (🛋️), colour `SPACE_COLORS[0]` (`app/space/new.tsx:42`).

### 4.4 Data-bearing icons: container `visual_type`

`containers.visual_type TEXT NOT NULL DEFAULT 'box'` (`migrations.ts:42`). Known values, in picker order (`src/db/types.ts:56-65`): `box, drawer, shelf, cabinet, bin, bag, crate, other`. The match is exact and case-sensitive. An unknown stored value falls back to `other`, both for the icon (`theme.ts:86-95`, `SpaceTile.tsx:109`, `pickers/TypeGrid.tsx:67`, `app/container/[id]/index.tsx:324`) and for the name ("Container"). The glyph-to-SF-Symbol mapping is in section 5 (rows marked **DATA**). Names come from `strings.entities.typeNames.*`. New containers default to `'box'` (`app/container/new.tsx:29`). The desk accepts any non-empty string (`home-server/src/inventory.ts:131-137`).

**Unknown types survive an edit.** The edit form loads `stored.visualType` unchanged (`app/container/[id]/edit.tsx:84`). With an unknown value, `TypeGrid` selects **no** tile, because `selected = type === value`. `containerValuesChanged` compares the raw strings (`src/ui/spaces/spaceSetup.ts:101-107`), so saving without touching the type writes the original string back. Natively, keep `visualType` as `String` in the model and the form, not as a closed Swift enum that would coerce unknown values.

The `TypeGrid` picker uses 72 pt tiles, four per row, or three when the **window** width is below `NARROW_WIDTH = 360`. It spreads with `spreadGap(width, 72, 8, columns)` (`pickers/TypeGrid.tsx:11,28-29`). Only the selected tile shows its name underneath, but every tile keeps room for the name, so the grid never shifts (`:20-25,69-78`). Each tile is a radio with label `typeNames[type] ?? type`.

### 4.5 Decorative tokens: native replacement

These carry no data. The native look drops them for system semantic colours. Contrast tests (section 11) assert AA for the custom pairs; system colours meet it by construction.

| Token (`tokens.ts` line) | Light / Dark | Native replacement |
|---|---|---|
| `plaster` (17/64) | `#E9ECE7` / `#141715` | `Color(.systemGroupedBackground)` |
| `sheet` (19/65) | `#FFFFFF` / `#1C201E` | `Color(.secondarySystemGroupedBackground)` |
| `sheet2` (21/66) | `#F3F5F2` / `#242926` | `Color(.tertiarySystemFill)` / `.quaternary` fills |
| `selected` (23/67) | `#E4EBE2` / `#2B332E` | System list selection, Picker checkmarks |
| `pressed`, `ripple`, `inkPressed` | | Dropped. Button styles handle press states |
| `ink` (28/70) | `#1C211E` / `#E8ECE8` | `.primary` text; the **AccentColor** for tint (4.1) |
| `onInk` (32/72) | `#FFFFFF` / `#1C201E` | Automatic on `.borderedProminent` |
| `graphite` (33/73) | `#59625C` / `#A3ACA5` | `.secondary` |
| `rule`, `ruleStrong`, `control` | | `Color(.separator)`, `.opaqueSeparator`; stock control borders |
| `tape`, `tapeInk` | see 4.1 | **Keep** as the named brand colours |
| `mark` (43/79) | `#FFE48C` / `#5D5327` | Search-match highlight background (`AppText.tsx:128-145`). Keep as a named colour, or use the system `.findHighlight` look |
| `numberFocus` | `#FFF5D5` / `#4C4525` | Dropped (the stepper field focus wash) |
| `signal` (46/81) | `#B3361A` / `#FF9573` | `Color.red` / `role: .destructive`; error text `.red` |
| `signalWash` | `#FBECE7` / `#3A231C` | Error banner background; use `.red.opacity(0.12)` or a system banner |
| `toast*` | | Toast is custom (feedback area). Native suggestion: material capsule; action in tape or `toastAction` |
| `scrim`, `shadowFloat` | | Dropped (system sheets and shadows) |
| `pipRing` | see 4.2 | **Keep** for pips and swatches |
| `fixed.qrPaper` / `qrInk` (104-105) | `#FFFFFF` / `#000000` | **Keep**: the QR card is black on white in both schemes "so every scanner reads it" |
| `fixed.photoBackdrop` | `rgba(12,14,13,0.96)` | `Color.black` |
| `fixed.tapeBevel*` | inset shadows | Optional subtle `.shadow` / overlay stroke on tape |
| `camera.*` (119-129) | bg `#000`, ink `#FFF`, chip `rgba(12,14,13,0.62)`, selected `rgba(255,255,255,0.22)`, accent `#FFD23F`, errorBar `#FF9573`, reticle `rgba(255,255,255,0.85)` | Camera chrome ignores the scheme. Native: Liquid Glass or `.ultraThinMaterial` chips over the preview, white glyphs, tape-yellow when a toggle is on or the reticle is locked. The error bar colour stays because coral text on a bright scene measures 2.54:1 (`tokens.ts:114-118`) |
| `space.*`, `radius.*`, `ROW_*`, `THUMB*`, `TAB_BAR_CONTENT`, `BOTTOM_BAR_PADDING` (131-175) | | Dropped (native list metrics). Thumbnails 56, 76, 88, 48 can stay as hints for the item-row area |
| `GUTTER = 16` (157) | | System list insets |
| `CONTENT_MAX_WIDTH = 640` (159) | | Keep for iPad: `.frame(maxWidth: 640)` or readable content width |
| `MIN_TOUCH_TARGET = 48` (`theme.ts:106`) | | iOS minimum is 44 pt. Stock controls comply. Custom tappables need `.frame(minWidth: 44, minHeight: 44)` + `.contentShape(Rectangle())` |

**Scheme**: follows the system with no in-app override (`theme.ts:108-117`; `app.json:9` `userInterfaceStyle: automatic`).

---

## 5. Icons: glyphs to SF Symbols

Today every icon is a 24×24 SVG line glyph with a 1.75 stroke, round caps and joins, and no fill. The active tab uses stroke 2 (`glyphs.tsx:4-12`, `Icon.tsx:10-43`). Sizes are 16, 20, 24 or 28 in chrome. **Icons are always decorative**: hidden from accessibility, with the control owning the label (`Icon.tsx:19-24`).

Natively: `Image(systemName:)` with `.symbolRenderingMode(.monochrome)`, `.fontWeight(.regular)`. Selected states use `.symbolVariant(.fill)` (TabView does this automatically). In a `Label` or `Button` the symbol scales with Dynamic Type. Hide decorative standalone images with `.accessibilityHidden(true)`.

Confidence: **✓** = present since SF Symbols 1 to 3, certain. **?** = believed present (SF Symbols 4+), verify in the SF Symbols 7 app before use. The fallback is a certain alternative.

| Glyph (`glyphs.tsx` line) | Used for (examples) | SF Symbol | Conf. | Fallback / note |
|---|---|---|---|---|
| `search` (:14) | search field, onboarding fact 1 (`SearchField.tsx:86`, `onboarding.tsx:18`) | `magnifyingglass` | ✓ | `.searchable` draws its own |
| `close` (:20) | banner, toast, scanner, photo viewer, sheet close (`Toast.tsx:144`, `photo.tsx:220`) | `xmark` | ✓ | iOS 26 `Button(role: .close)` draws it (verify) |
| `back` (:21) | add-flow step back, onboarding (`item/new.tsx:601`) | `chevron.backward` | ✓ | The navigation back button is automatic |
| `lock` (:22) | code input trailing (`CodeInput.tsx:63`) | `lock` | ✓ | |
| `menu` (:28) | **unused** | `line.3.horizontal` | ✓ | Do not port |
| `minus` (:29) | stepper (`QuantityStepper.tsx:143`) | `minus` | ✓ | |
| `plus` (:30) | stepper, Add tab, "new" buttons (`TabBar.tsx:198`) | `plus` | ✓ | |
| `edit` (:31) | edit buttons (`item/[id]/index.tsx:401`) | `pencil` | ✓ | |
| `move` (:37) | Move / File it (`WhereCard.tsx:74`, `ItemRow.tsx:258`) | `folder` | ✓ | iOS convention for "Move" (Files, Mail). Literal look: `rectangle.portrait.and.arrow.forward` (?) |
| `home` (:43) | Home tab; empty space tile (`TabBar.tsx:21`, `SpaceTile.tsx:74`) | `house` | ✓ | |
| `inbox` (:49) | **Drop zone**: tab, location line, picker row, camera "Into" pill (`TabBar.tsx:24`, `LocationLine.tsx:117`) | `tray` | ✓ | Matches the 📥 meaning; `tray.and.arrow.down` (✓) is an option |
| `photo` (:55) | thumbnail placeholder (`Thumb.tsx:33`) | `photo` | ✓ | |
| `box` (:62) | **DATA** `visual_type=box`; "New container" (`space/[id]/index.tsx:188`) | `shippingbox` | ✓ | |
| `drawer` (:68) | **DATA** `drawer` (one divider and two handles, so two stacked drawers) | `tray.2` | ✓ | Reads as stacked drawers. Alternative `rectangle.split.1x2` (✓). The SF Symbols 4 `cabinet` symbol may also be drawn as stacked drawers. Check it in the SF Symbols app before choosing between `drawer` and `cabinet` |
| `shelf` (:74) | **DATA** `shelf` | `books.vertical` | ✓ | Alternative `square.split.1x2` (✓) |
| `cabinet` (:80) | **DATA** `cabinet` (two doors with vertical handles) | `cabinet` | ? | Fallback `square.split.2x1` (✓). If SF `cabinet` turns out to show drawers (see `drawer`), use the fallback here so the two types never share a symbol |
| `bin` (:86) | **DATA** `bin` (lidded storage bin) | `archivebox` | ✓ | Never `trash` (that means delete) |
| `bag` (:92) | **DATA** `bag` | `bag` | ✓ | |
| `crate` (:98) | **DATA** `crate` (slatted; the drawn glyph is a 3 × 3 grid of two horizontal and two vertical slats) | `square.grid.3x2` | ✓ | `square.grid.3x3` (✓, SF Symbols 2) matches the drawn glyph more literally; `basket` (?) is more literal still |
| `other` (:104) | **DATA** `other` / unknown types (tag) | `tag` | ✓ | |
| `spaces` (:112) | Spaces tab, empty state (`TabBar.tsx:22`) | `square.split.bottomrightquarter` | ? | Floor-plan look. Fallback `square.grid.2x2` (✓) |
| `camera` (:118) | take photo, permission screen (`container/[id]/index.tsx:354`) | `camera` | ✓ | |
| `gallery` (:124) | choose from library (`capture/index.tsx:519`) | `photo.on.rectangle` | ✓ | `PhotosPicker` label |
| `scan` (:131) | Scan tab, onboarding fact 3 (`TabBar.tsx:23`) | `qrcode.viewfinder` | ✓ | |
| `qr` (:134) | QR label actions (`container/[id]/qr.tsx:283`) | `qrcode` | ✓ | |
| `settings` (:142) | settings entry (`(tabs)/index.tsx:415`) | `slider.horizontal.3` | ✓ | The iOS convention is `gearshape` (✓). Pick one (Q6) |
| `flash` (:149) | capture flash on (`capture/index.tsx:438`) | `bolt` | ✓ | `bolt.fill` when on |
| `flashOff` (:150) | capture flash off | `bolt.slash` | ✓ | |
| `torch` (:156) | scanner torch toggle (`QrScanner.tsx:196`) | `flashlight.off.fill` / `flashlight.on.fill` | ✓ | Swap by state |
| `keyboard` (:162) | "Type it instead" (`QrScanner.tsx:221`, `CameraChrome.tsx:201`) | `keyboard` | ✓ | |
| `chevronRight` (:168) | row disclosure, crumb (`Row.tsx:99`) | `chevron.right` | ✓ | `NavigationLink` draws it |
| `chevronDown` (:169) | expanders, quantity chip (`SettingsRow.tsx:62`, `QuantityChip.tsx:69`) | `chevron.down` | ✓ | `DisclosureGroup` draws it |
| `check` (:170) | selected option, swatch, status pill (`ChoiceList.tsx:54`, `SwatchPicker.tsx:74`) | `checkmark` | ✓ | `Picker` draws it |
| `trash` (:171) | delete (`ItemRow.tsx:266`) | `trash` | ✓ | |
| `share` (:172) | share label or recovery code (`qr.tsx:323`, `backup.tsx:269`) | `square.and.arrow.up` | ✓ | `ShareLink` draws it |
| `warning` (:178) | field errors, error toast, banners (`TextField.tsx:164`) | `exclamationmark.triangle` | ✓ | |
| `info` (:184) | info banner, About (`Banner.tsx:79`) | `info.circle` | ✓ | |
| `cloudOff` (:190) | connection banner (`ConnectionBanner.tsx:33`) | `icloud.slash` | ✓ | `wifi.slash` (✓); the home server is not iCloud |
| `server` (:196) | home server row (`settings.tsx:57`) | `server.rack` | ✓ | |
| `phone` (:203) | this phone, version row (`household.tsx:314`) | `iphone` | ✓ | |
| `backup` (:209) | backup row (`settings.tsx:70`) | `clock.arrow.circlepath` | ✓ | The backup/restore convention. Literal: `archivebox` + arrow; `icloud.and.arrow.up` (✓) |
| `shield` (:216) | privacy row (`settings.tsx:94`) | `hand.raised` | ✓ | Apple's privacy convention. Literal `shield` (✓) |
| `refresh` (:217) | retry (`ErrorState.tsx:67`) | `arrow.clockwise` | ✓ | |
| `sparkle` (:223) | photo suggestion banner (`SuggestionBanner.tsx:61`) | `sparkle` | ✓ | `sparkles` (✓) |
| `clock` (:224) | "Recent" header in place picker (`PlacePicker.tsx:399`) | `clock` | ✓ | |
| `layers` (:230) | Quick Snap / "Several" (`DropZoneCard.tsx:78`, `drop-zone.tsx:133`) | `square.3.layers.3d` | ? | Fallback `square.stack.3d.up` (✓); `photo.stack` (?) is more meaningful |
| `link` (:237) | "Link a printed sticker" (`qr.tsx:297`) | `link` | ✓ | |

Inline icons beside text follow `inlineIconSize(base, fontScale) = round(base * min(max(fontScale, 1), 1.6))` (`useLayoutScale.ts:19-21`). They grow with the text up to 1.6×, never shrink below `base` at small text sizes, and round to whole points. There are three users: the banner icon (base 20, `Banner.tsx:80`), the drop-zone tray in `LocationLine` (`LocationLine.tsx:118`), and the Home caption icon that says where the data lives (`server` when paired, `phone` otherwise, base 16, signal colour while reconnecting, `app/(tabs)/index.tsx:431-435`). SF Symbols in `Label` or inside `Text` scale with the font automatically. For a cap, use `.dynamicTypeSize(...DynamicTypeSize.xxxLarge)` on the image, or `@ScaledMetric` with a manual `min(base*1.6, scaled)`.

---

## 6. Typography

The user decided on **system fonts**, so Atkinson Hyperlegible Next and its loader are dropped: `FontProvider.tsx:21-79`, `typography.ts:12-29`, `fontContext.ts:19`. The type scale (`typography.ts:47-72`) maps to system text styles as follows. RN sizes are in pt at scale 1.

| Variant | RN size/line/weight/tracking/cap | SwiftUI | Notes |
|---|---|---|---|
| `display` | 32/40/800/-0.4/1.4 | `.largeTitle.weight(.heavy)` | Onboarding |
| `title` | 26/32/700/-0.3/1.5 | `.title.bold()` | |
| `whereCard` | 24/30/700/0/1.6 | `.title.bold()` | Keep it ≥ `itemTitle`, which is 24 vs 22 in the scale. This follows the principle that the answer is never smaller than the question. The comment at `typography.ts:43-46` states that principle for `where` vs `name`, and the test asserts only that pair. Nothing asserts `whereCard` vs `itemTitle` |
| `itemTitle` | 22/28/700/0/1.6 | `.title2.bold()` | |
| `heading` | 19/25/700/0/1.8 | `.title3.bold()` | |
| `search` | 19/24/500/0/1.6 | system search field | |
| `code` | 19/26/700/1.5/1.6, tabular | `.title3.bold().monospacedDigit()` + `.tracking(1.5)` | Code inputs |
| `name` | 17/22/600/0/2.0 | `.headline` | |
| `where` | 17/22/500/0/2.0 | `.body.weight(.medium)` | **Same size as `name`** (test in section 11) |
| `body` | 17/24/400/0/2.2 | `.body` | |
| `section` | 16/21/700/0/1.8 | system section header | |
| `button` | 16/20/600/0/1.6 | system button font | |
| `label` | 15/20/600/0/2.0 | `.subheadline.weight(.semibold)` | |
| `meta` | 15/20/500/0/2.0 | `.subheadline.weight(.medium)` | |
| `aside` | 15/20/600/0/2.0, tabular | `.subheadline.weight(.semibold).monospacedDigit()` | |
| `caption` | 13/18/500/0.1/2.0 | `.footnote.weight(.medium)` | |
| `factLabel` | 13/18/700/0.1/2.0 | `.footnote.bold()` | |
| `tab` | 12/16/600/0.1/1.3 | system tab bar | |
| `badge` | 12/16/700/0/1.3, tabular | `.caption.bold().monospacedDigit()` | |
| `tapeS` / `tapeM` / `tapeL` | 13/16/700/0.9, 16/19/700/1.1, 22/26/800/1.8 (caps 1.6, 1.6, 1.5), tabular | `.footnote` / `.callout` / `.title2`, bold/heavy, `.monospacedDigit()`, `.tracking(...)` | The tape never wraps, truncates or stretches. When space runs out, the whole tape moves to the next line (`Tape.tsx:34-37`) |
| `stepper` / `stepperL` | 17/22/800, 22/28/800, tabular | `.body.weight(.heavy).monospacedDigit()`, `.title2.weight(.heavy).monospacedDigit()` | |

Semantics to keep:

- **Headers**: `display`, `title`, `itemTitle` and `heading` announce as headers unless opted out (`typography.ts:77`, `AppText.tsx:92-94`). Use `.accessibilityAddTraits(.isHeader)`. The where-card path opts out (`AppText.tsx:63-66`).
- **Tabular digits** for numbers that change in place: `.monospacedDigit()`.
- **Text never clips; it wraps** (`AppText.tsx:59-66`). Buttons wrap to 2 lines (`Button.tsx:135`).
- **Balanced line breaks** for `display`, `title`, `heading` and `body` (`AppText.tsx:67-71`) avoid a lone last word. That is an RN `textBreakStrategy` workaround. SwiftUI `Text` uses the standard (push-out) strategy by default, so it is not needed.
- **Bold Text**: RN bumps weights by hand because iOS does not apply Bold Text to custom fonts (`typography.ts:79-93`). The system font gets it automatically, so this is dropped.
- **Caps on scaling** (`maxFontSizeMultiplier`). RN's iOS font-scale multipliers per content size category (`node_modules/react-native/React/CoreModules/RCTAccessibilityManager.mm:260-271`) are: xS 0.823, S 0.882, M 0.941, L 1.0, xL 1.118, xxL 1.235, xxxL 1.353, AX1 1.786, AX2 2.143, AX3 2.643, AX4 3.143, AX5 3.571. The SwiftUI cap `.dynamicTypeSize(...X)` that never exceeds the RN cap, meaning the largest step whose multiplier is ≤ the cap, is: cap 1.3 → `.xxLarge`; 1.4, 1.5, 1.6 → `.xxxLarge`; 1.8, 2.0 → `.accessibility1`; 2.2 → `.accessibility2`. This is not always the nearest step: 1.6 is closer to AX1 (1.786) and 2.0 is closer to AX2 (2.143). RN clamps continuously and SwiftUI steps, and system styles scale non-linearly, so caps are approximate. **Recommend** capping only fixed-geometry text (tape, badge, stepper digits) and letting the rest scale fully.

---

## 7. Haptics

### 7.1 Events (`src/ui/haptics.ts:15-34`)

Every call is fire-and-forget. A failure (simulator, power saving) never throws into the caller, and web is a no-op (`haptics.ts:4-13`). Natively the generators never throw, so the guard goes away. `expo-haptics` calls `UIKit` exactly as shown (`node_modules/expo-haptics/ios/HapticsModule.swift`): it creates a generator, calls `prepare()`, then fires.

| Event | Meaning (source comment) | expo call | UIKit | SwiftUI `.sensoryFeedback` |
|---|---|---|---|---|
| `step` | Stepper ± tap (every 5th step during hold-repeat) | `selectionAsync` | `UISelectionFeedbackGenerator().selectionChanged()` | `.selection` |
| `reachedZero` | Stepper reached 0, "None left": heavier than a step | `impactAsync(Light)` | `UIImpactFeedbackGenerator(style: .light).impactOccurred()` | `.impact(weight: .light)` |
| `choice` | A choice changed: place, space, type, colour, icon, segment; search cleared | `selectionAsync` | selection | `.selection` |
| `undo` | Undo applied | `selectionAsync` | selection | `.selection` |
| `success` | Add, Move, File, label linked, joined, QR recognised | `notificationAsync(Success)` | `UINotificationFeedbackGenerator().notificationOccurred(.success)` | `.success` |
| `warning` | A conflict (409) shown to the person | `notificationAsync(Warning)` | `.warning` | `.warning` |
| `error` | A failed write, an invalid QR, a quantity that did not save | `notificationAsync(Error)` | `.error` | `.error` |
| `tap` | Add block pressed; fast-mode shot returned | `impactAsync(Light)` | impact light | `.impact(weight: .light)` |
| `longPress` | Add block long-pressed (Quick Snap) | `impactAsync(Medium)` | impact medium | `.impact(weight: .medium)` |

Implementation: most haptics fire after an async outcome (network or DB result), not on a view-value change. Provide a `@MainActor enum Haptics { static func success() … }` wrapper around UIKit generators for imperative call sites (UIKit feedback generators are main-actor-isolated in Swift 6). Use `.sensoryFeedback(_:trigger:)` where a state value changes in a view. iOS 17.5+ also offers view-anchored initialisers (`UIImpactFeedbackGenerator(style:view:)`); use them when convenient.

### 7.2 Call-site inventory (port the triggers exactly)

| Event | Call site | Trigger |
|---|---|---|
| step | `src/ui/components/QuantityStepper.tsx:230` | Every ± tap. A 400 ms hold (`delay.stepRepeat`, :129) fires `onLongPress` → `startRepeat` (:240-246). That makes one ordinary step **with** a haptic, resets `repeatCount = 0`, then repeats every 80 ms (`delay.stepRepeatEvery`, :245). A repeat step ticks only when `++repeatCount % 5 == 0` (`REPEAT_HAPTIC_EVERY = 5`, :32). VoiceOver increment and decrement go through the same `bump(±1)` (:273-284), so they tick too. **No haptic when the value did not change**: at a bound or while disabled, `bump` returns early and also stops the repeat (:217-225) |
| reachedZero | `QuantityStepper.tsx:228` | `next == 0` (MIN_QUANTITY), on taps and repeats alike. **Takes precedence over** `step`, and does not advance the repeat counter |
| choice | `pickers/TypeGrid.tsx:48`, `pickers/SwatchPicker.tsx:58`, `pickers/SegmentedControl.tsx:60`, `pickers/EmojiPicker.tsx:53`, `pickers/ChoiceList.tsx:50` | Only when the tapped option is **not already selected** |
| choice | `src/ui/components/SearchField.tsx:64` | Clear button pressed |
| choice | `src/ui/components/PlacePicker.tsx:270` | A place picked (ignored while a pick is saving) |
| choice | `app/item/new.tsx:350` | A "where it goes" entry chosen. **No already-selected guard**: choosing the current entry ticks again |
| undo | `src/hooks/useMove.ts:94`; `app/item/new.tsx:483` | Move undone; just-added item removed again |
| success | `useMove.ts:133` | Item moved or filed |
| success | `src/ui/household/JoinForm.tsx:123` | Joined a household |
| success | `app/container/new.tsx:79`; `app/space/new.tsx:181` | Container or space created |
| success | `app/household.tsx:151` | Local inventory copied into the household |
| success | `app/c/[token].tsx:132` | Deep-link label bound to a container |
| success | `app/item/new.tsx:546` | Item saved |
| success | `app/backup.tsx:174` | Restore succeeded |
| success | `app/container/[id]/qr.tsx:165`, `:190` | Label made or replaced; label removed |
| success | `app/container/[id]/link.tsx:150`, `:177` | Sticker already opens this container; sticker linked |
| success | `app/(tabs)/scan.tsx:235` | Scanned label resolved to a bound container |
| warning | `useMove.ts:98` | Undo met a conflict |
| warning | `useMove.ts:178` | Item already moved elsewhere by another device |
| warning | `src/ui/item/NameItInline.tsx:155` | Named meanwhile (recognition or another phone) |
| warning | `app/item/[id]/edit.tsx:222` | Edit conflict |
| error | `src/hooks/useSavedQuantity.ts:136` | Quantity not saved |
| error | `useMove.ts:99`, `:174`, `:182` | Undo failed (non-conflict); item gone; move failed |
| error | `NameItInline.tsx:164` | Name not saved |
| error | `JoinForm.tsx:108`, `:138` | Join validation failed; join refused or failed |
| error | `app/container/new.tsx:102`; `app/space/new.tsx:200` | Create failed |
| error | `app/household.tsx:159`, `:196` | Import failed; remove device failed |
| error | `app/c/[token].tsx:141` | Bind failed |
| error | `app/item/new.tsx:488`, `:526` | Undo-add failed; save failed |
| error | `app/backup.tsx:154`, `:179`, `:186` | Code validation; restore refused; restore threw |
| error | `app/container/[id]/qr.tsx:168`, `:193` | Make/replace failed; remove failed |
| error | `app/item/[id]/index.tsx:255`; `app/capture/review.tsx:167` | Delete failed |
| error | `app/container/[id]/edit.tsx:135`, `:192`; `app/space/[id]/edit.tsx:120`, `:179` | Save failed; delete failed |
| error | `app/item/[id]/edit.tsx:211`, `:226` | Item gone; save failed |
| error | `app/container/[id]/link.tsx:136`, `:145`, `:169` | Resolve threw; not our label; bind failed |
| error | `app/(tabs)/scan.tsx:227`, `:249` | Lookup failed; not our label |
| tap | `src/ui/components/TabBar.tsx:169` | Add pressed |
| tap | `app/capture/index.tsx:270` | Fast-mode shot **taken**: the camera returned a photo URI. It fires after the take-picture await and **before** `captureFastItem` saves the item (:270-273), so it never holds up the next shot. It says nothing about the save succeeding |
| longPress | `TabBar.tsx:174` | Add long-pressed (`delayLongPress = 350`, :182) → Quick Snap. The VoiceOver custom action "Quick Snap" calls the same `quickSnap()` (:186-189), so it fires this haptic too |

There is no haptic on successful deletes, on navigation, or on toasts. There is also none on a successful edit of an existing record (item name, quantity, Edit details, space or container edits), on an **unbound** scanned label (`outcome.kind === 'unknown'` routes to `/c/[token]` silently, `app/(tabs)/scan.tsx:241-246`), or on a successful backup.

**Double-haptic risk natively**: `.contextMenu`, swipe-action full swipes and some stock pickers emit system haptics. If the Add tab's long press becomes a context menu, do not also fire `longPress`. Keep explicit `choice` on stock `Picker`s via `.sensoryFeedback(.selection, trigger: selection)`, but only on user-initiated changes (the RN pickers skip re-selecting the current value).

---

## 8. Motion and timing (`src/ui/motion.ts`)

### 8.1 Durations: motion, become 0 under Reduce Motion (`motion.ts:11-20`)

| Token | ms | Used at | Native |
|---|---|---|---|
| `press` | 100 | **unused** | n/a |
| `toastIn` | 160 | `Toast.tsx:70-86`: opacity 0 → 1 **and** an 8 pt rise to 0, in parallel, `easing.out`. The rise starts at 0 when reduced | `.timingCurve(0.33, 1, 0.68, 1, duration: 0.16)` (≈ ease-out cubic) or `.snappy`, with `.move(edge: .bottom).combined(with: .opacity)` |
| `toastOut` | 120 | `Toast.tsx:88-95`: opacity → 0, `easing.exit`. The provider removes the toast after `duration.toastOut` (`ToastProvider.tsx:142`) | `.timingCurve(0.4, 0, 1, 1, duration: 0.12)` |
| `expand` | 180 | `animateNextLayout` (`motion.ts:94-100`): `LayoutAnimation.create(180, 'easeInEaseOut', 'opacity')`. Views that **appear or disappear fade**, and views that **move or resize animate** their frame on ease-in-out. It is not a pure cross-fade. Callers: the Home header compacting (`app/(tabs)/index.tsx:269,275`), a drop-zone row leaving after it is filed (`app/(tabs)/drop-zone.tsx:107`), a review row hidden after a delete (`app/capture/review.tsx:161`), an item row expanding or collapsing its quantity controls (`ItemRow.tsx:170-173`) and the settings technical-details expander (`app/settings.tsx:111`). Also the photo viewer settle (`app/item/[id]/photo.tsx:95`, `easing.settle`) | `withAnimation(.easeInOut(duration: 0.18)) { … }`. SwiftUI's default `.opacity` insertion and removal transitions plus animated frames match it. Settle: `.timingCurve(0.2, 0.8, 0.2, 1, duration: 0.18)` |
| `stepSwap` | 180 | Add form step change (`app/item/new.tsx:312-325`): the new step **fades in** from opacity 0 to 1 with `easing.out`. There is no slide. When reduced, the opacity is not reset and no animation runs | `.transition(.opacity)` with `.easeOut(duration: 0.18)`, or a system push if the step becomes a navigation destination |
| `reticleLock` | 250 | Scanner holds the locked reticle for 250 ms before acting (`QrScanner.tsx:131`). Skipped when reduced | `try await Task.sleep(for: .milliseconds(reduced ? 0 : 250))` |
| `focusSpot` | 700 | **unused** token. `TapToFocusLayer.tsx:8` has its own `FOCUS_SPOT_MS = 700` (72 pt square) | camera area |
| `shutterFlash` | 120 | White flash: opacity 0 → 0.5 in 60 ms, then → 0 in 60 ms ease-out (`CameraChrome.tsx:70-88`). **Skipped** when reduced | camera area |

Easings (`motion.ts:39-43`): `settle = bezier(0.2, 0.8, 0.2, 1)`, `out = Easing.out(cubic)`, `exit = bezier(0.4, 0, 1, 1)`. With a native look, system defaults (`.smooth`, `.snappy`, push and sheet transitions) are acceptable. Keep only the semantics.

Other motion outside the tokens: the container screen's "just added" highlight holds 600 ms, then fades over 1200 ms. Under Reduce Motion it waits 600 + 1200 ms and then disappears instantly (`app/container/[id]/index.tsx:36-39,118-140`).

### 8.2 Delays: timing, **not** affected by Reduce Motion (`motion.ts:26-37`)

| Token | ms | Meaning and use |
|---|---|---|
| `skeleton` | 180 | Show skeleton or spinner only if loading lasts ≥ 180 ms (`useDelayedFlag` default, `src/hooks/useDelayedFlag.ts:12-25`; `Skeleton.tsx:96`, `SearchField.tsx:59`, `scan.tsx:163`, `link.tsx:109`, `CameraPermission.tsx:59`, `photo.tsx`) |
| `spinner` | 150 | Button spinner joins the label after 150 ms of `loading` (`Button.tsx:87`; `space/new.tsx:79`) |
| `bootCaption` | 400 | Boot screen caption (`strings.boot.opening`) after 400 ms (`BootScreen.tsx:17`) |
| `reconnect` | 2500 | Reconnect retry delay (`ConnectionProvider.tsx:127`; connection area) |
| `searchDebounce` | 200 | Search debounce; 0 if the trimmed query equals the settled one (`useSearch.ts:92`, `(tabs)/index.tsx:338`) |
| `searchSkeleton` | 600 | Older results are dropped for a skeleton after 600 ms (`(tabs)/index.tsx:331-332`). RN mounts the `Skeleton` at 600 − 180 = 420 ms, because the skeleton waits its own `delay.skeleton` before it becomes visible. It therefore appears at 600 ms, exactly when the older results go. Natively, show the skeleton at 600 ms |
| `toast` | 5000 | Toast life, `record.duration ?? (action ? toastWithAction : toast)`. A caller may pass its own `duration`. The result is **doubled while VoiceOver is on** (`ToastProvider.tsx:164-165`), using `isScreenReaderEnabled` plus `screenReaderChanged` (`:95-108`). A paused toast resumes with at least `toast/2` (`:238`) |
| `toastWithAction` | 9000 | Toast with an action (Undo); also doubled with VoiceOver |
| `stepRepeat` | 400 | Hold before stepper auto-repeat |
| `stepRepeatEvery` | 80 | Auto-repeat interval |

`useDelayedFlag(active, ms)` is true only after `active` has stayed true for `ms`, and resets to false the moment `active` goes false. Native: `.task(id: active) { if active { try? await Task.sleep(for: .milliseconds(ms)); elapsed = true } else { elapsed = false } }`, with `show = active && elapsed`.

### 8.3 Reduce Motion semantics

- Read from `AccessibilityInfo.isReduceMotionEnabled` plus the change event, one app-wide subscription (`motion.ts:50-86`). Natively use `@Environment(\.accessibilityReduceMotion)`. The singleton-store workaround is not needed.
- `motionMs(ms, reduced)` returns 0 when reduced (`motion.ts:46-48`). Delays are untouched.
- `animateNextLayout()` and `animateWithKeyboard()` do **nothing** when reduced, so the change is instant (`motion.ts:94-111`). Natively: `withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) { … }`. SwiftUI keyboard avoidance replaces `Keyboard.scheduleLayoutAnimation`, so that is not needed.
- Stack navigation uses a fade on **Android only** under Reduce Motion (`app/_layout.tsx:138`). iOS system transitions already respect the setting, so nothing to port.
- Shutter flash and reticle wait are skipped; the toast fade and rise are instant, and a short swipe snaps back without its spring (`Toast.tsx:99-101`); the photo viewer snaps back without animating (`photo.tsx:88-92`).
- Programmatic scrolls are not animated: scroll-to-index on Home (`app/(tabs)/index.tsx:243`) and scroll-to-top on the Add form (`app/item/new.tsx:470`) pass `animated: !reduceMotion`. Natively, wrap `ScrollViewProxy.scrollTo` in `withAnimation(reduceMotion ? nil : .default)`.
- The Add form step fade is skipped (`app/item/new.tsx:315-317`).
- The container screen's "just added" highlight still holds 600 ms. Under Reduce Motion it then waits a further 1200 ms and disappears instantly, instead of fading over 1200 ms (section 8.1).

---

## 9. Accessibility conventions to preserve

### 9.1 Pure helpers (`src/ui/a11y.ts`), port and test verbatim

- `spellCode(code)` (`a11y.ts:23-29`): `code.split("-")`, then for each group `[...group.trim()].join(" ")` (iterate **Unicode scalars**), then drop empty groups, then join with `", "`. `DRW-7K2M` → `D R W, 7 K 2 M`. Read as written, "DRW" is spoken as "drew" (`a11y.ts:17-22`). An alternative is `AttributedString.accessibilitySpeechSpellOut`, but the spelled string is embedded in composed labels and asserted by tests, so keep the function.
- `whereSpoken(place)` (`a11y.ts:36-42`): if `containerId == "drop-zone"`, return `strings.a11y.inDropZone`. Else, if `containerName` is **truthy**, `a11y.inPlace(spaceName, containerName, spelled)`, otherwise `a11y.inSpace(spaceName, spelled)`, where `spelled = spellCode(containerShortCode)`. JS truthiness means both `null` **and `""`** count as unnamed. A whitespace-only name such as `" "` counts as named and is spoken as is. Swift: `if let n = place.containerName, !n.isEmpty { … }`. Do not trim.
- `quantitySpoken(q)` (`a11y.ts:45-47`): 0 gives `strings.rows.noneLeft`, else `rows.quantity(q)`.

### 9.2 Conventions

1. **Icons are never announced.** The control owns the label (`Icon.tsx:19-24`). Icon-only buttons **require** a label, item-specific where it matters ("Edit Tool chest", not "Edit") (`IconButton.tsx:9-10`). Natively: `Button { } label: { Label(title, systemImage:) }.labelStyle(.iconOnly)`.
2. **Item-specific labels** on repeated actions: `strings.item.moveA11y(name)`, `strings.rows.deleteA11y(name)`, `strings.quantity.increase(name)`, with `…Unnamed` / `…Plain` variants when there is no name.
3. **Rows are one element** with a composed label: `strings.rows.itemA11y(name, whereSpoken, quantitySpoken)`, `rows.spaceA11y`, `rows.containerA11y`. Use `.accessibilityElement(children: .ignore)` + `.accessibilityLabel(...)`. Pips, space tiles, type tiles and decorative tape are hidden (`SpacePip.tsx:23-24`, `SpaceTile.tsx:47,95`, `Tape.tsx:48-49`).
4. **Codes are spelled**: a tape that is its own element reads `strings.a11y.labelCode(spellCode(code))` (`Tape.tsx:45-49`). The container title code uses `a11y.labelCodeTitle` (`app/container/[id]/index.tsx:288`).
5. **Colour never carries meaning alone**: the name always follows the pip (`SpacePip.tsx:12-18`). Swatches are spoken by colour name, emoji by object name (section 4).
6. **Pickers are radio groups** with a selected state (`EmojiPicker.tsx:42-58`, `SwatchPicker.tsx:43-63`). Natively a stock `Picker` provides this. For custom grids, `.accessibilityAddTraits(.isSelected)` on the chosen one and `.accessibilityElement(children: .contain)` + label on the group.
7. **Quantity stepper is one adjustable element on iOS**: label `quantity.field(name)` (or `fieldPlain`); value `noneLeft` at 0, else the number; min 0, max 9999; increment and decrement step it; a custom action "Type a number" (`strings.quantity.typeNumber`) focuses the field (`QuantityStepper.tsx:300-315`). Natively: `.accessibilityElement(children: .ignore)`, `.accessibilityLabel`, `.accessibilityValue`, `.accessibilityAdjustableAction { direction in … }`, `.accessibilityAction(named: L10n.Quantity.typeNumber) { focused = true }`. The Android count announcement (`QuantityStepper.tsx:39-50`) is a TalkBack workaround and is not needed. An RN artifact not to port: under the New Architecture (Fabric, `app.json:10`), **every** entry in `accessibilityActions` becomes a `UIAccessibilityCustomAction`. That includes `increment` and `decrement`, which have no label, so VoiceOver's Actions rotor today lists "increment", "decrement" and "Type a number" (`node_modules/react-native/React/Fabric/Mounting/ComponentViews/View/RCTViewComponentView.mm:1575-1599`). Natively, only "Type a number" is a custom action. Swipe up and down comes from `.accessibilityAdjustableAction`.
8. **Custom action for long press**: the Add tab is labelled `strings.tabs.addA11y` ("Add an item"; the visible label is `strings.tabs.add`). It exposes "Quick Snap" (`strings.tabs.quickSnapAction`) as a custom action, with hint `strings.tabs.addHint` (`TabBar.tsx:183-189`). The action runs the same `quickSnap()` as a long press, including its haptic. Natively: `.accessibilityAction(named:)` + `.accessibilityHint`.
9. **Toggle state**: icon toggles (torch, flash) announce selected (`IconButton.tsx:14-15,63`). Natively use a `Toggle` or `.accessibilityAddTraits(.isSelected)`. Disabled and busy states are exposed (`Button.tsx:108`). SwiftUI `.disabled` handles disabled; for busy, keep the label and add a `ProgressView`.
10. **Announcements**, because VoiceOver does not read RN live regions:
    - Toasts: announced, **queued**, as `message` or `"\(message), \(availableAction(label))"`. Life is doubled while VoiceOver runs (`ToastProvider.tsx:95-108,164-180`).
    - Banners: announced when they appear or their copy changes, as `"\(title). \(message)"`, or the bare `message` when there is no title. They are **not** announced when `live == 'off'`, and **not queued**, because they use plain `announceForAccessibility` (`Banner.tsx:61-69`).
    - Field errors: queued `strings.forms.errorA11y(error)` (`TextField.tsx:91-97`). The field's own label also carries `required` and the error (section 2.6(8)).
    - Code counter: read **once on leaving the field** (it would talk over typing) (`CodeInput.tsx:51-54`).
    - Search results: `strings.search.summary(items, places)` (`(tabs)/index.tsx:86-90`). It is announced only when the search key is pressed. If the results were not in yet, it is announced when they land (`:184,290-305,569`), never on every keystroke.
    - Connection lost: `strings.connection.reconnecting` (`ConnectionProvider.tsx:166`). Revoked: `strings.revoked.title`, and the revoked panel is **modal** for VoiceOver (`ConnectionBanner.tsx:64,85`).
    - Error states announce their heading (`ErrorState.tsx:61`); stepper save errors, for the `large` stepper only (`QuantityStepper.tsx:196-198`); name conflicts (`NameItInline.tsx:51`); scanner results (`scan.tsx:63`); link results (`link.tsx:53`); last backup line (`backup.tsx:313`); camera status (`CameraChrome.tsx:148`).
    - Native: `AccessibilityNotification.Announcement(text).post()` (iOS 17+). For queueing, set the `AttributedString` accessibility speech attribute (`accessibilitySpeechQueueAnnouncement = true`, or `accessibilitySpeechAnnouncementPriority = .low`; verify the attribute names). RN's `{ queue: true }` sets UIKit's `UIAccessibilitySpeechAttributeQueueAnnouncement = YES` on an `NSAttributedString` (`node_modules/react-native/React/CoreModules/RCTAccessibilityManager.mm:329-330`), so that is the exact behaviour to match. Only toasts and field errors are queued. Every other announcement interrupts. Modal panel: `.accessibilityAddTraits(.isModal)`.
11. **Focus moves**: during a filing run, the next item's title gets VoiceOver focus if a screen reader is on (`app/item/[id]/index.tsx:63-65,147-158`). Native: `@AccessibilityFocusState`. Buttons expose their ref for this purpose (`Button.tsx:45-46`).
12. **Links** in the where card are `link` role with hint `strings.a11y.opensSpace` / `opensContainer`, always underlined (touch has no hover). The hit area extends to 48 pt vertically without padding the text (`LocationLine.tsx:39-87`). Natively: `.accessibilityAddTraits(.isLink)`.
13. **Touch targets**: 48 × 48 for every icon control (`IconButton.tsx:24-25,126-131`), small buttons ≥ 40 + `hitSlop` 4 (`Button.tsx:104,161-165`). Native minimum is 44.
14. **Dynamic Type**: all text scales (section 6). Layouts **stack** when `fontScale >= 1.35` or `width < 360` (`useLayoutScale.ts:13-16`, `tokens.ts:178-179`). With RN's multipliers that is exactly **`dynamicTypeSize >= .xxxLarge`** (xxL = 1.235 < 1.35 ≤ xxxL = 1.353). The width rule only bites on iPad, in Slide Over, split view, or an iPadOS 26 freely resized window, which can be narrower than 360 pt. Every iOS 26 iPhone is ≥ 375 pt wide. It is the **window** width (`useWindowDimensions`), not the container width. Native: `@Environment(\.dynamicTypeSize)` + `GeometryReader`/`containerRelativeFrame`, or `ViewThatFits` / `AnyLayout(HStackLayout) ↔ VStackLayout`.
15. **Search highlight**: matches are drawn on `mark` with ink text; the spoken text is unchanged (`AppText.tsx:122-145`). `splitHighlight(text, terms)` (`AppText.tsx:107-115`): keep terms whose length is > 1 **UTF-16 code unit** (`term.utf16.count > 1` in Swift), regex-escape each, build `(t1|t2|…)` case-insensitive global, and split so odd indexes are matches (leading and trailing empty strings kept). Alternation order decides ties at the same position. Natively build an `AttributedString` with `NSRegularExpression(pattern:options: .caseInsensitive)`. Escape each term with `NSRegularExpression.escapedPattern(for:)`, because ICU's metacharacters are not identical to the JS set `[.*+?^${}()|[\]\\]`. An empty `terms` list, or one with only one-unit terms, returns `[text]` unchanged. ICU's case folding can differ from JS for non-ASCII (ß, İ); this is acceptable but test ASCII parity.
16. **Bold Text and Increase Contrast**: system fonts and colours handle both; nothing to port.
17. **Focus ring** for hardware keyboard or Switch Control: a 2 pt ink outline (`PressFeedback.tsx:51-69`). Natively the system focus effect replaces it.

---

## 10. Primitive components: behaviour to keep

**`Button`** (`src/ui/components/Button.tsx`):

- `primary` → `.buttonStyle(.borderedProminent)` with tint ink. `secondary` → `.bordered`. `quiet` → `.borderless` / `.plain`. `destructive` → `Button(role: .destructive)`, as text, never filled, and **always leads to a confirm** (`Button.tsx:56-64`).
- `loading` keeps the label in place (no width jump, still announced). A spinner joins it only after 150 ms, and it **replaces** the leading icon if there is one (`showSpinner ? spinner : icon`, `Button.tsx:127-131`). Presses are ignored while loading (`disabled={disabled || loading}`), and the button announces busy. RN reports `accessibilityState.disabled` from the `disabled` prop only, so a loading button says "busy" but not "dimmed" (`Button.tsx:85-108`). Natively, `.disabled(loading)` would also make it say "dimmed". That is acceptable, but keep the busy cue, for example a `ProgressView` with its own label.
- Disabled opacity 0.45 (`Button.tsx:117`). Stock styles do their own.
- `size: 'sm'` (min height 40, hitSlop 4) and `flush` (outdented quiet button) are RN layout details. Use `.controlSize(.small)`.
- The default accessibility label is the visible label; pass item-specific forms explicitly (`Button.tsx:39,106`).

**`IconButton`** (`IconButton.tsx`): variants `plain` (header), `outlined` (bottom bar), `chip` (search clear, 28 pt circle, 16 pt icon), `camera` (over the preview, 48 pt circle, `camera.chip` fill, tape accent when selected). The selected non-camera variant draws a heavier stroke (2). Natively: toolbar items, `.bordered` buttons, `.searchable`'s own clear, and glass buttons over the camera.

**`AppText`** (`AppText.tsx`): see sections 6 and 9.2(15). `toneColor` maps `camera` to `#FFFFFF`, otherwise to a scheme token (`AppText.tsx:14-18`).

**`PressFeedback`** (`PressFeedback.tsx`): the iOS pressed overlay, the Android ripple and a manual focus ring. **Dropped entirely**, because native button styles and focus effects cover it.

**`FontProvider` / `fontContext`**: **dropped** (system font, automatic Bold Text).

**`useSpreadGap` / `spreadGap(width, tile, minGap, columns?)`** (`src/hooks/useSpreadGap.ts:13-21`): spreads fixed tiles so full rows touch both edges. Used by three pickers: swatches (tile 48, min gap 4, `SwatchPicker.tsx:35`), emoji (tile 48, min gap 8, `EmojiPicker.tsx:34`), and the type grid (tile 72, min gap 8, columns 4, or 3 when the window is narrower than 360 pt, `TypeGrid.tsx:29`).

```
if width <= 0: return minGap
fit = min(columns ?? +inf, floor((width + minGap) / (tile + minGap)))
if fit < 2: return minGap
return max(minGap, floor(((width - fit*tile) / (fit - 1)) * 10) / 10)   // rounded DOWN to 0.1
```

Natively, implement a small custom `Layout`, or accept `LazyVGrid(columns: [GridItem(.adaptive(minimum: 48), spacing: minGap)])`. Note the difference: adaptive grids stretch cells, not gaps, so a tile visual inside the cell must stay a fixed 48. Port the pure function and its tests if a custom `Layout` is used.

**`Mark`** (`Mark.tsx`): the brand mark, an ink box with a strip of tape. Sizes 52×46 (radius 10) and 72×64 (radius 14). The tape strip sits at top 36 %, height 30 %, inset 20 % left and right, radius 3. Decorative. Draw it in SwiftUI, or reuse it for the app icon (section 12).

---

## 11. Unit tests to port (Swift Testing)

Each line gives the file, the test name, then what it asserts. Port each as `@Test` with the same vectors.

`src/i18n/__tests__/format.test.ts`

- `plural` › "picks the form by count": (1, item, items) → `1 item`; 0 → `0 items`; 3 → `3 items`.
- `sentenceList` › "joins like a sentence, without a serial comma": `[]` → `""`; `[a]` → `a`; `[a, b]` → `a and b`; `[a, b, c]` → `a, b and c`.
- `ago` › "%p ms ago reads %p" (now = `Date.UTC(2026, 9, 2, 12)`): 0 and 59 000 → `just now`; 1 min → `1 minute ago`; 5 min → `5 minutes ago`; 1 h → `1 hour ago`; 3 h → `3 hours ago`; 1 d and 47 h → `yesterday`; 2 d → `2 days ago`; 29 d → `29 days ago`; 30 d → `1 month ago`; 64 d → `2 months ago`; 365 d → `1 year ago`; 800 d → `2 years ago`.
- `ago` › "reads a time from a phone with a fast clock as just now": now + 5 min → `just now`.
- `longDate` › "formats en-GB with the month spelled out": `Date.UTC(2026, 8, 2, 12)` → `2 September 2026`. Use a fixed time zone in the Swift test, or noon UTC as here.

`src/ui/__tests__/a11y.test.ts`

- `spellCode` › "spaces the characters and pauses between groups": `DRW-7K2M` → `D R W, 7 K 2 M`.
- `spellCode` › "copes with a code without groups and with stray hyphens": `BOX1` → `B O X 1`; `-AB--C-` → `A B, C`.
- `whereSpoken` › "names the space, the container and the spelled label": Garage / Tool chest / `CAB-J92R` → `In Garage, Tool chest, label C A B, J 9 2 R`.
- `whereSpoken` › "leaves out an unnamed container": containerName nil → `In Garage, label C A B, J 9 2 R`.
- `whereSpoken` › "never reads the drop zone’s internal code": `drop-zone` / `DROP-ZONE` → `In the drop zone, not filed yet`.
- `quantitySpoken` › "says "None left" at zero": 0 → `None left`; 12 → `Quantity 12`.

`src/ui/__tests__/color.test.ts`

- `safeColor` › "normalises 6-digit hex to upper case with a hash": `#5b8def`, `5B8DEF` → `#5B8DEF`; `'  #0F9BB0 '` → `#0F9BB0`.
- `safeColor` › "expands 3- and 4-digit shorthand and drops alpha": `#abc` and `#abcd` → `#AABBCC`; `#11223344` → `#112233`.
- `safeColor` › "falls back to the desk grey for %p": nil, `''`, `blue`, `#12`, `#12345`, `#GGGGGG`, `rgb(0,0,0)` → `#8A948D`.
- `rgb and toHex` › "round-trips channels": `#5B8DEF` ↔ (91, 141, 239). "rounds and clamps": toHex(-4, 255.6, 127.5) → `#00FF80`.
- `mixHex` › "returns each end at weight 1 and 0"; "lerps per channel": (#000, #FFF, 0.5) → `#808080`.
- `spaceTint` › "matches the desk’s 24 % colour-mix": (#5B8DEF, #FFFFFF, 0.24) → `#D8E4FB`. "defaults to 24 % and tolerates junk colours": junk → `mixHex('#8A948D', '#FFFFFF', 0.24)`. "keeps ink readable on the tint of any colour, light and dark": for #000, #FFF, #E0A800, #0F9BB0, #5B8DEF, contrast(ink, tint on sheet) > 9 light and > 6 dark.
- `withAlpha` › "appends the alpha byte": (#5B8DEF, 0.45) → `#5B8DEF73`; (#abc, 1) → `#AABBCCFF`; (…, 0) → `…00`.
- `luminance and contrast` › "measures the WCAG extremes": L(#000) = 0, L(#FFF) = 1, contrast ≈ 21 both ways.
- `token contrast` › "%s on %s clears AA in both schemes": 19 text/surface pairs ≥ 4.5. "control borders clear 3:1 on %s". **Only relevant if the custom tokens are kept.** With system colours, drop these tests or keep them for `Tape`/`TapeInk`, `mark`/ink and space tints.

`src/ui/__tests__/theme.test.tsx`

- `onColor` › "puts light text on dark fills and dark text on light fills": #000 → `#FFFFFF`; #FFF → `#12161C`. "accepts shorthand hex and a missing leading hash": `#000`, `fff`. "weights green more than blue": #0000FF → white; #00FF00 → `#12161C`. "clears WCAG AA for large text on every space colour": ≥ 3:1 for all 6. "picks the higher-contrast foreground, not the intuitive one": #5B8DEF → `#12161C`.
- `SPACE_PRESETS` › "offers distinct one-tap names drawn from the shared palette": unique names, colours in the palette, non-empty icons.

`src/ui/__tests__/typography.test.tsx` (Atkinson-specific, mostly dropped)

- "uses the system font at the numeric weight until the fonts are ready", "switches to the weight’s own family…", "bumps one step for iOS Bold Text…": **drop** (no custom font).
- "keeps changing numbers tabular": keep as a design rule (stepper and badges use `.monospacedDigit()`).
- "never sets the location smaller than the name above it": asserts `where.fontSize` **equals** `name.fontSize` (`toBe`, both 17). Keep it as a rule: the native `where` style must be at least the `name` style, and equal is the shipped design.

`src/ui/components/__tests__/textHelpers.test.tsx` (in-scope part)

- `splitHighlight` › "puts matches at odd indexes, case-insensitively": (`Spare batteries AA`, [batt, aa]) → `['Spare ', 'batt', 'eries ', 'AA', '']`.
- `splitHighlight` › "ignores one-letter terms and escapes regex characters": (`USB-C (2m)`, [c, (2m)]) → `['USB-C ', '(2m)', '']`; (`Drill`, []) → `['Drill']`.
- (`suggestCategories` and `numberFieldWidth` in the same file belong to the form and stepper areas.)

`src/hooks/__tests__/useSpreadGap.test.ts`

- "keeps the minimum gap until the row is measured": (0, 48, 8) → 8.
- "spreads as many tiles as fit…": (358, 48, 8) → 14, and 6·48 + 5·gap ≤ 358.
- "never rounds a row past its width": (358.33, 48, 4) satisfies 6·48 + 5·gap ≤ 358.33.
- "keeps to a fixed number of columns when asked": (358, 72, 8, 4) ≈ 23.3; (288, 72, 8, 3) → 36.
- "falls back to fewer columns, or the minimum, when they do not fit": (250, 72, 8, 4) → 17; (60, 48, 8) → 8.

Copy assertions in other areas' tests (port with those areas, listed here because they pin copy):

- `src/ui/home/__tests__/homeList.test.ts` › "reads as one sentence": `home.summary(5, 13, 45)` → `5 spaces, 13 containers and 45 items.`; (1, 1, 1) → `1 space, 1 container and 1 item.`
- same file › "says none are left when every place is empty": `search.totalNone('Printer ink', 2)` → `“Printer ink”: none left in any of 2 places`.
- same file › "summarises what was found": `search.summary(3, 1)` → `3 items and 1 place found`; (1, 0) → `1 item found`; (0, 0) → `Nothing found`. "reads the total line as one sentence": `search.total('AA batteries', 14, 2)` → `“AA batteries”: ×14 in 2 places`.
- same file › "counts places, not items, and needs a second place": two Screws rows in `c1` give no total; adding one in `c2` gives `{ name: 'Screws', quantity: 16, places: 2 }`. This is why `search.total*` can say "places" without a plural.
- `src/ui/household/__tests__/join.test.ts` › "puts each problem under its own field": `join.wrongLength(3)`, `join.nameRequired`, `join.badChars('U')`; "asks for an empty code…": `join.codeRequired`; `codeProblem` › "names characters no code uses before complaining about the length": `'MMWKU-M2H7%'` gives `{ kind: 'chars', chars: 'U %' }` (feeds `badChars`); "reports the length of a short or long code": counts 18 and 27 (feeds `wrongLength`).
- `src/ui/household/__tests__/status.test.ts`:
  - `backupReason` › "has plain words for every failure": `malformed` → `reasons.malformed`, `not_found` → `reasons.notFound`, `quota_exceeded` → `reasons.quotaExceeded`; `server_error`, `malformed_response` and `no_account` → `reasons.other`.
  - `backupReason` › "never shows a raw reason code": no `_` in the output for the 12 codes `malformed, not_configured, no_account, offline, timeout, unauthorized, quota_exceeded, too_large, not_found, corrupted, server_error, malformed_response`.
  - `backupSummary` › "always has a value, including Off": `unavailable` → `backupSummary.notConfigured`, `off` → `.off`, `working` → `.working`, `idle` with `lastBackupAt == nil` → `.notYetRun`, `idle` with a backup → `.on`, all with tone ink. "marks a failed backup in signal": `error` → `.attention`, tone signal.
  - `devices` › "describes each phone": this device → `household.thisPhone`; `lastSeenAt = NOW - 3 days` → `household.lastUsed('3 days ago')` (exercises `ago`); `lastSeenAt == nil` → `household.neverUsed`.

**New Swift-only tests to add**:

- (a) Every catalog key resolves to a non-empty value, and no value equals its key.
- (b) Each plural key renders identically to the TS function for counts 0, 1, 2 and 1234. Generate expected values by running the TS functions in the catalog-generation script.
- (c) Emoji keys round-trip exact code points (🛋️ keeps U+FE0F).
- (d) `strings.where.notFiledYet` contains U+00A0 twice.
- (e) `ago` boundaries beyond the TS vectors: `2*DAY - 1` → `yesterday`; 360 days → `12 months ago`; 364 days → `12 months ago`; `HOUR - 1` → `59 minutes ago`.
- (f) `longDate` under a non-Gregorian `Calendar.current` (for example `.buddhist`) still gives `2 September 2026`.
- (g) `safeColor` whitespace and digit parity: U+FEFF is trimmed; U+0085 is **not** trimmed, so `"\u{0085}#5B8DEF"` gives `#8A948D`, because JS keeps NEL; a fullwidth `"＃５Ｂ８ＤＥＦ"` gives `#8A948D`.
- (h) `whereSpoken` with `containerName == ""` speaks the `inSpace` form, and with `" "` the `inPlace` form.
- (i) `backupReason` covers all 9 named mappings plus `other` (table in 2.6(5)).
- (j) `onColor` returns `#12161C` for all six palette colours and for the fallback grey.

---

## 12. Assets: app icon and splash

- `assets/icon.png` (1024×1024 RGB) and `assets/splash-icon.png` (1024×1024) are the **stock Expo template placeholders**: a blue chevron on a blueprint grid, and concentric circles on a grid. They are not brand art. `app.json:7` uses the icon; there is **no `splash` key** and no splash plugin config (`app.json:42-66`). The generated `ios/` folder is git-ignored prebuild output (`.gitignore:51`). Its `SplashScreen.storyboard` is `systemBackground` (white or black, **not** the plaster colour) with an image view named `SplashScreen`. In the local prebuild, `ios/Inventory/Images.xcassets` contains only `AppIcon.appiconset`, so no logo is drawn and the launch screen is a plain system background. The shipped build may differ, so check the App Store binary if pixel continuity matters. The prebuild Info.plist sets `UIUserInterfaceStyle = Automatic`, iPhone portrait plus upside-down, and all four orientations on iPad (app-shell area).
- Native: the iOS 26 app icon should be authored with **Icon Composer** (`.icon`, layered for the Liquid Glass light, dark, tinted and clear appearances) and added to the target. Shipping the native app is a chance to replace the placeholder. A natural motif is the `Mark` (ink box + tape strip, `Mark.tsx`) (open question Q7).
- Launch screen: use an Info.plist `UILaunchScreen` dictionary (background colour only, matching `systemGroupedBackground`) instead of a storyboard. The RN boot screen (`BootScreen.tsx`, caption after 400 ms) belongs to the app-shell area.
- The Android icon assets (`android-icon-*.png`, `#E6F4FE` background, `app.json:22-27`) and `favicon.png` are out of scope.

---

## 13. RN/Expo workarounds that disappear natively

| Workaround | Where | Native |
|---|---|---|
| Hand-written relative time because Hermes lacks `Intl.RelativeTimeFormat` | `format.ts:31` | Still hand-written (for identical buckets), but backed by the catalog |
| Atkinson font loading, system-font fallback frame, re-render | `FontProvider.tsx:33-79` | System font |
| Manual Bold Text weight bump | `typography.ts:79-93`, `FontProvider.tsx:61-74` | Automatic |
| `includeFontPadding: false`, Android `fontWeight` quirks | `typography.ts:8-11,125` | n/a |
| `maxFontSizeMultiplier` per variant | `typography.ts:36-37` | `.dynamicTypeSize(...)` only where needed |
| Balanced line breaks via `textBreakStrategy` | `AppText.tsx:67-71,89-90` | Default text layout |
| iOS pressed overlay, Android ripple, manual focus ring | `PressFeedback.tsx` | Button styles, system focus |
| 48 dp touch target to satisfy Android | `theme.ts:100-106` | 44 pt HIG |
| SVG glyph set | `glyphs.tsx`, `Icon.tsx` | SF Symbols |
| `useSyncExternalStore` singleton for Reduce Motion | `motion.ts:50-86` | `@Environment(\.accessibilityReduceMotion)` |
| `LayoutAnimation` / `Keyboard.scheduleLayoutAnimation` | `motion.ts:94-111` | `withAnimation`, automatic keyboard avoidance |
| Android-only fade under Reduce Motion | `app/_layout.tsx:138` | System |
| Platform guard and promise catch around haptics | `haptics.ts:10-13` | n/a |
| `announceForAccessibility` because VoiceOver ignores live regions; TalkBack count announcements | `Banner.tsx:61-69`, `TextField.tsx:91-97`, `QuantityStepper.tsx:39-50` | `AccessibilityNotification.Announcement` where a change is not otherwise read. Stock controls announce their own value changes |
| Inset-shadow tape emboss gated on Android API 29 | `Tape.tsx:31` | n/a |
| JS tint cache | `color.ts:53-71` | Optional |
| `onLayout` measurement for spread gaps | `useSpreadGap.ts:24-34` | `Layout` protocol |

---

## 14. Open questions

1. **Q1, copy source of truth**: while Android and web stay on RN, `strings.ts` is shared. Should the native catalog be generated from `strings.ts` on every change (recommended: a script plus a CI check), or should native fork the copy?
2. **Q2, locale for dates and lists**: pin en-GB (identical to today: "2 September 2026", no serial comma) or follow the device locale ("September 2, 2026", "a, b, and c")?
3. **Q3, brand accent**: is "the brand accent" the **ink** tint (today's interactive colour) or the **tape yellow**? This spec recommends AccentColor = ink and named `Tape` colours for non-interactive brand marks, because yellow fails contrast as a control tint.
4. **Q4, space presets**: preset names (Garage, Wardrobe, Loft, Cellar) are English literals in `theme.ts:57-62`, not in `strings.ts`, and become stored data. Localise them?
5. **Q5, the `'cube'` default**: render it literally (today) or map it to a symbol? Rows with it only come from the schema default or the importer.
6. **Q6, SF Symbol choices** marked "?" or with a convention-versus-literal alternative (`move` → `folder`, `settings`, `backup`, `shield` → `hand.raised`, `spaces`, `cabinet`, `crate`, `layers`): confirm in the SF Symbols 7 app and with the user.
7. **Q7, app icon**: the RN app ships the Expo placeholder. Should the native update keep it for continuity or ship a real icon?
8. **Q8, toast and banner look**: these are custom RN components. Native toasts need a design (material capsule?). This belongs to the feedback area but drives `toast*` token decisions.
9. **Q9, search highlight colour**: keep the `mark` yellow wash (brand-adjacent) or use a system-style highlight?
10. **Q10, custom action and announcement attribute names** (`accessibilitySpeechQueueAnnouncement`, `accessibilitySpeechAnnouncementPriority`) and iOS 26 `ButtonRole.close`: verify against the iOS 26 SDK.
11. **Q11, English fallbacks outside `strings.ts`**: the household name `'Home'` and the device name `'This phone'` are hard-coded in session and pairing code (section 2.6(10)). The session one runs when a **persisted** session is read back. Should the native port keep the English literals, which are identical to today, or route them through `L10n` (for example `strings.tabs.home` for `'Home'`)? This must be decided together with the household area, which owns session parsing.
12. **Q12, SF Symbol `cabinet`**: if it depicts stacked drawers, it suits `visual_type = drawer` better than `cabinet` (section 5). Decide once it has been checked in the SF Symbols 7 app, and make sure the eight container types map to eight distinct symbols.

## 15. Dependencies on other areas

- **Database / persistence**: the `spaces.icon`, `spaces.color`, `containers.visual_type` and drop-zone rows (section 4) must be read unchanged. `safeColor` and the emoji rules depend on exact stored strings.
- **Errors**: `describeError(...).kind` decides every `.offline` / `.other` string pair. `strings.errors.*` titles and bodies are chosen by `src/ui/errors.ts`.
- **Item rows, search and home**: the composition rules in 2.6(8), `TotalLine`, `splitHighlight`, `useNow` ticking, and `delay.searchDebounce` / `searchSkeleton`.
- **Quantity stepper**: haptic cadence (7.2), adjustable accessibility (9.2(7)), min 0 and max 9999 (`src/core/quantity.ts`).
- **Capture and scanner**: camera chrome colours, shutter flash, reticle lock, `FOCUS_SPOT_MS`, the fast-status copy chain, flash and torch toggles.
- **Feedback (toast, banner)**: lifetimes, VoiceOver doubling, queued announcements, `a11y.availableAction`.
- **Household, backup and join**: `backupReason` mapping, the `ago`-based "Last used" / "Last backup", code formatting (`src/ui/code.ts`), and the `'Home'` / `'This phone'` fallbacks applied when the persisted session is parsed (`src/services/household/session.ts:23-24`).
- **Database / containers**: `visual_type` must stay a free `String` end to end, so unknown types survive an edit (section 4.4).
- **Recognition service**: the `suggestions.failedBody` keys equal its wire reason codes.
- **App shell and navigation**: tab labels and badge (`99+`), Add long-press custom action, boot caption delay, launch screen, `InfoPlist.xcstrings`, AccentColor.
- **Spaces and containers forms**: palette and emoji picker ordering rules, presets, type grid order, delete-impact copy selection (`src/ui/spaces/spaceSetup.ts:64-79`).

---

## Reviewer notes

An adversarial review checked this spec against the source on 2026-10-19. I re-read every in-scope file and evaluated `strings.ts` and `format.ts` with the repo's TypeScript compiler. Results:

- All 157 function-valued keys appear in 2.4 or 2.5.
- All 114 simple templates render exactly as the TS functions do.
- All the cited `strings.ts` line numbers are correct.
- The namespace counts (537 static, 157 functions) are correct.

The changes:

**Corrections**

1. **`backupReason` mapping was wrong (2.6(5)).** The spec said `not_found` and `quota_exceeded` fall back to `other`. They map to `backup.reasons.notFound` and `backup.reasons.quotaExceeded` (`src/ui/household/status.ts:62-65`, asserted in `status.test.ts` "has plain words for every failure"). I replaced the sentence with the full mapping table.
2. **Glyph count**: there are 47 glyphs, not 45 (`src/ui/icons/glyphs.tsx`, 47 keys).
3. **`whereSpoken` (9.1)**: the spec said only `null` is checked. The code uses JS truthiness (`a11y.ts:39`), so `""` also counts as unnamed and a whitespace-only name counts as named.
4. **Haptic `tap` in capture (7.2)**: it fires when the photo URI comes back, **before** the item is saved (`app/capture/index.tsx:270-273`), not on "shot saved".
5. **`stepSwap` (8.1)**: an opacity fade-in, not a push or slide (`app/item/new.tsx:312-325`). **`expand` / `animateNextLayout`**: `LayoutAnimation.create(…, 'easeInEaseOut', 'opacity')` animates moves and resizes and fades insertions and removals. It is not a pure cross-fade. I added its five call sites.
6. **`whereCard` note (6)**: the "never smaller than the question" comment (`typography.ts:43-46`) is about `where` vs `name`, not `whereCard` vs `itemTitle`. I reworded it. The `typography.test` assertion is equality, not ≥.
7. **Dynamic Type cap mapping (6)**: the table is the largest step that does not exceed the cap, not the nearest step. I reworded it.
8. **Citations**: `app/onboarding.tsx:19` → `:18` (twice); `ToastProvider.tsx:171-173` → `:170-172`. I also extended `TabBar.tsx:185-189` to `:183-189` so it covers the Add label.
9. **`L10n` naming**: I changed `L10n.tabs` / `L10n.a11y` to `L10n.Tabs` / `L10n.A11y` to match the enum style used elsewhere.

**Additions**

10. **Persisted-data rules**:
    - Swatch membership uses `safeColor` equality, so a stored `#5b8def` is Blue and is never rewritten, and junk renders as the grey "Current colour".
    - Emoji-picker membership uses the untrimmed stored string, and a blank stored icon selects no tile.
    - `visual_type` lookups are case-sensitive, unknown types survive an edit because `TypeGrid` selects nothing and the raw string is compared, so the model must keep `visual_type` as a `String`.
    - The unnamed-container label differs by call site (trim vs `??`).
11. **`safeColor` in Swift**:
    - `trimmingCharacters(.whitespacesAndNewlines)` also strips U+0085, which JS keeps, so the exact JS trim set is now listed.
    - `Character.isHexDigit` accepts fullwidth digits, so matching must be ASCII-only.
    - I added extra vectors, computed by running the TS.
12. **`onColor`**: I filled in all six palette results (`#12161C` for each, with contrast ratios) and a computed tint table for both schemes and both surfaces.
13. **`longDate`**: the calendar must be pinned to Gregorian as well as the locale. `Date.FormatStyle` otherwise follows the device calendar.
14. **`ago`**:
    - The signature is now in `Int64` milliseconds.
    - New edge cases: 360 to 364 days read "12 months ago"; `useNow` ticks on only four screens and every other caller computes at render.
15. **Composition outside `strings.ts` (2.6(8))**: I added `WhereList.tsx:80`, `PlacePicker.tsx:459`, `TextField.tsx:80-86,103-106`, `NameItInline.tsx:231-235`, `PlaceRows.tsx:136,203`, `containerRules.ts:113` and `Banner.tsx:61`. I rewrote the item-row second line precisely from `ItemRow.tsx:71-110`.
16. **English literals outside `strings.ts` (new 2.6(10))**: `'Home'` (three sites, one in persisted-session parsing) and `'This phone'`. New open question Q11.
17. **Accessibility**:
    - Some keys are reached through object spread, so `errors.*` must keep the `{title, body}` shape (2.1).
    - The Fabric artifact that exposes "increment" and "decrement" as custom actions is not to be ported.
    - Banners are not announced when `live == 'off'`, are not queued, and drop the title when there is none.
    - The search summary is announced only on the search key.
    - The RN queue flag is `UIAccessibilitySpeechAttributeQueueAnnouncement`.
    - The Quick Snap custom action also fires its haptic.
    - The spoken tab badge uses the full count, while the visible badge caps at `99+`.
18. **Haptics detail**:
    - The hold-to-repeat start fires one full step with a haptic, then the counter resets.
    - No haptic fires when the value does not change.
    - VoiceOver adjust also ticks.
    - `item/new.tsx:350` has no already-selected guard.
    - The "no haptic" list is extended (successful edits, unbound scanned label, backup success).
19. **Motion detail**:
    - The toast enters with a fade plus an 8 pt rise.
    - The search skeleton mounts at 420 ms so that it appears at 600 ms.
    - A toast may carry a custom duration.
    - Reduce Motion also disables programmatic scroll animation and the toast swipe spring.
20. **Smaller items**:
    - `inlineIconSize` floors at 1× and rounds; I listed its three users.
    - `spreadGap` is also used by `TypeGrid` (72 pt, 4 or 3 columns).
    - `Button` loading replaces the leading icon with the spinner, and the busy and disabled states differ.
    - `container.sub` counts rows and is replaced by the bare type when the list is empty.
    - `badChars` lists characters in order of first appearance.
    - `PhotosPicker` makes `libraryDeniedBody` unreachable.
    - The launch storyboard's image set is absent in the local prebuild.
    - SF Symbol notes: `crate` → `square.grid.3x3` is more literal; the SF `cabinet` symbol might show drawers (new Q12).
21. **Tests (11)**: I added the copy-pinning tests that were missing:
    - `status.test` › `deviceMeta` (uses `ago`)
    - `status.test` › both `backupSummary` tests
    - the explicit `backupReason` vectors
    - `join.test` › `codeProblem` ("U %", 18, 27)
    - `homeList.test` › "counts places, not items…"

    I also added Swift-only tests (e) to (j).

**Completeness / consistency pass (cross-spec critic)**

22. **2.7 `NSPhotoLibraryUsageDescription`**: this section called the key optional once `PhotosPicker` is used. It must stay, because the QR label share sheet offers Save Image, which writes to the photo library (02 §9.4; 05 §16.2 already kept it).
23. **4.1 / Q3 brand accent**: `02-device-storage-migration.md` §9.8 and `09-app-shell-lifecycle-config.md` Q18 treated tape yellow as the accent; this spec's Q3 (ink as `AccentColor`, named `Tape`) is the single tracked decision, and 02 now says so.
24. **Coverage check**: `IconButton`, `PressFeedback`, `Button`, `AppText`, `Icon`, `glyphs.tsx`, `typography.ts`, `fontContext.ts`, `theme.ts`, `tokens.ts`, `color.ts`, `motion.ts`, `haptics.ts`, `a11y.ts`, `format.ts`, `strings.ts`, `useLayoutScale`, `useSpreadGap`, `Mark`, `Tape` are covered here or in 06/07/09; every exported symbol is referenced.

**Unchanged but worth noting**: the RN app has no persisted state of its own in this area (no AsyncStorage, keychain or file writes in these modules). The in-place-upgrade risk here is limited to reading `spaces.icon`, `spaces.color` and `containers.visual_type` byte-for-byte and never normalising them on write. Sections 2.6, 4.2, 4.3 and 4.4 now state that rule explicitly.
