import { sheetKeyboardOffset } from '@/hooks/useSheetKeyboardOffset';

describe('sheetKeyboardOffset', () => {
  it('uses the header height until the form is laid out', () => {
    expect(
      sheetKeyboardOffset({ headerHeight: 56, windowHeight: 844, formHeight: 0, floating: false }),
    ).toBe(56);
  });

  it('counts the gap above an iPhone page sheet, which the header height leaves out', () => {
    // 844 pt screen; the sheet starts 59 + 10 pt down, under a 56 pt header.
    const formHeight = 844 - 69 - 56;
    expect(
      sheetKeyboardOffset({ headerHeight: 56, windowHeight: 844, formHeight, floating: false }),
    ).toBe(125);
  });

  it('counts a connection banner above the form', () => {
    // Android: a 24 + 64 pt header, then a 52 pt banner, then the form.
    const formHeight = 800 - 88 - 52;
    expect(
      sheetKeyboardOffset({ headerHeight: 88, windowHeight: 800, formHeight, floating: false }),
    ).toBe(140);
  });

  it('never goes below the header height', () => {
    expect(
      sheetKeyboardOffset({
        headerHeight: 88,
        windowHeight: 800,
        formHeight: 780,
        floating: false,
      }),
    ).toBe(88);
  });

  it('keeps the header height for a sheet that floats clear of the bottom', () => {
    expect(
      sheetKeyboardOffset({
        headerHeight: 56,
        windowHeight: 1180,
        formHeight: 900,
        floating: true,
      }),
    ).toBe(56);
  });
});
