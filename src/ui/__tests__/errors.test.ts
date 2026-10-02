import { ConflictError } from '@/core/conflict';
import { HouseholdHttpError } from '@/services/household/client';
import { describeError, type ErrorContext } from '@/ui/errors';

const RAW = /http_|invalid_|offline|timeout|unauthorized|not_found|photo_missing/;

describe('describeError', () => {
  it.each([
    [new HouseholdHttpError(0, 'offline')],
    [new HouseholdHttpError(0, 'timeout')],
    [new HouseholdHttpError(502, 'http_502')],
    [new HouseholdHttpError(530, 'http_530')],
    [new HouseholdHttpError(520, 'origin_down')],
  ])('treats %p as the home server not answering', (cause) => {
    const read = describeError(cause, 'read');
    expect(read.kind).toBe('offline');
    expect(read.title).toBe('The home server did not answer');
    expect(read.body).toContain('Nothing on this phone was lost');
    expect(describeError(cause, 'save').body).toContain('What you typed is still here');
  });

  it('treats a 401 as a removed phone, except while joining', () => {
    expect(describeError(new HouseholdHttpError(401, 'unauthorized')).kind).toBe('revoked');
    expect(describeError(new HouseholdHttpError(403, 'unauthorized')).kind).toBe('revoked');
    expect(describeError(new HouseholdHttpError(401, 'unauthorized'), 'join').kind).toBe('server');
  });

  it('treats null, 404 and not_found as gone, named by subject', () => {
    expect(describeError(null, 'read', 'item').title).toBe('This item is gone');
    expect(describeError(new HouseholdHttpError(404, 'http_404'), 'read', 'space').title).toBe(
      'This space is not in the household any more',
    );
    expect(
      describeError(new HouseholdHttpError(400, 'not_found'), 'read', 'container'),
    ).toMatchObject({
      kind: 'gone',
      title: 'This container is not in the household any more',
    });
  });

  it('separates a missing photo from a missing item', () => {
    expect(describeError(new HouseholdHttpError(0, 'photo_missing')).kind).toBe('photo');
  });

  it.each(['http_500', 'invalid_json', 'invalid_response', 'photos_not_configured'])(
    'reads %p as a home-server problem',
    (code) => {
      expect(describeError(new HouseholdHttpError(500, code)).kind).toBe('server');
    },
  );

  it('reads a conflict as a change on another phone', () => {
    expect(describeError(new ConflictError(1)).kind).toBe('conflict');
  });

  it('reads anything else as the local database', () => {
    expect(describeError(new Error('SQLITE_BUSY'), 'read')).toMatchObject({
      kind: 'local',
      body: 'Try again. If this keeps happening, restart the app. Your data is still on this phone.',
    });
    expect(describeError(new Error('SQLITE_BUSY'), 'save').body).toBe(
      'It was not saved. Try again.',
    );
  });

  it('never puts a raw code or message on screen', () => {
    const causes = [
      new HouseholdHttpError(0, 'offline'),
      new HouseholdHttpError(0, 'timeout'),
      new HouseholdHttpError(530, 'http_530'),
      new HouseholdHttpError(500, 'invalid_json'),
      new HouseholdHttpError(500, 'invalid_response'),
      new HouseholdHttpError(401, 'unauthorized'),
      new HouseholdHttpError(404, 'not_found'),
      new HouseholdHttpError(0, 'photo_missing'),
      new ConflictError(),
      new Error('http_500 invalid_json'),
      null,
      undefined,
    ];
    const contexts: ErrorContext[] = [
      'read',
      'save',
      'move',
      'quantity',
      'delete',
      'label',
      'join',
    ];
    for (const cause of causes) {
      for (const context of contexts) {
        const { title, body } = describeError(cause, context);
        expect(title).not.toMatch(RAW);
        expect(body).not.toMatch(RAW);
      }
    }
  });
});
