import { ConflictError } from '@/core/conflict';
import { strings } from '@/i18n/strings';
import { HouseholdHttpError } from '@/services/household/client';

export type ErrorKind = 'offline' | 'revoked' | 'conflict' | 'gone' | 'photo' | 'server' | 'local';
export type ErrorContext = 'read' | 'save' | 'move' | 'quantity' | 'delete' | 'label' | 'join';
export type ErrorSubject = 'item' | 'space' | 'container' | 'list';

export interface DescribedError {
  kind: ErrorKind;
  title: string;
  body: string;
}

/** Codes from the household client that mean the home box could not be reached. */
function isUnreachable(error: HouseholdHttpError): boolean {
  if (error.code === 'offline' || error.code === 'timeout' || error.code === 'http_502') {
    return true;
  }
  // Cloudflare answers 520–530 itself when the home box behind it is down.
  const match = /^http_(\d{3})$/.exec(error.code);
  const status = match ? Number(match[1]) : error.status;
  return status === 502 || (status >= 520 && status <= 530);
}

function goneTitle(subject: ErrorSubject): string {
  if (subject === 'space') return strings.errors.gone.space;
  if (subject === 'container') return strings.errors.gone.container;
  return strings.errors.gone.item;
}

/**
 * Plain words for anything a read or write can fail with.
 *
 * Raw codes and `Error.message` never reach the screen: the person gets
 * what happened, what to do next and what is still safe; the cause itself is
 * for `logError`. A `null` result counts as gone, because a record deleted on
 * another phone comes back as `null` rather than an error. Pure, so it is
 * tested in Node.
 */
export function describeError(
  cause: unknown,
  context: ErrorContext = 'read',
  subject: ErrorSubject = 'list',
): DescribedError {
  const reading = context === 'read' || context === 'join';

  if (cause instanceof ConflictError) {
    return { kind: 'conflict', ...strings.errors.conflict };
  }

  if (cause === null) {
    return { kind: 'gone', title: goneTitle(subject), body: strings.errors.gone.body };
  }

  if (cause instanceof HouseholdHttpError) {
    if (isUnreachable(cause)) {
      return {
        kind: 'offline',
        title: strings.errors.offline.title,
        body: reading ? strings.errors.offline.read : strings.errors.offline.save,
      };
    }
    // Pairing has no token yet, so a 401 there is a refused code, not a removed phone.
    if (context !== 'join' && (cause.status === 401 || cause.code === 'unauthorized')) {
      return { kind: 'revoked', ...strings.errors.revoked };
    }
    if (cause.status === 404 || cause.code === 'not_found') {
      return { kind: 'gone', title: goneTitle(subject), body: strings.errors.gone.body };
    }
    if (cause.code === 'photo_missing') {
      return { kind: 'photo', ...strings.errors.photo };
    }
    return { kind: 'server', ...strings.errors.server };
  }

  return {
    kind: 'local',
    title: strings.errors.local.title,
    body: reading ? strings.errors.local.read : strings.errors.local.save,
  };
}
