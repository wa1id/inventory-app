/**
 * Joining a household, as plain logic: checking a typed code and name before
 * anything is sent, the phone name to suggest, and what a refusal means.
 * Pure (no React Native), so it is tested in Node.
 */
import { strings } from '@/i18n/strings';
import { HouseholdHttpError } from '@/services/household/client';
import { invalidCodeChars } from '@/ui/code';
import { describeError } from '@/ui/errors';

/** Household codes and recovery codes are both 16 bytes of Crockford base32. */
export const CODE_LENGTH = 26;

export type CodeProblem =
  { kind: 'chars'; chars: string } | { kind: 'length'; count: number } | null;

/**
 * What is wrong with a normalised code, if anything. Characters first: a code
 * with a U in it is wrong whatever its length, and saying so points at the
 * character to check.
 */
export function codeProblem(normalised: string, length: number = CODE_LENGTH): CodeProblem {
  const bad = invalidCodeChars(normalised);
  if (bad.length > 0) return { kind: 'chars', chars: bad.join(' ') };
  if (normalised.length !== length) return { kind: 'length', count: normalised.length };
  return null;
}

export interface JoinErrors {
  code?: string;
  name?: string;
}

/**
 * Checked on press, not while typing, so a half-typed code is never an error.
 * Stricter than the old "8 characters and a name" rule (`household.tsx:154`):
 * a code of the wrong length cannot be right, and saying how long it is saves
 * a round trip to the home server and a vaguer refusal.
 */
export function validateJoin(normalisedCode: string, name: string): JoinErrors {
  const errors: JoinErrors = {};
  const problem = codeProblem(normalisedCode);
  if (problem?.kind === 'chars') errors.code = strings.join.badChars(problem.chars);
  if (problem?.kind === 'length') errors.code = strings.join.wrongLength(problem.count);
  if (name.trim() === '') errors.name = strings.join.nameRequired;
  return errors;
}

/** Names that say nothing about whose phone it is; iOS 16+ reports "iPhone" without an entitlement. */
const GENERIC_NAMES = new Set(['iphone', 'ipad', 'android']);

/**
 * The name to prefill: the phone's own name ("Anna’s iPhone") when it has a
 * real one, otherwise nothing, so the field asks for one instead of
 * suggesting "This phone" (the old default, which every phone then shared).
 */
export function suggestedPhoneName(deviceName: string | null | undefined): string {
  const name = (deviceName ?? '').trim();
  return GENERIC_NAMES.has(name.toLowerCase()) ? '' : name;
}

export type JoinFailure = 'refused' | 'offline' | 'other';

/**
 * Why joining did not work. A 401 from pairing is a code the home server did
 * not accept (pairing carries no token, so it is never a removed phone);
 * the unreachable cases follow `describeError`, which knows Cloudflare's
 * "home box is down" answers.
 */
export function joinFailure(cause: unknown): JoinFailure {
  if (
    cause instanceof HouseholdHttpError &&
    (cause.status === 401 || cause.code === 'unauthorized')
  ) {
    return 'refused';
  }
  return describeError(cause, 'join').kind === 'offline' ? 'offline' : 'other';
}

/** The host of the home server's address, for "Home server: inventory.wystudio.be". */
export function serverHost(origin: string): string {
  const host = origin
    .trim()
    .replace(/^[a-z][a-z0-9+.-]*:\/\//i, '')
    .replace(/[/?#].*$/, '');
  return host || origin;
}
