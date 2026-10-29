import ReactTestRenderer, { act } from 'react-test-renderer';
import { Place, Verdict } from '../../api/types';
import { sampleResponse } from '../../samples';
import { allText, flush, hasText, press } from '../../testing';
import { WaitPlan } from '../WaitPlan';

const NOW = new Date('2026-10-21T14:00:00Z'); // 7:00 AM Pacific
const time = { locale: 'en-US', timeZone: 'America/Los_Angeles' };
const here = { lat: 38.5593, lng: -121.4237 };

const cafe = (id: string, name: string, lat: number): Place => ({
  id,
  name,
  address: `${id} J St`,
  lat,
  lng: -121.4237,
});

/** A place this many miles north of the phone. */
const miles = (id: string, name: string, away: number): Place =>
  cafe(id, name, here.lat + away / 69);

/** A stand-in backend. A function answers each search by its text. */
function backend(answer: Place[] | Error | ((q: string) => Place[] | Error)) {
  const fetchFn = jest.fn(async (raw: string) => {
    const q = new URL(raw).searchParams.get('q')!;
    const places = typeof answer === 'function' ? answer(q) : answer;
    if (places instanceof Error) {
      throw places;
    }
    return {
      ok: true,
      status: 200,
      json: async () => ({ places }),
    } as Response;
  });
  return fetchFn as unknown as typeof fetch & jest.Mock;
}

function fakeReminders() {
  let n = 0;
  return {
    schedule: jest.fn(async (_at: Date, _body: string) => `id-${++n}`),
    cancel: jest.fn(async (_id: string) => undefined),
  };
}

async function render(
  kind: 'wait' | 'leave_now' | 'late',
  extra: Partial<Parameters<typeof WaitPlan>[0]> = {},
) {
  const fetchFn = extra.fetchFn ?? backend([cafe('a', 'Starbucks', 38.5601)]);
  const reminders = fakeReminders();
  const openUrl = jest.fn(async (_url: string) => undefined);
  let renderer!: ReactTestRenderer.ReactTestRenderer;
  await act(async () => {
    renderer = ReactTestRenderer.create(
      <WaitPlan
        verdict={sampleResponse(kind, NOW).verdict}
        baseUrl="http://h:3000"
        located={here}
        clock={() => NOW}
        openUrl={openUrl}
        reminders={reminders}
        timeOptions={time}
        {...extra}
        fetchFn={fetchFn}
      />,
    );
  });
  return {
    root: renderer.root,
    renderer,
    fetchFn: fetchFn as unknown as jest.Mock,
    reminders,
    openUrl,
  };
}

beforeEach(() => jest.useFakeTimers().setSystemTime(NOW));
afterEach(() => jest.useRealTimers());

