/**
 * Household and recovery codes as a person types them.
 *
 * Both are Crockford base32, which drops I, L, O and U so the usual misreads
 * cannot make a different valid code. Typing folds them back the same way the
 * home server (`home-server/src/base32.ts`) and the recovery code
 * (`src/services/account/base32.ts`) decode them, so lower case, missing
 * hyphens and the look-alikes all work. Pure, so it is tested in Node.
 */

const VALID = /^[0-9A-HJKMNP-TV-Z]$/;

/** Strip whitespace and hyphens, uppercase, and fold I and L to 1 and O to 0. */
export function normaliseCode(input: string): string {
  return input
    .replace(/[\s-]+/g, '')
    .toUpperCase()
    .replace(/[IL]/g, '1')
    .replace(/O/g, '0');
}

/** Characters in a normalised code that no code can contain (U, punctuation), each once. */
export function invalidCodeChars(normalised: string): string[] {
  return [...new Set([...normalised].filter((char) => !VALID.test(char)))];
}

/** Groups of five joined by hyphens, as the code is printed: "MMWKY-M2H78-…". */
export function formatCode(normalised: string): string {
  return normalised.match(/.{1,5}/g)?.join('-') ?? '';
}
