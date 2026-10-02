import { strings } from '@/i18n/strings';
import { describeError } from '@/ui/errors';

/**
 * The rules behind the Spaces tab and the space and container forms, kept
 * pure (no React Native) so they are tested in Node.
 */

/** What a space form edits. */
export interface SpaceValues {
  name: string;
  icon: string;
  color: string;
}

/** A container as people read it: its name, or else the code on its label. */
export function containerLabel(container: { name: string | null; shortCode: string }): string {
  return container.name ?? container.shortCode;
}

/**
 * Containers in a space sort by label, case- and accent-insensitively, like
 * the desk's `byLabel` (`home-server/web/app.js`). The repository returns them
 * newest first, which made a long space impossible to scan.
 */
export function byContainerLabel(
  a: { name: string | null; shortCode: string },
  b: { name: string | null; shortCode: string },
): number {
  return containerLabel(a).localeCompare(containerLabel(b), 'en', { sensitivity: 'base' });
}

function nameKey(name: string): string {
  return name.trim().toLocaleLowerCase('en');
}

/**
 * The names already used by spaces, compared without case or surrounding
 * spaces. A quick-add preset whose name is here is shown as "Already added",
 * so a second tap on another visit no longer makes a second Garage
 * (entities §1).
 */
export function takenSpaceNames(spaces: readonly { name: string }[]): ReadonlySet<string> {
  return new Set(spaces.map((entry) => nameKey(entry.name)));
}

export function isNameTaken(name: string, taken: ReadonlySet<string>): boolean {
  return taken.has(nameKey(name));
}

/**
 * How many QR labels deleting a space unlinks. Over HTTP the impact always
 * reports 0 labels (`httpRepositories.ts`, `deletionImpact`), so the
 * containers' own `qrToken`s are counted too and the larger number wins; a
 * printed label that stops working is exactly what the confirm must mention.
 */
export function labelsInSpace(
  impactLabels: number,
  containers: readonly { qrToken: string | null }[],
): number {
  const linked = containers.filter((container) => Boolean(container.qrToken)).length;
  return Math.max(impactLabels, linked);
}

/** The space delete confirm's body: everything that goes with it, spelled out (#4). */
export function spaceDeleteBody(
  impact: { containerCount: number; itemCount: number },
  labels: number,
): string {
  if (impact.containerCount === 0 && impact.itemCount === 0 && labels === 0) {
    return strings.spaceForm.deleteEmpty;
  }
  return strings.spaceForm.deleteBody(impact.containerCount, impact.itemCount, labels);
}

/** The container delete confirm's body, with the label it unlinks (#4). */
export function containerDeleteBody(impact: { itemCount: number; hasQrBinding: boolean }): string {
  return impact.itemCount === 0
    ? strings.containerForm.deleteEmpty(impact.hasQrBinding)
    : strings.containerForm.deleteBody(impact.itemCount, impact.hasQrBinding);
}

/**
 * Whether a space form differs from where it started. Surrounding spaces in
 * the name do not count: the repository trims them away on save.
 */
export function spaceValuesChanged(values: SpaceValues, initial: SpaceValues): boolean {
  return (
    values.name.trim() !== initial.name.trim() ||
    values.icon !== initial.icon ||
    values.color !== initial.color
  );
}

/** What the container form edits. The label code is not here: it never changes (entities §14.13). */
export interface ContainerValues {
  name: string;
  visualType: string;
  spaceId: string;
}

/** Whether a container form differs from the stored container; an emptied name counts. */
export function containerValuesChanged(values: ContainerValues, initial: ContainerValues): boolean {
  return (
    values.name.trim() !== initial.name.trim() ||
    values.visualType !== initial.visualType ||
    values.spaceId !== initial.spaceId
  );
}

/**
 * A refresh that failed while data stayed on screen gets its own "could not
 * be refreshed" banner, except when the reason already has one: the
 * connection banner explains an unreachable home server, and the
 * removed-phone layer covers a revoked one (spec §5.0).
 */
export function needsRefreshBanner(refreshFailed: boolean, cause: unknown): boolean {
  if (!refreshFailed) return false;
  const { kind } = describeError(cause);
  return kind !== 'offline' && kind !== 'revoked';
}

/** Whether a failed write was the connection, for "Check the connection" wording. */
export function isOffline(cause: unknown): boolean {
  return describeError(cause, 'save').kind === 'offline';
}
