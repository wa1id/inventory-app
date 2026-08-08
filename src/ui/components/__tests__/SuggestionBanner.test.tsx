import { staleSuggestionName, type SuggestionState } from '@/ui/components/SuggestionBanner';

const applied: SuggestionState = { status: 'applied', confidence: 0.9, forName: 'Cordless drill' };

describe('staleSuggestionName', () => {
  it('is null while the title still matches what the details describe', () => {
    expect(staleSuggestionName(applied, 'Cordless drill')).toBeNull();
    expect(staleSuggestionName(applied, '  Cordless drill  ')).toBeNull();
  });

  it('reports the corrected title once it diverges from ours', () => {
    // Covers both orders: typing over the suggestion, and typing a name before
    // it lands — either way the details describe an item the user never named.
    expect(staleSuggestionName(applied, 'Angle grinder')).toBe('Angle grinder');
  });

  it('goes stale again after a refresh', () => {
    const refreshed: SuggestionState = { status: 'refreshed', forName: 'Angle grinder' };

    expect(staleSuggestionName(refreshed, 'Angle grinder')).toBeNull();
    expect(staleSuggestionName(refreshed, 'Bench grinder')).toBe('Bench grinder');
  });

  it('offers nothing to refresh when the title has been cleared', () => {
    expect(staleSuggestionName(applied, '')).toBeNull();
    expect(staleSuggestionName(applied, '   ')).toBeNull();
  });

  it('offers nothing to refresh when no suggestion was applied', () => {
    expect(staleSuggestionName({ status: 'idle' }, 'Angle grinder')).toBeNull();
    expect(staleSuggestionName({ status: 'running' }, 'Angle grinder')).toBeNull();
    expect(staleSuggestionName({ status: 'refreshing' }, 'Angle grinder')).toBeNull();
    expect(
      staleSuggestionName({ status: 'failed', reason: 'offline' }, 'Angle grinder'),
    ).toBeNull();
  });
});
