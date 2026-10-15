import { DEMO_TRIPS } from '../../trips';
import { buildRequest, DEFAULT_SETTINGS } from '../request';

const trip = DEMO_TRIPS[0];
const now = new Date(2026, 9, 21, 7, 0, 0, 0);

describe('buildRequest', () => {
  it('sends the trip and preferences', () => {
    expect(
      buildRequest(
        trip,
        { ...DEFAULT_SETTINGS, goal: 'minimize_time', maxWaitMinutes: 60 },
        now,
      ),
    ).toEqual({
      origin: trip.origin,
      destination: trip.destination,
      preferences: {
        goal: 'minimize_time',
        maxWaitMinutes: 60,
        minSavingsMinutes: 10,
      },
    });
  });

  it('adds the deadline as an ISO time when one is typed', () => {
    const request = buildRequest(
      trip,
      { ...DEFAULT_SETTINGS, arriveByText: '8:30 AM' },
      now,
    );
    expect(request.arriveBy).toBe(new Date(2026, 9, 21, 8, 30).toISOString());
  });

  it('leaves the deadline out when it is empty or not understood', () => {
    expect(buildRequest(trip, DEFAULT_SETTINGS, now)).not.toHaveProperty(
      'arriveBy',
    );
    expect(
      buildRequest(trip, { ...DEFAULT_SETTINGS, arriveByText: 'soon' }, now),
    ).not.toHaveProperty('arriveBy');
  });

  it('has sensible defaults: balanced, 10 minute minimum', () => {
    expect(DEFAULT_SETTINGS).toMatchObject({
      goal: 'balance',
      minSavingsMinutes: 10,
    });
  });
});
