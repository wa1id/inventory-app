import type { ContainerVisualType } from '@/db/types';

/**
 * Alphabet chosen so a code stays readable when handwritten on a label or read
 * aloud: no O/0, I/1, or similar confusable pairs.
 */
const ALPHABET = '23456789ABCDEFGHJKLMNPQRSTUVWXYZ';
const SUFFIX_LENGTH = 4;

const PREFIXES: Record<ContainerVisualType, string> = {
  box: 'BOX',
  drawer: 'DRW',
  shelf: 'SHF',
  cabinet: 'CAB',
  bin: 'BIN',
  bag: 'BAG',
  crate: 'CRT',
  other: 'CTR',
};

function randomSuffix(): string {
  let out = '';
  for (let i = 0; i < SUFFIX_LENGTH; i += 1) {
    out += ALPHABET[Math.floor(Math.random() * ALPHABET.length)];
  }
  return out;
}

/**
 * Builds a human-friendly container code such as `BOX-7K2M`.
 *
 * Uniqueness is enforced by the UNIQUE constraint on `containers.short_code`;
 * the caller retries with a fresh candidate on collision.
 */
export function generateShortCode(visualType: ContainerVisualType): string {
  return `${PREFIXES[visualType] ?? PREFIXES.other}-${randomSuffix()}`;
}

/** Codes are compared and searched case-insensitively and dash-insensitively. */
export function normalizeShortCode(input: string): string {
  return input
    .trim()
    .toUpperCase()
    .replace(/[\s-]+/g, '');
}
