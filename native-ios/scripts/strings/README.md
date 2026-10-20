# strings: the String Catalog generator

`generate.mjs` turns the React Native copy in `src/i18n/strings.ts` (and the
relative-time wording in `src/i18n/format.ts`), plus the native-only copy in
`native/<area>.ts`, into the native app's String Catalog and its typed
accessors. `strings.ts` stays the source of truth while Android and web still
use it (DECISIONS U9), so re-run the script whenever it or a native file
changes and commit the outputs.

```sh
# In a git worktree, link the main checkout's dependencies first (gitignored):
ln -s /home/walid/inventory-app/node_modules node_modules

node native-ios/scripts/strings/generate.mjs              # write the outputs
node native-ios/scripts/strings/generate.mjs --check      # exit 1 if any output is stale
node native-ios/scripts/strings/generate.mjs --validate   # build and verify everything, write nothing
node --test native-ios/scripts/strings/generate.test.mjs  # the generator's own tests
```

## Native-only copy (`native/<area>.ts`)

Copy for states only the native app has (a keychain that cannot be read, the
Restore offer, anything RN never showed) never goes into `strings.ts`. Each
screen area writes it in its own file, named after the area: `home.ts`,
`account.ts`, `labels.ts`, `places.ts`, `item.ts`, `add.ts` or `capture.ts`.
A file is shaped like `strings.ts`, may import `plural` and `sentenceList`
from `@/i18n/format`, and is merged into the same tree at its own paths:

```ts
// native/account.ts
export const strings = {
  backup: {
    unreadable: {
      /** Doc comments become the catalog comment and the Swift doc. */
      title: 'Backup can’t be checked right now',
    },
  },
};
// → catalog key backup.unreadable.title, L10n.Backup.Unreadable.title
```

- Its groups join the `strings.ts` groups of the same path (`backup` above),
  so the copy sits next to the screen's other strings in `L10n`.
- Everything else must be new: the script **fails** on a key that already
  exists in `strings.ts` or in another native file, and on a file not named
  after an area.
- Strings, format strings and plurals or substitutions work as for
  `strings.ts`, and every entry goes into the parity fixture evaluated by the
  real TS. `PLANS` is not open to native files: instead of a boolean or zero
  branch, give each branch its own key and choose between them in Swift (the
  script says so when it meets one).
- Each native entry's doc ends with "Native only (native/<area>.ts)."
- Match the voice of `strings.ts`: short, plain, no jargon, sentence case,
  British spelling, typographic quotes and apostrophes (`’`, `“…”`).

Areas each edit only their own file and regenerate. When branches merge, the
generated outputs may conflict; resolve them by re-running the script.

It needs only Node and the repo's `typescript` package. It transpiles both TS
files in memory (`ts.transpileModule`), runs them, and reads parameter names,
types and doc comments from the syntax tree.

## Outputs (all generated; do not edit)

| File | What |
|---|---|
| `Packages/InventoryKit/Sources/InventoryStrings/Resources/Localizable.xcstrings` | The catalog, English only (the script prints the key count) |
| `Packages/InventoryKit/Sources/InventoryStrings/L10n.swift` | `public enum L10n`, one member per strings.ts and native entry, plus the internal `…Keys` entries the hand-written code composes |
| `Packages/InventoryKit/Tests/InventoryStringsTests/Fixtures/strings-parity.json` | Every strings.ts and native entry evaluated by the real TS over a spread of arguments, plus format.ts vectors |
| `Packages/InventoryKit/Tests/InventoryStringsTests/StringsParityDispatch.swift` | Maps each path to its Swift accessor for the parity test |

Hand-written, next to the generated code: `L10n+Logic.swift` (the 28 functions
that branch), `L10nRuntime.swift` (lookup), `Format.swift` (format.ts),
`JSText.swift` (JS `toLowerCase` and `charAt(0).toUpperCase()` semantics).

## Keys and accessors

- The catalog key is the dotted TS path: `boot.opening`, `errors.offline.title`,
  `onboarding.facts.0`. Lookup maps get one key per entry:
  `entities.typeNames.box`, `entities.colourNames.5B8DEF` (hex without `#`),
  `entities.iconNames.sofa` (a slug, because the TS key is an emoji),
  `suggestions.failedBody.rate_limited` (the wire code).
- Swift mirrors the tree: `L10n.Common.cancel`, `L10n.Errors.Offline.title`,
  `L10n.Tabs.waitingA11y(count:)`, `L10n.Rows.itemA11y(name:where:quantity:)`.
  Lookup maps also have a subscript that matches keys exactly, as JS does:
  `L10n.Entities.TypeNames["box"]`, `L10n.Entities.IconNames["🛋️"]`.
