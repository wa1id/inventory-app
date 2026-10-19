# strings: the String Catalog generator

`generate.mjs` turns the React Native copy in `src/i18n/strings.ts` (and the
relative-time wording in `src/i18n/format.ts`) into the native app's String
Catalog and its typed accessors. `strings.ts` stays the source of truth while
Android and web still use it (DECISIONS U9), so re-run the script whenever it
changes and commit the outputs.

```sh
# In a git worktree, link the main checkout's dependencies first (gitignored):
ln -s /home/walid/inventory-app/node_modules node_modules

node native-ios/scripts/strings/generate.mjs           # write the outputs
node native-ios/scripts/strings/generate.mjs --check   # exit 1 if any output is stale
```

It needs only Node and the repo's `typescript` package. It transpiles both TS
files in memory (`ts.transpileModule`), runs them, and reads parameter names,
types and doc comments from the syntax tree.

## Outputs (all generated; do not edit)

| File | What |
|---|---|
| `Packages/InventoryKit/Sources/InventoryStrings/Resources/Localizable.xcstrings` | The catalog: 742 keys, English only |
| `Packages/InventoryKit/Sources/InventoryStrings/L10n.swift` | `public enum L10n`, one member per strings.ts entry, plus the internal `…Keys` entries the hand-written code composes |
| `Packages/InventoryKit/Tests/InventoryStringsTests/Fixtures/strings-parity.json` | Every strings.ts entry evaluated by the real TS over a spread of arguments, plus format.ts vectors |
| `Packages/InventoryKit/Tests/InventoryStringsTests/StringsParityDispatch.swift` | Maps each strings.ts path to its Swift accessor for the parity test |

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
- Arguments are formatted with `String(format:locale:arguments:)` and the
  `en_US_POSIX` locale. This matters: with any other locale Foundation groups
  numbers (`1,234`, `1.234`, Arabic digits) and takes the plural rule from that
  locale (French reads 0 as singular). JS template literals never group, so
  `POSIX` is the only locale that matches. Revisit it when the app is localised.
- `String(localized:)` is not used. Its interpolated integers are always grouped
  by locale, and its arguments come from the default value, which cannot hold
  plural variants.

The tests cover both paths. `StringsParityTests` checks every accessor against
the TS output (the fallback path under `swift test`), and then compiles the
catalog with Xcode's own `xcstringstool` into a temporary bundle and runs every
accessor again against it with the fallback turned off. That second run also
checks that every catalog key is read by some accessor and that every key an
accessor reads exists. The same strict run inside the app on the simulator
(against the app's real bundle) passed all 2424 cases and resolved all 742 keys
when this was set up.

Xcode 26 also generates internal `LocalizedStringResource` symbols for the
catalog in the InventoryStrings target. They are unused and harmless.
