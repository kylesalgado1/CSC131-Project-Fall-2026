import { DEFAULT_SETTINGS } from '../request';
import { summarizeSettings } from '../settingsSummary';

describe('summarizeSettings', () => {
  it('says no wait limit by default, and the minimum saving', () => {
    expect(summarizeSettings(DEFAULT_SETTINGS)).toBe(
      'no wait limit · only if it saves 10 min',
    );
  });

  it('follows the choices', () => {
    expect(
      summarizeSettings({
        ...DEFAULT_SETTINGS,
        maxWaitMinutes: 30,
        minSavingsMinutes: 5,
      }),
    ).toBe('wait up to 30 min · only if it saves 5 min');
  });
});
