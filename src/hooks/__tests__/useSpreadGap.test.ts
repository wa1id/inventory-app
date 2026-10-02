import { spreadGap } from '@/hooks/useSpreadGap';

describe('spreadGap', () => {
  it('keeps the minimum gap until the row is measured', () => {
    expect(spreadGap(0, 48, 8)).toBe(8);
  });

  it('spreads as many tiles as fit so the row reaches both edges', () => {
    // 358 pt: six 48 pt tiles, five gaps of 14.
    const gap = spreadGap(358, 48, 8);
    expect(gap).toBe(14);
    expect(6 * 48 + 5 * gap).toBeLessThanOrEqual(358);
  });

  it('never rounds a row past its width', () => {
    const gap = spreadGap(358.33, 48, 4);
    expect(6 * 48 + 5 * gap).toBeLessThanOrEqual(358.33);
  });

  it('keeps to a fixed number of columns when asked', () => {
    // Four type tiles of 72 pt across 358 pt.
    expect(spreadGap(358, 72, 8, 4)).toBeCloseTo(23.3, 1);
    // Three on the narrowest phones.
    expect(spreadGap(288, 72, 8, 3)).toBe(36);
  });

  it('falls back to fewer columns, or the minimum, when they do not fit', () => {
    expect(spreadGap(250, 72, 8, 4)).toBe(17);
    expect(spreadGap(60, 48, 8)).toBe(8);
  });
});
