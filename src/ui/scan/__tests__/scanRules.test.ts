import { HouseholdHttpError } from '@/services/household/client';
import { labelFor, linkFailureMessage, planBind, tokenParam } from '@/ui/scan/scanRules';

const TOKEN = 'a'.repeat(32);
const OTHER_TOKEN = 'b'.repeat(32);

describe('labelFor', () => {
  it('uses the name, or else the code on the label', () => {
    expect(labelFor({ name: 'Tool chest', shortCode: 'CAB-J92R' })).toBe('Tool chest');
    expect(labelFor({ name: null, shortCode: 'BOX-7K2M' })).toBe('BOX-7K2M');
    expect(labelFor({ name: '   ', shortCode: 'BOX-7K2M' })).toBe('BOX-7K2M');
  });
});

describe('tokenParam', () => {
  it('reads one token from the route', () => {
    expect(tokenParam(TOKEN)).toBe(TOKEN);
    expect(tokenParam(` ${TOKEN} `)).toBe(TOKEN);
  });

  it('keeps the first of a repeated parameter', () => {
    expect(tokenParam([TOKEN, OTHER_TOKEN])).toBe(TOKEN);
  });

  it('is empty when there is nothing to read', () => {
    expect(tokenParam(undefined)).toBe('');
    expect(tokenParam([])).toBe('');
  });
});

describe('planBind', () => {
  it('links straight away when the container has no label', () => {
    expect(planBind(null, TOKEN, 'Tool chest')).toEqual({ write: true, confirm: null });
  });

  it('asks before retiring the sticker the container already has', () => {
    const plan = planBind({ token: OTHER_TOKEN }, TOKEN, 'Tool chest');
    expect(plan.write).toBe(true);
    expect(plan.confirm).toEqual({
      title: 'Replace the label on Tool chest?',
      body: 'Tool chest already has a label. Its old sticker will stop opening it.',
      confirmLabel: 'Replace',
    });
  });

  it('writes nothing when this label was linked to it meanwhile', () => {
    expect(planBind({ token: TOKEN.toUpperCase() }, TOKEN, 'Tool chest')).toEqual({
      write: false,
      confirm: null,
    });
  });

  it('never says "Move this label?" for a replacement (capture §13.16)', () => {
    const plan = planBind({ token: OTHER_TOKEN }, TOKEN, 'BOX-7K2M');
    expect(plan.confirm?.title).not.toMatch(/move/i);
  });
});

describe('linkFailureMessage', () => {
  it('says to check the connection when the home server did not answer', () => {
    expect(linkFailureMessage(new HouseholdHttpError(0, 'offline'))).toBe(
      'The label was not linked. Check the connection and try again.',
    );
    expect(linkFailureMessage(new HouseholdHttpError(530, 'http_530'))).toBe(
      'The label was not linked. Check the connection and try again.',
    );
  });

  it('says the container is gone when it was deleted elsewhere', () => {
    expect(linkFailureMessage(new HouseholdHttpError(404, 'not_found'))).toBe(
      'That container is not in the household any more. Choose another one.',
    );
  });

  it('never shows a raw code or message', () => {
    const message = linkFailureMessage(new Error('SQLITE_CONSTRAINT: FOREIGN KEY'));
    expect(message).toBe('The label was not linked. Try again.');
    expect(linkFailureMessage(new HouseholdHttpError(500, 'http_500'))).not.toMatch(/http_/);
  });
});