describe('WaitPlan', () => {
  it('shows a countdown to the time to leave', async () => {
    const { root } = await render('wait');
    const text = allText(root);
    expect(text).toContain('While you wait');
    expect(text).toContain('Leave in 1 hr');
    expect(hasText(root, 'Leave at 8:00 AM')).toBe(true);
    expect(hasText(root, 'arrive around 8:38 AM')).toBe(true);
  });

  it('keeps counting down as time passes', async () => {
    const now = { current: NOW };
    const { root } = await render('wait', { clock: () => now.current });
    now.current = new Date(NOW.getTime() + 25 * 60_000);
    await flush(30_000);
    expect(allText(root)).toContain('Leave in 35 min');
    now.current = new Date(NOW.getTime() + 61 * 60_000);
    await flush(30_000);
    expect(allText(root)).toContain('Time to leave');
  });

  it('is not shown for any answer but wait', async () => {
    for (const kind of ['leave_now', 'late'] as const) {
      const { renderer, fetchFn } = await render(kind);
      expect(renderer.toJSON()).toBeNull();
      expect(fetchFn).not.toHaveBeenCalled();
    }
  });

  describe('places', () => {
    const byKind = (q: string) =>
      ({
        cafe: [miles('c1', 'Far Cafe', 3), miles('c2', 'Near Cafe', 0.2)],
        restaurant: [
          miles('f1', 'Pizza', 0.5),
          miles('f2', 'Distant Diner', 40),
        ],
        park: [miles('p1', 'Tahoe Park', 1.3), miles('p2', 'Oki Park', 1.8)],
        bookstore: [miles('b1', 'Hornet Bookstore', 0.1)],
      }[q] ?? []);

    it('searches every kind of place near the phone', async () => {
      const { fetchFn } = await render('wait', { fetchFn: backend(byKind) });
      expect(fetchFn).toHaveBeenCalledTimes(4);
      const urls = fetchFn.mock.calls.map(call => new URL(call[0]));
      expect(urls.map(url => url.searchParams.get('q')).sort()).toEqual([
        'bookstore',
        'cafe',
        'park',
        'restaurant',
      ]);
      for (const url of urls) {
        expect(url.pathname).toBe('/places');
        expect(url.searchParams.get('lat')).toBe(String(here.lat));
        expect(url.searchParams.get('lng')).toBe(String(here.lng));
      }
    });

    it('shows only the three closest, nearest first', async () => {
      const { root } = await render('wait', { fetchFn: backend(byKind) });
      const names = allText(root).filter(t =>
        [
          'Hornet Bookstore',
          'Near Cafe',
          'Pizza',
          'Tahoe Park',
          'Far Cafe',
        ].includes(t),
      );
      expect(names).toEqual(['Hornet Bookstore', 'Near Cafe', 'Pizza']);
      expect(hasText(root, 'Bookstore · 0.1 mi')).toBe(true);
      expect(hasText(root, 'Cafe · 0.2 mi')).toBe(true);
      expect(hasText(root, 'Food · 0.5 mi')).toBe(true);
    });

    it('leaves out places too far away to wait at', async () => {
      const { root } = await render('wait', {
        fetchFn: backend(q =>
          q === 'restaurant' ? [miles('x', 'Distant Diner', 40)] : [],
        ),
      });
      expect(allText(root)).not.toContain('Distant Diner');
      expect(hasText(root, 'Nothing found within 5 miles.')).toBe(true);
    });

    it('lists a place found by two searches once', async () => {
      const { root } = await render('wait', {
        fetchFn: backend([miles('same', 'Campus Cafe', 0.1)]),
      });
      expect(allText(root).filter(t => t === 'Campus Cafe')).toHaveLength(1);
    });

    it('narrows to one kind when a chip is tapped, and back to all', async () => {
      const { root } = await render('wait', { fetchFn: backend(byKind) });
      expect(allText(root)).toEqual(
        expect.arrayContaining(['All', 'Cafes', 'Food', 'Parks', 'Bookstores']),
      );

      press(root, 'Parks');
      const parks = allText(root).filter(t => t.endsWith('Park'));
      expect(parks).toEqual(['Tahoe Park', 'Oki Park']);
      expect(allText(root)).not.toContain('Near Cafe');

      press(root, 'Cafes');
      expect(allText(root)).toEqual(
        expect.arrayContaining(['Near Cafe', 'Far Cafe']),
      );

      press(root, 'All');
      expect(allText(root)).toContain('Hornet Bookstore');
    });

    it('says so when a kind has nothing nearby', async () => {
      const { root } = await render('wait', {
        fetchFn: backend(q =>
          q === 'cafe' ? [miles('c', 'Only Cafe', 1)] : [],
        ),
      });
      press(root, 'Parks');
      expect(hasText(root, 'No parks within 5 miles.')).toBe(true);
    });

    it('still shows what it found when one search fails', async () => {
      const { root } = await render('wait', {
        fetchFn: backend(q => (q === 'park' ? new Error('boom') : byKind(q))),
      });
      expect(allText(root)).toContain('Near Cafe');
      expect(hasText(root, 'Could not look for places.')).toBe(false);
    });

    it('asks the phone for its position when the app has none', async () => {
      const locate = jest.fn(async () => here);
      const { fetchFn } = await render('wait', {
        located: undefined,
        locate,
      });
      expect(locate).toHaveBeenCalledTimes(1);
      expect(new URL(fetchFn.mock.calls[0][0]).searchParams.get('lat')).toBe(
        String(here.lat),
      );
    });

    it('does not look again when the advice refreshes', async () => {
      const { renderer, fetchFn } = await render('wait');
      await act(async () => {
        renderer.update(
          <WaitPlan
            verdict={sampleResponse('wait', NOW).verdict}
            baseUrl="http://h:3000"
            located={here}
            clock={() => NOW}
            fetchFn={fetchFn}
            timeOptions={time}
          />,
        );
      });
      expect(fetchFn).toHaveBeenCalledTimes(4);
    });

    it('explains a failed search without hiding the countdown', async () => {
      const { root } = await render('wait', {
        fetchFn: backend(new Error('boom')),
      });
      expect(hasText(root, 'Could not look for places.')).toBe(true);
      expect(allText(root)).toContain('Leave in 1 hr');
    });

    it('opens directions in Maps when one is tapped', async () => {
      const { root, openUrl } = await render('wait');
      press(root, 'Starbucks');
      expect(openUrl).toHaveBeenCalledTimes(1);
      expect(openUrl.mock.calls[0][0]).toContain('38.5601');
      expect(openUrl.mock.calls[0][0]).toContain('Starbucks');
    });

    it('says when Maps cannot be opened', async () => {
      const { root } = await render('wait', {
        openUrl: jest.fn(async () => {
          throw new Error('no maps');
        }),
      });
      await act(async () => {
        press(root, 'Starbucks');
      });
      expect(hasText(root, 'Could not open Maps.')).toBe(true);
    });
  });

  describe('reminder', () => {
    it('schedules one five minutes before leaving, then turns off', async () => {
      const { root, reminders } = await render('wait');
      expect(reminders.schedule).not.toHaveBeenCalled();

      await act(async () => {
        press(root, 'Remind me 5 min before');
      });
      expect(reminders.schedule).toHaveBeenCalledTimes(1);
      const [at, body] = reminders.schedule.mock.calls[0];
      expect(at).toEqual(new Date(NOW.getTime() + 55 * 60_000));
      expect(body).toBe('Leave now to arrive around 8:38 AM.');
      expect(allText(root)).toContain('Reminder on');

      await act(async () => {
        press(root, 'Reminder on');
      });
      expect(reminders.cancel).toHaveBeenCalledWith('id-1');
      expect(allText(root)).toContain('Remind me 5 min before');
    });

    it('moves when the departure moves', async () => {
      const { root, renderer, fetchFn, reminders } = await render('wait');
      await act(async () => {
        press(root, 'Remind me 5 min before');
      });
      const later = sampleResponse('wait', new Date(NOW.getTime() + 600_000));
      await act(async () => {
        renderer.update(
          <WaitPlan
            verdict={later.verdict}
            baseUrl="http://h:3000"
            located={here}
            clock={() => NOW}
            reminders={reminders}
            fetchFn={fetchFn}
            timeOptions={time}
          />,
        );
      });
      expect(reminders.cancel).toHaveBeenCalledWith('id-1');
      expect(reminders.schedule).toHaveBeenCalledTimes(2);
      expect(reminders.schedule.mock.calls[1][0]).toEqual(
        new Date(NOW.getTime() + 65 * 60_000),
      );
    });

    it('goes away when the advice stops being to wait', async () => {
      const { root, renderer, fetchFn, reminders } = await render('wait');
      await act(async () => {
        press(root, 'Remind me 5 min before');
      });
      await act(async () => {
        renderer.update(
          <WaitPlan
            verdict={sampleResponse('leave_now', NOW).verdict}
            baseUrl="http://h:3000"
            located={here}
            clock={() => NOW}
            reminders={reminders}
            fetchFn={fetchFn}
          />,
        );
      });
      expect(reminders.cancel).toHaveBeenCalledWith('id-1');
      expect(renderer.toJSON()).toBeNull();
    });

    it('explains when notifications are not allowed', async () => {
      const denied = fakeReminders();
      denied.schedule.mockRejectedValue(
        new Error('Notifications are turned off for Wait It Out.'),
      );
      const { root } = await render('wait', { reminders: denied });
      await act(async () => {
        press(root, 'Remind me 5 min before');
      });
      expect(hasText(root, 'Notifications are turned off')).toBe(true);
      expect(allText(root)).toContain('Remind me 5 min before');
    });
  });

  describe('no need to leave yet', () => {
    const at = (minutes: number) =>
      new Date(NOW.getTime() + minutes * 60_000).toISOString();
    const base = sampleResponse('wait', NOW).verdict;
    const noRush: Verdict = {
      ...base,
      action: 'no_rush',
      waitMinutes: 0,
      recommended: base.leaveNow,
      deadline: {
        arriveBy: at(300),
        marginMinutes: 240,
        latestDeparture: {
          departAt: at(120),
          arriveAt: at(158),
          driveMinutes: 38,
        },
      },
    };

    it('counts down to the latest time to leave', async () => {
      const { root } = await render('wait', { verdict: noRush });
      const text = allText(root);
      expect(text).toContain('While you wait');
      expect(text).toContain('Leave within 2 hr');
      expect(
        hasText(
          root,
          'Any time before 9:00 AM works. Leave then and you arrive around 9:38 AM.',
        ),
      ).toBe(true);
      expect(text).toContain('Places near you');
    });

    it('reminds a quarter of an hour before the latest time', async () => {
      const { root, reminders } = await render('wait', { verdict: noRush });
      await act(async () => {
        press(root, 'Remind me 15 min before');
      });
      const [when, body] = reminders.schedule.mock.calls[0];
      expect(when).toEqual(new Date(NOW.getTime() + 105 * 60_000));
      expect(body).toBe('Last chance to leave to arrive around 9:38 AM.');
    });

    it('offers only places when the deadline is too far off to plan', async () => {
      const farOff: Verdict = { ...noRush, deadline: undefined };
      const { root, fetchFn, reminders } = await render('wait', {
        verdict: farOff,
      });
      expect(allText(root)).toContain('While you wait');
      expect(allText(root)).toContain('Places near you');
      expect(fetchFn).toHaveBeenCalled();
      expect(hasText(root, 'Leave within')).toBe(false);
      expect(() => press(root, 'Remind me')).toThrow();
      expect(reminders.schedule).not.toHaveBeenCalled();
    });

    it('treats a planned departure for a far deadline like a wait', async () => {
      const { root } = await render('wait', {
        verdict: { ...base, action: 'leave_later' },
      });
      expect(allText(root)).toContain('Leave in 1 hr');
      expect(allText(root)).toContain('Remind me 5 min before');
    });
  });

  it('can be set aside with "Leave now instead", and brought back', async () => {
    const { root, reminders } = await render('wait');
    await act(async () => {
      press(root, 'Remind me 5 min before');
    });
    await act(async () => {
      press(root, 'Leave now instead');
    });
    expect(allText(root)).toEqual(['Show the wait plan']);
    expect(reminders.cancel).toHaveBeenCalledWith('id-1');

    await act(async () => {
      press(root, 'Show the wait plan');
    });
    expect(allText(root)).toContain('While you wait');
    expect(allText(root)).toContain('Remind me 5 min before');
  });
});
