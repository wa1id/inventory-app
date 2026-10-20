/**
 * Native-only copy for the home area (Home, Spaces, Drop zone): states only the
 * native app has. generate.mjs merges this tree into the strings.ts tree, so
 * `search.corrected.showing` becomes `L10n.Search.Corrected.showing`. Never copy
 * these into src/i18n/strings.ts (DECISIONS U9); see native-ios/scripts/strings/README.md.
 */
export const strings = {
  search: {
    /**
     * A search found nothing, so its misspelt or unknown words were corrected
     * against the words the inventory itself uses, and the corrected search is
     * shown instead. Above the results, and spoken before the results summary.
     */
    corrected: {
      showing: (typed: string, shown: string) => `No results for “${typed}”. Showing “${shown}” instead.`,
    },
  },
};