- `format.ago.*` keys back `Format.ago` (spec 08 §3.3); they are not in strings.ts.

## How function-valued strings become catalog entries

The script calls each function with sentinel arguments and turns the result into
a format string (`%@` for text, `%lld` for counts; positional when there is more
than one argument). It then calls it again with each count set to 1. When the
wording changes beyond the number (`plural()`, `count === 1 ? … : …`), that count
becomes a plural variation (one count decides the sentence) or a substitution
(several arguments). Everything else stays a plain format.

Functions with other logic are listed in `PLANS` in `generate.mjs`: booleans
(`offline`, `hasLabel`, `on`, `expanded`), zero branches (`entities.contents`,
`search.summary`, `capture.doneA11y`, …) and the lower-cased type names. Each
branch gets its own key, for example `quantity.notSavedNamed.offline` and
`.other`, or `entities.unnamedContainer.box`; the branching is hand-written in
`L10n+Logic.swift`, the same as the TS. `rows.addedShort` has no key: it only
upper-cases the first letter of its argument.

Before writing anything, the script renders every derived entry the way
Foundation will and compares it with the TS output for every test argument,
and checks that each plan covers every argument set exactly once. A change in
strings.ts that the plans no longer describe stops the script with a message
that names the entry.

## Runtime: SwiftPM does not compile String Catalogs

Xcode compiles `Localizable.xcstrings` into `.strings` and `.stringsdict` files
in the app's `InventoryKit_InventoryStrings.bundle`. **The SwiftPM command line
(`swift test`, `scripts/mac.sh test`) only copies the `.xcstrings` file into the
bundle**, so every lookup there misses. To make both work:

- Every accessor calls `Bundle.module.localizedString(forKey:value:table:)` with
  the exact English as the fallback value. For plural entries the fallback is
  resolved in Swift first (`one` for exactly 1, like the TS), so under
  `swift test` the output is still exactly the strings.ts output.
- Arguments are formatted with `String(format:locale:arguments:)` and **no
  locale** (`nil`). This matters, because JS template literals neither group
  digits nor touch the text:
  - With any locale, `en_US_POSIX` included, Foundation wraps each `%@` argument
    in U+2068…U+2069 bidi isolates once right-to-left text is involved (a Hebrew
    or Arabic name, a bidi mark). On iOS the other arguments of that sentence are
    wrapped too: `In ⁨שלום⁩, label ⁨Garage⁩`.
  - Every locale except `en_US_POSIX` also groups digits (`1,234`, `1 234`).
  - With no locale, a compiled plural entry takes the plural rule of its own
    table's language (English here, so `one` is exactly 1), not the device's. A
    French phone still reads "0 items" and a Russian one "21 items"; with
    `locale: .current` they would read "0 item" and "21 item".
  - Measured with Xcode 26.3 on macOS 15.7 and the iOS 26 simulator.
- `String(localized:)` is not used. Its interpolated integers are always grouped
  by locale, and its arguments come from the default value, which cannot hold
  plural variants.

The tests in `StringsParityTests` cover every path:

- `every accessor reproduces strings.ts` runs each accessor as the app does
  (`Bundle.module` with the fallback), then again against a bundle without a
  catalog, so the English fallback is checked in every build.
- `the compiled catalog reproduces strings.ts through every accessor` (macOS
  only) compiles the catalog with Xcode's own `xcstringstool` into a temporary
  bundle and runs every accessor against it with the fallback turned off. It also
  checks that every catalog key is read by some accessor, and that every key an
  accessor reads exists. The app's `InventoryKit_InventoryStrings.bundle` holds
  the same `.strings` and `.stringsdict` content as this output.
- `the module's compiled catalog reproduces strings.ts through every accessor`
  makes the same strict run against `Bundle.module` itself, when Xcode built it.
  `swift test` skips it. To run it on this checkout's iOS simulator, optionally
  under another device language:

  ```sh
  native-ios/scripts/mac.sh shell 'cd Packages/InventoryKit && xcodebuild test \
    -scheme InventoryKit-Package -destination "id=$udid" \
    -only-testing:InventoryStringsTests -testLanguage ru -testRegion RU'
  ```

  It passes under the simulator's default locale, `ru_RU` and `fr_FR`.

Xcode 26 also generates internal `LocalizedStringResource` symbols for the
catalog in the InventoryStrings target. They are unused and harmless.
