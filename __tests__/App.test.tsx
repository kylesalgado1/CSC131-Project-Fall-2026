import React from 'react';
import { Linking } from 'react-native';
import ReactTestRenderer, { act } from 'react-test-renderer';
import App from '../App';
import { VerdictResponse } from '../src/api/types';
import { sampleResponse } from '../src/samples';
import { DEMO_TRIPS } from '../src/trips';
import { allText, hasText, press, tapLink, typeArriveBy } from '../src/testing';

// Without native code to report the screen's insets, the real provider
// renders nothing.
jest.mock(
  'react-native-safe-area-context',
  () => require('react-native-safe-area-context/jest/mock').default,
);

const START = new Date('2026-10-21T14:00:00Z');
const BASE_URL = 'http://192.168.1.5:3000';

type Reply = VerdictResponse | Error;

/** A stand-in server that answers with each reply in turn. */
function server(...replies: Reply[]) {
  let call = 0;
  const fetchFn = jest.fn(async () => {
    const reply = replies[Math.min(call++, replies.length - 1)];
    if (reply instanceof Error) {
      throw reply;
    }
    return { ok: true, status: 200, json: async () => reply } as Response;
  });
  return fetchFn;
}

const bodyOf = (fetchFn: jest.Mock, call = 0) =>
  JSON.parse(
    (fetchFn.mock.calls[call] as unknown as [string, RequestInit])[1]
      .body as string,
  );

let renderer: ReactTestRenderer.ReactTestRenderer | undefined;

async function flush(ms = 0) {
  await act(async () => {
    await jest.advanceTimersByTimeAsync(ms);
  });
}

async function open(fetchFn: jest.Mock) {
  await act(async () => {
    renderer = ReactTestRenderer.create(
      <App baseUrl={BASE_URL} fetchFn={fetchFn as unknown as typeof fetch} />,
    );
  });
  await flush(1);
  return renderer!.root;
}

beforeEach(() => {
  jest.useFakeTimers();
  jest.setSystemTime(START);
});

afterEach(async () => {
  // Take the renderer first: a queued cleanup must not reach a later test's.
  const finished = renderer;
  renderer = undefined;
  await act(async () => {
    finished?.unmount();
  });
  jest.useRealTimers();
});

