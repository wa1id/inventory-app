import { z } from 'zod';

/**
 * Extraction schema and prompt, shared by every adapter.
 *
 * Kept out of the adapters on purpose: two providers pointed at the same photo
 * should be answering the same question, or comparing them tells you nothing.
 * An adapter's job is transport and error classification, not prompt design.
 */
export const extractionSchema = z.object({
  /** False when the model genuinely cannot tell what the object is. */
  identified: z.boolean(),
  name: z.string().nullable(),
  category: z.string().nullable(),
  tags: z.array(z.string()),
  /** Second-hand replacement value, not retail. */
  estimatedValue: z.number().nullable(),
  /** ISO 4217, uppercase. */
  currency: z.string().nullable(),
  confidence: z.number(),
});

export type Extraction = z.infer<typeof extractionSchema>;

export const SYSTEM_PROMPT = [
  'You identify household objects in photos for a personal home-inventory app.',
  'The user has photographed one item while putting it into a box or drawer.',
  '',
  'Return the single most prominent object. Ignore the background, the container,',
  'the surface it rests on, and any hands holding it.',
  '',
  'Field rules:',
  '- name: what an owner would call it, specific but short. "Cordless drill", not',
  '  "a yellow and black power tool". Include a brand only if clearly legible.',
  '- category: one broad grouping, e.g. "Power Tools", "Kitchenware", "Clothing".',
  '- tags: up to 5 lowercase keywords someone might later search for. No duplicates',
  '  of the name or category.',
  '- estimatedValue: approximate SECOND-HAND replacement value as a number, or null',
  '  when you cannot reasonably tell. Never guess wildly.',
  '- currency: ISO 4217 code for that value, or null when estimatedValue is null.',
  '- confidence: 0 to 1, your honest certainty about `name`.',
  '',
  'Set identified=false when the photo is too dark, too blurry, too close, empty,',
  'or shows something you cannot name. Do not invent an object to fill the field —',
  'a wrong answer is worse than none, because the user must then notice and undo it.',
].join('\n');

export const USER_PROMPT = 'Identify the item in this photo.';

/** Trims and clamps model output before it reaches the wire contract. */
export function toRawSuggestion(extraction: Extraction) {
  const clean = (value: string | null): string | null => {
    const trimmed = value?.trim();
    return trimmed ? trimmed.slice(0, 80) : null;
  };

  return {
    name: clean(extraction.name),
    category: clean(extraction.category),
    tags: Array.from(
      new Set(
        extraction.tags
          .map((tag) => tag.trim().toLowerCase())
          .filter((tag) => tag.length > 0 && tag.length <= 40),
      ),
    ).slice(0, 8),
    estimatedValue:
      extraction.estimatedValue !== null && Number.isFinite(extraction.estimatedValue)
        ? Math.max(0, extraction.estimatedValue)
        : null,
    currency: /^[A-Za-z]{3}$/.test(extraction.currency ?? '')
      ? extraction.currency!.toUpperCase()
      : null,
    // A provider that returns a nonsense confidence gets clamped, not trusted.
    confidence: Math.min(1, Math.max(0, extraction.confidence)),
  };
}
