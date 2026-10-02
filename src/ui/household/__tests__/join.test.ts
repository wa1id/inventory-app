import { strings } from '@/i18n/strings';
import { HouseholdHttpError } from '@/services/household/client';
import { normaliseCode } from '@/ui/code';
import {
  codeProblem,
  joinFailure,
  serverHost,
  suggestedPhoneName,
  validateJoin,
} from '@/ui/household/join';

const CODE = 'MMWKY-M2H78-ABCDE-FGHJK-MNPQR-S';

describe('codeProblem', () => {
  it('accepts a full code however it was typed', () => {
    expect(codeProblem(normaliseCode(CODE))).toBeNull();
    expect(codeProblem(normaliseCode(CODE.toLowerCase().replace(/-/g, ' ')))).toBeNull();
  });

  it('names characters no code uses before complaining about the length', () => {
    expect(codeProblem(normaliseCode('MMWKU-M2H7%'))).toEqual({ kind: 'chars', chars: 'U %' });
  });

  it('reports the length of a short or long code', () => {
    expect(codeProblem(normaliseCode('MMWKY-M2H78-ABCDE-FGH'))).toEqual({
      kind: 'length',
      count: 18,
    });
    expect(codeProblem(normaliseCode(`${CODE}X`))).toEqual({ kind: 'length', count: 27 });
  });
});

describe('validateJoin', () => {
  it('passes a full code and a name', () => {
    expect(validateJoin(normaliseCode(CODE), 'Kitchen iPhone')).toEqual({});
  });

  it('puts each problem under its own field', () => {
    expect(validateJoin('ABC', '   ')).toEqual({
      code: strings.join.wrongLength(3),
      name: strings.join.nameRequired,
    });
    expect(validateJoin(normaliseCode('MMWKU'), 'Anna').code).toBe(strings.join.badChars('U'));
  });

  it('treats an empty code as too short, not as valid', () => {
    expect(validateJoin('', 'Anna').code).toBe(strings.join.wrongLength(0));
  });
});

describe('suggestedPhoneName', () => {
  it('keeps a real phone name', () => {
    expect(suggestedPhoneName('Anna’s iPhone')).toBe('Anna’s iPhone');
    expect(suggestedPhoneName('  Pixel 8 ')).toBe('Pixel 8');
  });

  it('skips generic and missing names', () => {
    expect(suggestedPhoneName('iPhone')).toBe('');
    expect(suggestedPhoneName('IPAD')).toBe('');
    expect(suggestedPhoneName('android')).toBe('');
    expect(suggestedPhoneName(null)).toBe('');
    expect(suggestedPhoneName(undefined)).toBe('');
  });
});

describe('joinFailure', () => {
  it('reads a 401 from pairing as a refused code', () => {
    expect(joinFailure(new HouseholdHttpError(401, 'unauthorized'))).toBe('refused');
  });

  it('reads no answer, a timeout and Cloudflare’s origin errors as offline', () => {
    expect(joinFailure(new HouseholdHttpError(0, 'offline'))).toBe('offline');
    expect(joinFailure(new HouseholdHttpError(0, 'timeout'))).toBe('offline');
    expect(joinFailure(new HouseholdHttpError(530, 'http_530'))).toBe('offline');
  });

  it('reads anything else as a plain failure', () => {
    expect(joinFailure(new HouseholdHttpError(500, 'invalid_response'))).toBe('other');
    expect(joinFailure(new Error('boom'))).toBe('other');
  });
});

describe('serverHost', () => {
  it('keeps only the host of the address', () => {
    expect(serverHost('https://inventory.wystudio.be')).toBe('inventory.wystudio.be');
    expect(serverHost('http://192.168.1.5:8788/')).toBe('192.168.1.5:8788');
    expect(serverHost('inventory.example')).toBe('inventory.example');
  });
});
