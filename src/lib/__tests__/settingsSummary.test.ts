import { DEFAULT_SETTINGS } from '../request';
import { summarizeSettings } from '../settingsSummary';

describe('summarizeSettings', () => {
  it('says the goal, the longest wait and the minimum saving', () => {
    expect(summarizeSettings(DEFAULT_SETTINGS)).toBe(
      'Balanced · wait up to 1 hr 30 min · only if it saves 10 min',
    );
  });

  it('follows the choices', () => {
    expect(
      summarizeSettings({
        ...DEFAULT_SETTINGS,
        goal: 'minimize_time',
        maxWaitMinutes: 30,
        minSavingsMinutes: 5,
      }),
    ).toBe('Least driving · wait up to 30 min · only if it saves 5 min');
  });
});
