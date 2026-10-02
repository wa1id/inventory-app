import type { QrBinding } from '@/db/types';
import { strings } from '@/i18n/strings';
import type { ConfirmOptions } from '@/ui/confirm';
import { describeError } from '@/ui/errors';

/**
 * The rules behind scanning a label (the Scan tab) and opening one from a
 * link (`/c/<token>`), kept pure (no React Native) so they are tested in Node.
 */

/**
 * What a sentence calls a container: its name, or else the code on its
 * label, which is what is written on the box (entities §14.13).
 */
export function labelFor(container: { name: string | null; shortCode: string }): string {
  return container.name?.trim() ? container.name : container.shortCode;
}

/**
 * The `token` of `/c/<token>` as one string. A link that repeats the
 * parameter arrives as an array; the first one is the label. Whatever it is,
 * the repository decides whether it is one of ours.
 */
export function tokenParam(value: string | string[] | undefined): string {
  const first = Array.isArray(value) ? value[0] : value;
  return first?.trim() ?? '';
}

export interface BindPlan {
  /**
   * False when the container already carries this very label: it was linked
   * on another phone while this one was choosing, so there is nothing to write.
   */
  write: boolean;
  /** Asked first when the container's own sticker would stop working. */
  confirm: ConfirmOptions | null;
}

/**
 * Linking a new label to the container someone picked (spec §5.18).
 *
 * A container has one label at a time, so linking a new one retires the old
 * sticker. That is asked as a question with the impact spelled out (capture
 * §10.15); the old title, "Move this label?", described a different case
 * (§13.16). `existing` comes from `qr.getByContainer`, because the picker's
 * container list carries no label token.
 */
export function planBind(
  existing: Pick<QrBinding, 'token'> | null,
  token: string,
  label: string,
): BindPlan {
  if (!existing) return { write: true, confirm: null };
  if (existing.token.toLowerCase() === token.toLowerCase()) return { write: false, confirm: null };
  return {
    write: true,
    confirm: {
      title: strings.deepLink.replaceTitle(label),
      body: strings.deepLink.replaceBody(label),
      confirmLabel: strings.deepLink.replace,
    },
  };
}

/**
 * The error toast when a label could not be linked, in plain words (B8). The
 * label stays on screen with the picker, so trying again needs no rescan.
 */
export function linkFailureMessage(cause: unknown): string {
  const { kind } = describeError(cause, 'label', 'container');
  if (kind === 'gone') return strings.deepLink.containerGone;
  return strings.deepLink.linkFailed(kind === 'offline');
}
