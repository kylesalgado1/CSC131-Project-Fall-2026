import { buildRequest, DEFAULT_SETTINGS } from '../request';

const origin = { lat: 38.2383, lng: -122.0402 };
const destination = { lat: 38.5593, lng: -121.4237 };
const now = new Date(2026, 9, 21, 7, 0, 0, 0);

describe('buildRequest', () => {
  it('sends the two places and the preferences', () => {
    expect(
      buildRequest(
        origin,
        destination,
        { ...DEFAULT_SETTINGS, goal: 'minimize_time', maxWaitMinutes: 60 },
        now,
      ),
    ).toEqual({
      origin,
      destination,
      preferences: {
        goal: 'minimize_time',
        maxWaitMinutes: 60,
        minSavingsMinutes: 10,
      },
    });
  });

  it('sends only the coordinates, even from a whole place', () => {
    const place = {
      ...destination,
      id: 'x',
      name: 'Sac State',
      address: '6000 J St',
    };
    const request = buildRequest(origin, place, DEFAULT_SETTINGS, now);
    expect(request.destination).toEqual(destination);
  });

  it('adds the arrive-by and leave-by times as ISO times', () => {
    const request = buildRequest(
      origin,
      destination,
      {
        ...DEFAULT_SETTINGS,
        arriveBy: { hour: 8, minute: 30 },
        leaveBy: { hour: 7, minute: 45 },
      },
      now,
    );
    expect(request.arriveBy).toBe(new Date(2026, 9, 21, 8, 30).toISOString());
    expect(request.leaveBy).toBe(new Date(2026, 9, 21, 7, 45).toISOString());
  });

  it('takes a time that has already passed as tomorrow', () => {
    const request = buildRequest(
      origin,
      destination,
      { ...DEFAULT_SETTINGS, arriveBy: { hour: 6, minute: 0 } },
      now,
    );
    expect(request.arriveBy).toBe(new Date(2026, 9, 22, 6, 0).toISOString());
  });

  it('works out the day again each time, so a time keeps meaning the next one', () => {
    const settings = { ...DEFAULT_SETTINGS, leaveBy: { hour: 7, minute: 30 } };
    const early = buildRequest(
      origin,
      destination,
      settings,
      new Date(2026, 9, 21, 7, 0),
    );
    const late = buildRequest(
      origin,
      destination,
      settings,
      new Date(2026, 9, 21, 7, 40),
    );
    expect(early.leaveBy).toBe(new Date(2026, 9, 21, 7, 30).toISOString());
    expect(late.leaveBy).toBe(new Date(2026, 9, 22, 7, 30).toISOString());
  });

  it('leaves both out when none are set', () => {
    const request = buildRequest(origin, destination, DEFAULT_SETTINGS, now);
    expect(request).not.toHaveProperty('arriveBy');
    expect(request).not.toHaveProperty('leaveBy');
  });

  it('has sensible defaults: balanced, 10 minute minimum', () => {
    expect(DEFAULT_SETTINGS).toMatchObject({
      goal: 'balance',
      minSavingsMinutes: 10,
    });
  });
});
