import { sampleResponse } from '../../samples';
import {
  closest,
  departureTarget,
  planKind,
  countdownLabel,
  distanceMiles,
  formatDistance,
  mapsUrl,
  minutesUntil,
  reminderTime,
} from '../waitPlan';

const NOW = new Date('2026-10-21T14:00:00Z');
const at = (minutes: number, extraSeconds = 0) =>
  new Date(NOW.getTime() + minutes * 60_000 + extraSeconds * 1000);

describe('countdownLabel', () => {
  it('counts down in hours and minutes', () => {
    expect(countdownLabel(at(102), NOW)).toBe('Leave in 1 hr 42 min');
    expect(countdownLabel(at(45), NOW)).toBe('Leave in 45 min');
  });

  it('rounds a part minute up, so it never reads 0 min early', () => {
    expect(minutesUntil(at(0, 20), NOW)).toBe(1);
    expect(countdownLabel(at(0, 20), NOW)).toBe('Leave in 1 min');
  });

  it('says it is time once the departure has come', () => {
    expect(countdownLabel(at(0), NOW)).toBe('Time to leave');
    expect(countdownLabel(at(-3), NOW)).toBe('Time to leave');
  });
});

describe('countdownLabel for a latest departure', () => {
  it('says "within", since any time before it will do', () => {
    expect(countdownLabel(at(102), NOW, true)).toBe('Leave within 1 hr 42 min');
    expect(countdownLabel(at(0), NOW, true)).toBe('Time to leave');
  });
});

describe('what the answer leaves to spend', () => {
  const verdict = sampleResponse('wait', NOW).verdict;
  const latest = { departAt: 'L', arriveAt: 'A', driveMinutes: 30 };

  it('is a wait for a set departure', () => {
    for (const action of ['wait', 'leave_later'] as const) {
      const v = { ...verdict, action };
      expect(planKind(v)).toBe('wait');
      expect(departureTarget(v)).toBe(v.recommended);
    }
  });

  it('is a window for "no need to leave yet", ending at the latest departure', () => {
    const v = {
      ...verdict,
      action: 'no_rush' as const,
      deadline: { arriveBy: 'D', marginMinutes: 60, latestDeparture: latest },
    };
    expect(planKind(v)).toBe('window');
    expect(departureTarget(v)).toBe(latest);
  });

  it('has no time to count down to when the deadline is too far off', () => {
    const v = { ...verdict, action: 'no_rush' as const };
    expect(planKind(v)).toBe('window');
    expect(departureTarget(v)).toBeUndefined();
  });

  it('is nothing for leaving now', () => {
    const v = { ...verdict, action: 'leave_now' as const };
    expect(planKind(v)).toBeUndefined();
    expect(departureTarget(v)).toBeUndefined();
  });

  it('is a wait for leaving at an earliest time that is not yet', () => {
    const v = {
      ...verdict,
      action: 'leave_now' as const,
      generatedAt: NOW.toISOString(),
      leaveNow: { ...verdict.leaveNow, departAt: at(120).toISOString() },
      recommended: { ...verdict.leaveNow, departAt: at(120).toISOString() },
    };
    expect(planKind(v)).toBe('wait');
    expect(departureTarget(v)).toBe(v.recommended);
  });
});

describe('reminderTime', () => {
  it('is five minutes before the departure', () => {
    expect(reminderTime(at(60), NOW)).toEqual(at(55));
  });

  it('falls back to a few seconds from now when that moment has passed', () => {
    expect(reminderTime(at(2), NOW)).toEqual(at(0, 5));
  });

  it('is undefined once the departure has passed', () => {
    expect(reminderTime(at(0), NOW)).toBeUndefined();
    expect(reminderTime(at(-5), NOW)).toBeUndefined();
  });

  it('takes a different lead', () => {
    expect(reminderTime(at(60), NOW, 15)).toEqual(at(45));
  });
});

describe('distance', () => {
  it('measures straight-line miles', () => {
    const sacState = { lat: 38.5593, lng: -121.4237 };
    const starbucks = { lat: 38.5601, lng: -121.4229 };
    expect(distanceMiles(sacState, sacState)).toBe(0);
    expect(distanceMiles(sacState, starbucks)).toBeGreaterThan(0.05);
    expect(distanceMiles(sacState, starbucks)).toBeLessThan(0.15);
    // One degree of latitude is about 69 miles.
    expect(
      distanceMiles({ lat: 38, lng: -121 }, { lat: 39, lng: -121 }),
    ).toBeCloseTo(69, 0);
  });

  it('shows feet up close and miles further out', () => {
    expect(formatDistance(0.05)).toBe('250 ft');
    expect(formatDistance(0.4)).toBe('0.4 mi');
    expect(formatDistance(2.46)).toBe('2.5 mi');
  });
});

describe('mapsUrl', () => {
  const place = { name: "Peet's & Co", lat: 38.5, lng: -121.4 };

  it('opens walking directions in Apple Maps on iOS', () => {
    expect(mapsUrl(place, 'ios')).toBe(
      "http://maps.apple.com/?daddr=38.5,-121.4&dirflg=w&q=Peet's%20%26%20Co",
    );
  });

  it('opens a geo link on Android', () => {
    expect(mapsUrl(place, 'android')).toBe(
      "geo:38.5,-121.4?q=38.5,-121.4(Peet's%20%26%20Co)",
    );
  });
});

describe('closest', () => {
  const spots = [
    { id: 1, category: 'cafe' },
    { id: 2, category: 'food' },
    { id: 3, category: 'cafe' },
    { id: 4, category: 'park' },
    { id: 5, category: 'cafe' },
  ];

  it('keeps the first three of a list sorted nearest first', () => {
    expect(closest(spots).map(s => s.id)).toEqual([1, 2, 3]);
  });

  it('keeps the first three of one kind', () => {
    expect(closest(spots, 'cafe').map(s => s.id)).toEqual([1, 3, 5]);
    expect(closest(spots, 'park').map(s => s.id)).toEqual([4]);
    expect(closest(spots, 'books')).toEqual([]);
  });

  it('takes a different count', () => {
    expect(closest(spots, undefined, 1).map(s => s.id)).toEqual([1]);
  });
});
