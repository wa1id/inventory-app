import { FOCUS_SPOT_SIZE, focusSpotOffset } from '@/ui/components/TapToFocusLayer';

describe('focusSpotOffset', () => {
  it('centres the square on the tap rather than hanging it from the corner', () => {
    expect(focusSpotOffset(100, 40)).toEqual({
      left: 100 - FOCUS_SPOT_SIZE / 2,
      top: 40 - FOCUS_SPOT_SIZE / 2,
    });
  });
});