describe('App', () => {
  it('asks the server and shows the answer', async () => {
    const fetchFn = server(sampleResponse('leave_now', START));
    const root = await open(fetchFn);
    expect(fetchFn).toHaveBeenCalledTimes(1);
    expect((fetchFn.mock.calls[0] as unknown as [string])[0]).toBe(
      `${BASE_URL}/verdict`,
    );
    expect(bodyOf(fetchFn)).toMatchObject({
      origin: DEMO_TRIPS[0].origin,
      destination: DEMO_TRIPS[0].destination,
      preferences: {
        goal: 'balance',
        maxWaitMinutes: 90,
        minSavingsMinutes: 10,
      },
    });
    expect(allText(root)).toContain('Leave now');
    expect(hasText(root, 'Updated')).toBe(true);
    expect(hasText(root, 'refreshes every 5 minutes')).toBe(true);
    expect(hasText(root, `Server: ${BASE_URL}`)).toBe(true);
  });

  it('says what went wrong when the server cannot be reached', async () => {
    const root = await open(server(new TypeError('Network request failed')));
    expect(hasText(root, 'Could not reach the server.')).toBe(true);
    expect(hasText(root, 'same Wi-Fi')).toBe(true);
    expect(hasText(root, 'Checking traffic')).toBe(false);
  });

  it('shows made-up answers, clearly labeled, without calling the server', async () => {
    const fetchFn = server(sampleResponse('leave_now', START));
    const root = await open(fetchFn);
    press(root, 'Sample: Wait');
    await flush(600);
    expect(allText(root)).toContain('Wait 60 minutes');
    expect(hasText(root, 'Sample data')).toBe(true);
    expect(hasText(root, 'refreshes every 5 minutes')).toBe(false);
    expect(fetchFn).toHaveBeenCalledTimes(1);

    press(root, 'Sample: Running late');
    await flush(600);
    expect(hasText(root, 'You may arrive about 35 minutes late.')).toBe(true);
  });

  it('asks again for a different trip', async () => {
    const fetchFn = server(sampleResponse('leave_now', START));
    const root = await open(fetchFn);
    press(root, 'Sac State to Suisun City');
    await flush(600);
    expect(fetchFn).toHaveBeenCalledTimes(2);
    expect(bodyOf(fetchFn, 1).origin).toEqual(DEMO_TRIPS[1].origin);
    expect(hasText(root, 'Sac State to Suisun City')).toBe(true);
  });

  it('sends the preferences the user picks', async () => {
    const fetchFn = server(sampleResponse('leave_now', START));
    const root = await open(fetchFn);
    press(root, 'Least driving');
    press(root, '1 hr');
    press(root, '5 min');
    await flush(600);
    expect(bodyOf(fetchFn, fetchFn.mock.calls.length - 1).preferences).toEqual({
      goal: 'minimize_time',
      maxWaitMinutes: 60,
      minSavingsMinutes: 5,
    });
  });

  it('sends an arrive-by time once it is typed, and rejects nonsense', async () => {
    const fetchFn = server(sampleResponse('leave_now', START));
    const root = await open(fetchFn);
    typeArriveBy(root, 'soon');
    expect(hasText(root, 'Try a time like 8:30 AM or 17:45.')).toBe(true);
    await flush(600);
    expect(bodyOf(fetchFn, fetchFn.mock.calls.length - 1)).not.toHaveProperty(
      'arriveBy',
    );

    typeArriveBy(root, '8:30 AM');
    expect(hasText(root, 'Try a time like')).toBe(false);
    await flush(600);
    expect(typeof bodyOf(fetchFn, fetchFn.mock.calls.length - 1).arriveBy).toBe(
      'string',
    );
  });

  it('does not ask the server on every keystroke', async () => {
    const fetchFn = server(sampleResponse('leave_now', START));
    const root = await open(fetchFn);
    for (const typed of ['8', '8:', '8:3', '8:30']) {
      typeArriveBy(root, typed);
      await flush(100);
    }
    await flush(600);
    expect(fetchFn).toHaveBeenCalledTimes(2); // the first load and one for the typing
  });

  describe('weather credit', () => {
    it('credits Open-Meteo under a live answer, saying the data was changed', async () => {
      const root = await open(server(sampleResponse('leave_now', START)));
      expect(hasText(root, 'Weather data by Open-Meteo.com')).toBe(true);
      expect(hasText(root, 'CC BY 4.0')).toBe(true);
      expect(hasText(root, 'Changed: rain forecasts')).toBe(true);
    });

    it('does not credit it before there is an answer, or on made-up samples', async () => {
      const root = await open(server(new TypeError('offline')));
      expect(hasText(root, 'Open-Meteo')).toBe(false);
      press(root, 'Sample: Wait');
      await flush(600);
      expect(hasText(root, 'Open-Meteo')).toBe(false);
    });

    it('links to Open-Meteo and to the license', async () => {
      const opened = jest.spyOn(Linking, 'openURL').mockResolvedValue(true);
      try {
        const root = await open(server(sampleResponse('leave_now', START)));
        tapLink(root, 'Weather data by Open-Meteo.com');
        tapLink(root, 'CC BY 4.0');
        expect(opened.mock.calls.map(c => c[0])).toEqual([
          'https://open-meteo.com/',
          'https://creativecommons.org/licenses/by/4.0/',
        ]);
      } finally {
        opened.mockRestore();
      }
    });

    it('survives a link that cannot be opened', async () => {
      const opened = jest
        .spyOn(Linking, 'openURL')
        .mockRejectedValue(new Error('no app to open this'));
      try {
        const root = await open(server(sampleResponse('leave_now', START)));
        tapLink(root, 'Open-Meteo.com');
        await flush();
        expect(allText(root)).toContain('Leave now');
      } finally {
        opened.mockRestore();
      }
    });
  });

  describe('keeping the answer fresh', () => {
    it('asks again every five minutes while open', async () => {
      const fetchFn = server(sampleResponse('leave_now', START));
      await open(fetchFn);
      await flush(4 * 60_000);
      expect(fetchFn).toHaveBeenCalledTimes(1);
      await flush(60_000);
      expect(fetchFn).toHaveBeenCalledTimes(2);
      await flush(5 * 60_000);
      expect(fetchFn).toHaveBeenCalledTimes(3);
    });

    it('updates the "last updated" time', async () => {
      const fetchFn = server(sampleResponse('leave_now', START));
      const root = await open(fetchFn);
      const before = allText(root).find(t => t.startsWith('Updated'));
      await flush(5 * 60_000);
      const after = allText(root).find(t => t.startsWith('Updated'));
      expect(before).not.toEqual(after);
    });

    it('highlights it when the best time to leave moves by 5 minutes or more', async () => {
      const first = sampleResponse('wait', START);
      const second = sampleResponse(
        'wait',
        new Date(START.getTime() + 5 * 60_000),
      );
      // The wait is the same 60 minutes, but it began 5 minutes later, so the
      // recommended departure has moved 5 minutes later.
      const root = await open(server(first, second));
      expect(hasText(root, 'Advice changed')).toBe(false);
      await flush(5 * 60_000);
      expect(hasText(root, 'Advice changed')).toBe(true);
      expect(hasText(root, 'moved later')).toBe(true);
    });

    it('stays quiet when the advice is the same', async () => {
      const answer = sampleResponse('wait', START);
      const root = await open(server(answer, answer));
      await flush(5 * 60_000);
      expect(hasText(root, 'Advice changed')).toBe(false);
    });

    it('keeps the last answer on screen if a refresh fails', async () => {
      const fetchFn = server(
        sampleResponse('wait', START),
        new TypeError('offline'),
      );
      const root = await open(fetchFn);
      await flush(5 * 60_000);
      expect(allText(root)).toContain('Wait 60 minutes');
      expect(hasText(root, 'Could not refresh')).toBe(true);
    });

    it('refreshes on demand', async () => {
      const fetchFn = server(sampleResponse('leave_now', START));
      const root = await open(fetchFn);
      press(root, 'Refresh now');
      await flush();
      expect(fetchFn).toHaveBeenCalledTimes(2);
    });

    it('does not carry an old answer into a different trip', async () => {
      const slow = server(
        sampleResponse('wait', START),
        sampleResponse('leave_now', START),
      );
      const root = await open(slow);
      expect(allText(root)).toContain('Wait 60 minutes');
      press(root, 'Sac State to SFSU');
      // Straight away, before the new answer, the old one is gone.
      expect(allText(root)).not.toContain('Wait 60 minutes');
      await flush(600);
      expect(allText(root)).toContain('Leave now');
    });
  });
});
