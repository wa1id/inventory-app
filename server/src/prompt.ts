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
  '- confidence: 0 to 1, your honest certainty about `name`.',
  '',
  'Set identified=false when the photo is too dark, too blurry, too close, empty,',
  'or shows something you cannot name. Do not invent an object to fill the field —',
  'a wrong answer is worse than none, because the user must then notice and undo it.',
].join('\n');

export const USER_PROMPT = 'Identify the item in this photo.';

/**
 * The turn given to the model, optionally anchored to a name the user supplied.
 *
 * A hint arrives when the user rejected our suggested name and typed their own.
 * The rest of the suggestion was derived from a wrong identification, so asking
 * again with the photo alone would just reproduce it — the corrected name has
 * to steer the second pass.
 *
 * The hint is user-authored text entering a prompt, so it is normalized to a
 * single short line by `parseRequest` before it gets here, and every field of
 * the answer is still schema-checked and clamped by `toRawSuggestion`. The
 * worst a crafted name can do is describe a different household object.
 */
export function userPrompt(nameHint?: string): string {
  if (!nameHint) return USER_PROMPT;

  return [
    `The user looked at your previous answer and corrected the item's name to: "${nameHint}".`,
    '',
    'That name is authoritative. They are holding the object; you only have a photo of it.',
    'Describe THAT item: derive its category and tags, using the photo as supporting',
    'evidence for condition, size, brand, and included accessories.',
    '',
    'Overrides for this turn:',
    '- name: return the corrected name exactly as given.',
    '- identified: true unless the name is meaningless. An unclear photo is no longer a reason',
    '  to answer false — the name already tells you what the object is.',
    '- confidence: your certainty in the supporting fields, since the name is not your guess.',
  ].join('\n');
}

/**
 * Trims and clamps model output before it reaches the wire contract.
 *
 * `nameHint` wins over whatever the model echoed back: the user's own wording
 * is what they will see in the field, and a model that "helpfully" reformats it
 * would look like the app overwriting their correction.
 */
export function toRawSuggestion(extraction: Extraction, nameHint?: string) {
  const clean = (value: string | null): string | null => {
    const trimmed = value?.trim();
    return trimmed ? trimmed.slice(0, 80) : null;
  };

  return {
    name: clean(nameHint ?? extraction.name),
    category: clean(extraction.category),
    tags: Array.from(
      new Set(
        extraction.tags
          .map((tag) => tag.trim().toLowerCase())
          .filter((tag) => tag.length > 0 && tag.length <= 40),
      ),
    ).slice(0, 8),
    // A provider that returns a nonsense confidence gets clamped, not trusted.
    confidence: Math.min(1, Math.max(0, extraction.confidence)),
  };
}
