import AsyncStorage from '@react-native-async-storage/async-storage';
import { Linking } from 'react-native';
import ReactTestRenderer, { act } from 'react-test-renderer';
import App from '../App';
import { LatLng, Place, VerdictResponse } from '../src/api/types';
import { nextOccurrence } from '../src/lib/clockTime';
import { LocationError } from '../src/location/errors';
import { lastKnownLocation } from '../src/location/currentLocation';
import { sampleResponse } from '../src/samples';
import {
  allText,
  flush,
  hasText,
  press,
  pressExact,
  tapLink,
  typeInto,
} from '../src/testing';
import { QUICK_PICKS } from '../src/trip/quickPicks';
import { Trip } from '../src/trip/types';

// Without native code to report the screen's insets, the real provider
// renders nothing.
jest.mock(
  'react-native-safe-area-context',
  () => require('react-native-safe-area-context/jest/mock').default,
);
// Location needs a phone. The screen is given its own `locate`; this only
// covers the quiet look at where the phone last was.
jest.mock('../src/location/currentLocation', () => ({
  getCurrentLocation: jest.fn(),
  lastKnownLocation: jest.fn(),
}));

const START = new Date('2026-10-21T14:00:00Z');
const BASE_URL = 'http://192.168.1.5:3000';
const HERE: LatLng = { lat: 38.2383, lng: -122.0402 };
const [SAC_STATE, SFSU] = QUICK_PICKS;
const HOME: Place = {
  id: 'home',
  name: 'Home Street',
  address: '1 Home St, Suisun City, CA',
  lat: 38.25,
  lng: -122.03,
};

type Reply = VerdictResponse | Error;

/** A stand-in backend: answers verdicts in turn, and searches from `places`. */
function backend(replies: Reply[], places: (q: string) => Place[] = () => []) {
  let call = 0;
  const verdicts: Array<{
    origin: LatLng;
    destination: LatLng;
    preferences: unknown;
    arriveBy?: string;
    leaveBy?: string;
    leaveAfter?: string;
  }> = [];
  const searches: URL[] = [];
  const fetchFn = jest.fn(async (raw: string, init?: RequestInit) => {
    const url = new URL(raw);
    if (url.pathname === '/places') {
      searches.push(url);
      return {
        ok: true,
        status: 200,
        json: async () => ({ places: places(url.searchParams.get('q')!) }),
      } as Response;
    }
    verdicts.push(JSON.parse(init!.body as string));
    const reply = replies[Math.min(call++, replies.length - 1)];
    if (reply instanceof Error) {
      throw reply;
    }
    return { ok: true, status: 200, json: async () => reply } as Response;
  });
  return { fetchFn, verdicts, searches };
}

let renderer: ReactTestRenderer.ReactTestRenderer | undefined;

async function open(
  api: ReturnType<typeof backend>,
  locate: jest.Mock = jest.fn().mockResolvedValue(HERE),
) {
  await act(async () => {
    renderer = ReactTestRenderer.create(
      <App
        baseUrl={BASE_URL}
        fetchFn={api.fetchFn as unknown as typeof fetch}
        locate={locate}
      />,
    );
  });
  await flush(1);
  return renderer!.root;
}

const saveTrip = (trip: Trip) =>
  AsyncStorage.setItem('waitItOut.trip.v1', JSON.stringify(trip));
const campusTrip: Trip = {
  from: { kind: 'place', place: HOME },
  to: SAC_STATE,
};

beforeEach(async () => {
  jest.useFakeTimers();
  jest.setSystemTime(START);
  await AsyncStorage.clear();
  (lastKnownLocation as jest.Mock).mockReset().mockResolvedValue(undefined);
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

describe('first launch', () => {
  it('asks where the user is going, and asks nobody anything yet', async () => {
    const api = backend([sampleResponse('leave_now', START)]);
    const locate = jest.fn();
    const root = await open(api, locate);
    expect(allText(root)).toContain('Where are you going?');
    expect(hasText(root, 'Current location')).toBe(true);
    expect(api.fetchFn).not.toHaveBeenCalled();
    expect(locate).not.toHaveBeenCalled(); // no permission prompt before there is a trip
    expect(hasText(root, 'Checking traffic')).toBe(false);
  });

  it('starts a trip from the current location when a well-known place is tapped', async () => {
    const api = backend([sampleResponse('leave_now', START)]);
    const locate = jest.fn().mockResolvedValue(HERE);
    const root = await open(api, locate);
    press(root, SAC_STATE.name);
    await flush(1);
    expect(locate).toHaveBeenCalledTimes(1);
    expect(api.verdicts[0].origin).toEqual(HERE);
    expect(api.verdicts[0].destination).toEqual({
      lat: SAC_STATE.lat,
      lng: SAC_STATE.lng,
    });
    expect(allText(root)).toContain('Leave now');
    expect(hasText(root, 'Where are you going?')).toBe(false);
    expect(hasText(root, SAC_STATE.name)).toBe(true);
  });

  it('says it is finding the location while it waits for the phone', async () => {
    let found!: (p: LatLng) => void;
    const locate = jest.fn(
      () => new Promise<LatLng>(resolve => (found = resolve)),
    );
    const root = await open(
      backend([sampleResponse('leave_now', START)]),
      locate,
    );
    press(root, SAC_STATE.name);
    await flush(1);
    expect(hasText(root, 'Finding your location...')).toBe(true);
    found(HERE);
    await flush();
    expect(hasText(root, 'Finding your location...')).toBe(false);
    expect(allText(root)).toContain('Leave now');
  });
});

describe('choosing places', () => {
  it('starts destination search at three characters, shows up to five ranked suggestions, and uses the pick', async () => {
    (lastKnownLocation as jest.Mock).mockResolvedValue(HERE);
    const api = backend([sampleResponse('leave_now', START)], q => [
      {
        id: 'csus',
        name: 'California State University, Sacramento',
        address: '6000 J St',
        lat: 38.56,
        lng: -121.42,
      },
      ...Array.from({ length: 5 }, (_, index) => ({
        id: `match-${index + 1}`,
        name: `${q} Plaza ${index + 1}`,
        address: `${index + 1} Main St`,
        lat: 38.3,
        lng: -121.9,
      })),
    ]);
    const root = await open(api);
    press(root, 'Where are you going?');
    expect(hasText(root, 'Where to?')).toBe(true);
    typeInto(root, 'Search for a place or address', 'sa');
    await flush(400);
    expect(api.searches).toHaveLength(0);

    typeInto(root, 'Search for a place or address', 'sac');
    await flush(400);
    expect(api.searches).toHaveLength(1);
    expect(api.searches[0].searchParams.get('q')).toBe('sac');
    for (const index of [1, 2, 3, 4]) {
      expect(allText(root)).toContain(`sac Plaza ${index}`);
    }
    expect(allText(root)).not.toContain('sac Plaza 5');
    expect(api.searches[0].searchParams.get('lat')).toBe(String(HERE.lat));
    press(root, 'California State University, Sacramento');
    await flush(1);
    expect(hasText(root, 'Where to?')).toBe(false); // the sheet closed
    expect(api.verdicts[0].destination).toEqual({ lat: 38.56, lng: -121.42 });
    expect(allText(root)).toContain('California State University, Sacramento');
  });

  it("starts from a chosen place instead of the phone's position", async () => {
    await saveTrip({ from: { kind: 'current' }, to: SAC_STATE });
    const api = backend([sampleResponse('leave_now', START)]);
    const locate = jest.fn().mockResolvedValue(HERE);
    const root = await open(api, locate);
    expect(locate).toHaveBeenCalledTimes(1);
    press(root, 'Current location'); // the FROM row
    expect(hasText(root, 'Start from')).toBe(true);
    press(root, SFSU.name);
    await flush(600);
    expect(api.verdicts[1].origin).toEqual({ lat: SFSU.lat, lng: SFSU.lng });
    expect(locate).toHaveBeenCalledTimes(1); // not asked again
    expect(hasText(root, SFSU.name)).toBe(true);
  });

  it("goes back to the phone's position when asked", async () => {
    await saveTrip({ from: { kind: 'place', place: HOME }, to: SAC_STATE });
    const api = backend([sampleResponse('leave_now', START)]);
    const locate = jest.fn().mockResolvedValue(HERE);
    const root = await open(api, locate);
    expect(locate).not.toHaveBeenCalled();
    press(root, HOME.name);
    press(root, 'Use my current location');
    await flush(600);
    expect(locate).toHaveBeenCalledTimes(1);
    expect(api.verdicts[1].origin).toEqual(HERE);
  });

  it('swaps start and destination in one tap, and only when that makes sense', async () => {
    await saveTrip({ from: { kind: 'place', place: HOME }, to: SAC_STATE });
    const api = backend([sampleResponse('leave_now', START)]);
    const root = await open(api);
    press(root, '⇅');
    await flush(600);
    expect(api.verdicts[1].origin).toEqual({
      lat: SAC_STATE.lat,
      lng: SAC_STATE.lng,
    });
    expect(api.verdicts[1].destination).toEqual({
      lat: HOME.lat,
      lng: HOME.lng,
    });

    await AsyncStorage.clear();
    const fromPhone = await open(backend([sampleResponse('leave_now', START)]));
    expect(hasText(fromPhone, '⇅')).toBe(false);
  });

  it('remembers places that were used, and shows them first next time', async () => {
    const api = backend([sampleResponse('leave_now', START)]);
    const root = await open(api);
    press(root, SFSU.name);
    await flush(1);
    press(root, SFSU.name); // the TO row, now showing the choice
    expect(allText(root)).toContain('RECENT');
    expect(
      JSON.parse(
        (await AsyncStorage.getItem('waitItOut.recents.v1')) ?? '[]',
      )[0].id,
    ).toBe(SFSU.id);
  });

  it('keeps the old destination when the sheet is cancelled', async () => {
    await saveTrip(campusTrip);
    const root = await open(backend([sampleResponse('leave_now', START)]));
    press(root, SAC_STATE.name);
    press(root, 'Cancel');
    expect(hasText(root, 'Where to?')).toBe(false);
    expect(hasText(root, SAC_STATE.name)).toBe(true);
  });
});

describe('when the phone cannot say where it is', () => {
  const denied = () =>
    new LocationError('denied', 'Location is turned off for Wait It Out.');

  it('explains, and offers a way forward', async () => {
    await saveTrip({ from: { kind: 'current' }, to: SAC_STATE });
    const root = await open(
      backend([sampleResponse('leave_now', START)]),
      jest.fn().mockRejectedValue(denied()),
    );
    expect(hasText(root, "Can't find your location")).toBe(true);
    expect(hasText(root, 'Location is turned off for Wait It Out.')).toBe(true);
    expect(allText(root)).toEqual(
      expect.arrayContaining([
        'Open Settings',
        'Choose a starting address',
        'Try again',
      ]),
    );
    expect(hasText(root, 'Something went wrong')).toBe(false);
  });

  it("opens the phone's settings", async () => {
    await saveTrip({ from: { kind: 'current' }, to: SAC_STATE });
    const root = await open(
      backend([sampleResponse('leave_now', START)]),
      jest.fn().mockRejectedValue(denied()),
    );
    const settings = jest.spyOn(Linking, 'openSettings').mockResolvedValue();
    try {
      press(root, 'Open Settings');
      expect(settings).toHaveBeenCalledTimes(1);
    } finally {
      settings.mockRestore();
    }
  });

  it('lets the user choose a starting address instead', async () => {
    await saveTrip({ from: { kind: 'current' }, to: SAC_STATE });
    const api = backend([sampleResponse('leave_now', START)]);
    const root = await open(api, jest.fn().mockRejectedValue(denied()));
    press(root, 'Choose a starting address');
    expect(hasText(root, 'Start from')).toBe(true);
    press(root, SFSU.name);
    await flush(600);
    expect(hasText(root, "Can't find your location")).toBe(false);
    expect(allText(root)).toContain('Leave now');
    expect(api.verdicts[0].origin).toEqual({ lat: SFSU.lat, lng: SFSU.lng });
  });

  it('can try again, for example after turning location on', async () => {
    await saveTrip({ from: { kind: 'current' }, to: SAC_STATE });
    const locate = jest
      .fn()
      .mockRejectedValueOnce(denied())
      .mockResolvedValue(HERE);
    const root = await open(
      backend([sampleResponse('leave_now', START)]),
      locate,
    );
    expect(hasText(root, "Can't find your location")).toBe(true);
    press(root, 'Try again');
    await flush();
    expect(hasText(root, "Can't find your location")).toBe(false);
    expect(allText(root)).toContain('Leave now');
  });

  it('does not offer Settings for a problem Settings cannot fix', async () => {
    await saveTrip({ from: { kind: 'current' }, to: SAC_STATE });
    const root = await open(
      backend([sampleResponse('leave_now', START)]),
      jest
        .fn()
        .mockRejectedValue(
          new LocationError('unavailable', 'Could not find your location.'),
        ),
    );
    expect(allText(root)).not.toContain('Open Settings');
    expect(allText(root)).toContain('Choose a starting address');
  });
});

describe('remembering the trip', () => {
  it('picks up where the user left off, with no taps', async () => {
    await saveTrip(campusTrip);
    const api = backend([sampleResponse('leave_now', START)]);
    const root = await open(api);
    expect(hasText(root, HOME.name)).toBe(true);
    expect(hasText(root, SAC_STATE.name)).toBe(true);
    expect(api.verdicts).toHaveLength(1);
    expect(allText(root)).toContain('Leave now');
  });

  it('saves a new destination for next time', async () => {
    await saveTrip(campusTrip);
    const root = await open(backend([sampleResponse('leave_now', START)]));
    press(root, SAC_STATE.name);
    press(root, SFSU.name);
    await flush(600);
    expect(
      JSON.parse((await AsyncStorage.getItem('waitItOut.trip.v1'))!).to.id,
    ).toBe(SFSU.id);
  });
});

describe('the answer', () => {
  it('asks the server and shows the answer', async () => {
    await saveTrip(campusTrip);
    const api = backend([sampleResponse('leave_now', START)]);
    const root = await open(api);
    expect((api.fetchFn.mock.calls[0] as unknown as [string])[0]).toBe(
      `${BASE_URL}/verdict`,
    );
    expect(api.verdicts[0]).toMatchObject({
      origin: { lat: HOME.lat, lng: HOME.lng },
      destination: { lat: SAC_STATE.lat, lng: SAC_STATE.lng },
      preferences: { minSavingsMinutes: 10 },
    });
    expect(api.verdicts[0].preferences).not.toHaveProperty('maxWaitMinutes');
    expect(allText(root)).toContain('Leave now');
    expect(hasText(root, 'Updated')).toBe(true);
    expect(hasText(root, 'refreshes every 5 minutes')).toBe(true);
    expect(hasText(root, `Server: ${BASE_URL}`)).toBe(true);
  });

  it('says what went wrong when the server cannot be reached', async () => {
    await saveTrip(campusTrip);
    const root = await open(backend([new TypeError('Network request failed')]));
    expect(hasText(root, 'Could not reach the server.')).toBe(true);
    expect(hasText(root, 'same Wi-Fi')).toBe(true);
    expect(hasText(root, 'Checking traffic')).toBe(false);
  });

  it('keeps the settings folded away until they are wanted', async () => {
    await saveTrip(campusTrip);
    const root = await open(backend([sampleResponse('leave_now', START)]));
    expect(hasText(root, 'no wait limit · only if it saves 10 min')).toBe(true);
    expect(hasText(root, 'LONGEST I WILL WAIT')).toBe(false);
    press(root, 'Preferences');
    expect(hasText(root, 'LONGEST I WILL WAIT')).toBe(true);
    // There is one aim, which follows from whether an Arrive by time is set.
    expect(hasText(root, 'WHAT MATTERS TO ME')).toBe(false);
    expect(hasText(root, 'Least driving')).toBe(false);
  });

  it('sends the preferences the user picks', async () => {
    await saveTrip(campusTrip);
    const api = backend([sampleResponse('leave_now', START)]);
    const root = await open(api);
    press(root, 'Preferences');
    press(root, '1 hr');
    press(root, '5 min');
    await flush(600);
    expect(api.verdicts[api.verdicts.length - 1].preferences).toEqual({
      maxWaitMinutes: 60,
      minSavingsMinutes: 5,
    });
  });

  it('sends a wait limit only when one is chosen, and can go back to none', async () => {
    await saveTrip(campusTrip);
    const api = backend([sampleResponse('leave_now', START)]);
    const root = await open(api);
    const last = () => api.verdicts[api.verdicts.length - 1].preferences;
    press(root, 'Preferences');
    press(root, '1 hr');
    await flush(600);
    expect(last()).toMatchObject({ maxWaitMinutes: 60 });
    press(root, 'No limit');
    await flush(600);
    expect(last()).not.toHaveProperty('maxWaitMinutes');
  });

  describe('leave-by and arrive-by times', () => {
    const lastRequest = (api: ReturnType<typeof backend>) =>
      api.verdicts[api.verdicts.length - 1];
    const atNext = (hour: number, minute: number) =>
      nextOccurrence({ hour, minute }, new Date()).toISOString();

    it('start as "Any time" and send no limits', async () => {
      await saveTrip(campusTrip);
      const api = backend([sampleResponse('leave_now', START)]);
      const root = await open(api);
      expect(allText(root).filter(t => t === 'Any time')).toHaveLength(3);
      expect(lastRequest(api)).not.toHaveProperty('arriveBy');
      expect(lastRequest(api)).not.toHaveProperty('leaveBy');
    });

    it('sets an arrive-by time by scrolling the wheels, shows it, and sends it', async () => {
      await saveTrip(campusTrip);
      const api = backend([sampleResponse('leave_now', START)]);
      const root = await open(api);
      press(root, 'Arrive by');
      expect(hasText(root, 'The latest you need to get there.')).toBe(true);
      pressExact(root, '8');
      pressExact(root, '30');
      pressExact(root, 'PM');
      press(root, 'Set arrive by');
      expect(hasText(root, 'The latest you need to get there.')).toBe(false); // the sheet closed
      expect(allText(root)).toContain('8:30 PM');
      await flush(600);
      expect(lastRequest(api).arriveBy).toBe(atNext(20, 30));
      expect(lastRequest(api)).not.toHaveProperty('leaveBy');
    });

    it('sets a leave-by time the same way, and sends it as its own limit', async () => {
      await saveTrip(campusTrip);
      const api = backend([sampleResponse('leave_now', START)]);
      const root = await open(api);
      press(root, 'Leave by');
      expect(hasText(root, 'The app will not tell you to wait past it.')).toBe(
        true,
      );
      pressExact(root, '5');
      pressExact(root, '45');
      pressExact(root, 'PM');
      press(root, 'Set leave by');
      expect(allText(root)).toContain('5:45 PM');
      await flush(600);
      expect(lastRequest(api).leaveBy).toBe(atNext(17, 45));
      expect(lastRequest(api)).not.toHaveProperty('arriveBy');
    });

    it('sets a leave-after time and sends it as the earliest departure', async () => {
      await saveTrip(campusTrip);
      const api = backend([sampleResponse('leave_now', START)]);
      const root = await open(api);
      press(root, 'Leave after');
      expect(hasText(root, 'The earliest you can be on the road')).toBe(true);
      pressExact(root, '5');
      pressExact(root, '45');
      pressExact(root, 'PM');
      press(root, 'Set leave after');
      expect(allText(root)).toContain('5:45 PM');
      await flush(600);
      expect(lastRequest(api).leaveAfter).toBe(atNext(17, 45));
      expect(lastRequest(api)).not.toHaveProperty('leaveBy');
      expect(lastRequest(api)).not.toHaveProperty('arriveBy');
    });

    it('can have both at once', async () => {
      await saveTrip(campusTrip);
      const api = backend([sampleResponse('leave_now', START)]);
      const root = await open(api);
      press(root, 'Leave by');
      press(root, 'Set leave by');
      press(root, 'Arrive by');
      press(root, 'Set arrive by');
      await flush(1200);
      expect(typeof lastRequest(api).leaveBy).toBe('string');
      expect(typeof lastRequest(api).arriveBy).toBe('string');
    });

    it('does not ask the server while the wheels are being turned, only once a time is set', async () => {
      await saveTrip(campusTrip);
      const api = backend([sampleResponse('leave_now', START)]);
      const root = await open(api);
      press(root, 'Arrive by');
      for (const value of ['2', '3', '4', '5', '6']) {
        pressExact(root, value);
        await flush(100);
      }
      await flush(1000);
      expect(api.verdicts).toHaveLength(1);
      press(root, 'Set arrive by');
      await flush(600);
      expect(api.verdicts).toHaveLength(2);
    });

    it('leaves things as they were when the sheet is cancelled', async () => {
      await saveTrip(campusTrip);
      const api = backend([sampleResponse('leave_now', START)]);
      const root = await open(api);
      press(root, 'Arrive by');
      pressExact(root, '9');
      press(root, 'Cancel');
      await flush(1000);
      expect(allText(root).filter(t => t === 'Any time')).toHaveLength(3);
      expect(api.verdicts).toHaveLength(1);
    });

    it('removes a limit with "Any time"', async () => {
      await saveTrip(campusTrip);
      const api = backend([sampleResponse('leave_now', START)]);
      const root = await open(api);
      press(root, 'Leave by');
      press(root, 'Set leave by');
      await flush(600);
      expect(typeof lastRequest(api).leaveBy).toBe('string');
      press(root, 'Leave by');
      pressExact(root, 'Any time'); // the sheet's button, not the card's row
      await flush(600);
      expect(lastRequest(api)).not.toHaveProperty('leaveBy');
      expect(allText(root).filter(t => t === 'Any time')).toHaveLength(3);
    });

    it('opens on the time already set, not a fresh suggestion', async () => {
      await saveTrip(campusTrip);
      const root = await open(backend([sampleResponse('leave_now', START)]));
      press(root, 'Leave by');
      pressExact(root, '3');
      pressExact(root, '15');
      pressExact(root, 'AM');
      press(root, 'Set leave by');
      press(root, 'Leave by');
      expect(hasText(root, '3:15 AM')).toBe(true);
    });

    it('is not asked for before a trip exists, but can still be set', async () => {
      const api = backend([sampleResponse('leave_now', START)]);
      const root = await open(api);
      press(root, 'Arrive by');
      press(root, 'Set arrive by');
      await flush(1000);
      expect(api.fetchFn).not.toHaveBeenCalled();
      expect(hasText(root, 'Where are you going?')).toBe(true);
    });
  });

  it('shows made-up answers, clearly labeled, without calling anything', async () => {
    await saveTrip(campusTrip);
    const api = backend([sampleResponse('leave_now', START)]);
    const root = await open(api);
    press(root, 'Demo options');
    press(root, 'Sample: Wait');
    await flush(600);
    expect(allText(root)).toContain('Wait 60 minutes');
    expect(hasText(root, 'Sample data')).toBe(true);
    expect(hasText(root, 'refreshes every 5 minutes')).toBe(false);
    expect(api.verdicts).toHaveLength(1);
    press(root, 'Sample: Running late');
    await flush(600);
    expect(hasText(root, 'You may arrive about 35 minutes late.')).toBe(true);
  });

  it('shows a sample even before a destination is chosen', async () => {
    const root = await open(backend([sampleResponse('leave_now', START)]));
    press(root, 'Demo options');
    press(root, 'Sample: Wait');
    await flush(600);
    expect(allText(root)).toContain('Wait 60 minutes');
    expect(hasText(root, 'Where are you going?')).toBe(true); // the trip card still asks
  });
});

describe('keeping the answer fresh', () => {
  it('asks again every five minutes while open', async () => {
    await saveTrip(campusTrip);
    const api = backend([sampleResponse('leave_now', START)]);
    await open(api);
    await flush(4 * 60_000);
    expect(api.verdicts).toHaveLength(1);
    await flush(60_000);
    expect(api.verdicts).toHaveLength(2);
    await flush(5 * 60_000);
    expect(api.verdicts).toHaveLength(3);
  });

  it('follows the phone: each refresh asks where it is now', async () => {
    await saveTrip({ from: { kind: 'current' }, to: SAC_STATE });
    const moved: LatLng = { lat: 38.4, lng: -121.7 };
    const locate = jest
      .fn()
      .mockResolvedValueOnce(HERE)
      .mockResolvedValue(moved);
    const api = backend([sampleResponse('leave_now', START)]);
    await open(api, locate);
    await flush(5 * 60_000);
    expect(api.verdicts.map(v => v.origin)).toEqual([HERE, moved]);
  });

  it('updates the "last updated" time', async () => {
    await saveTrip(campusTrip);
    const root = await open(backend([sampleResponse('leave_now', START)]));
    const before = allText(root).find(t => t.startsWith('Updated'));
    await flush(5 * 60_000);
    expect(allText(root).find(t => t.startsWith('Updated'))).not.toEqual(
      before,
    );
  });

  it('highlights it when the best time to leave moves by 5 minutes or more', async () => {
    await saveTrip(campusTrip);
    const first = sampleResponse('wait', START);
    const second = sampleResponse(
      'wait',
      new Date(START.getTime() + 5 * 60_000),
    );
    const root = await open(backend([first, second]));
    expect(hasText(root, 'Advice changed')).toBe(false);
    await flush(5 * 60_000);
    expect(hasText(root, 'Advice changed')).toBe(true);
    expect(hasText(root, 'moved later')).toBe(true);
  });

  it('stays quiet when the advice is the same', async () => {
    await saveTrip(campusTrip);
    const answer = sampleResponse('wait', START);
    const root = await open(backend([answer, answer]));
    await flush(5 * 60_000);
    expect(hasText(root, 'Advice changed')).toBe(false);
  });

  it('keeps the last answer on screen if a refresh fails', async () => {
    await saveTrip(campusTrip);
    const root = await open(
      backend([sampleResponse('wait', START), new TypeError('offline')]),
    );
    await flush(5 * 60_000);
    expect(allText(root)).toContain('Wait 60 minutes');
    expect(hasText(root, 'Could not refresh')).toBe(true);
  });

  it('refreshes on demand', async () => {
    await saveTrip(campusTrip);
    const api = backend([sampleResponse('leave_now', START)]);
    const root = await open(api);
    press(root, 'Refresh now');
    await flush();
    expect(api.verdicts).toHaveLength(2);
  });

  it('does not carry an old answer into a different trip', async () => {
    await saveTrip(campusTrip);
    const root = await open(
      backend([
        sampleResponse('wait', START),
        sampleResponse('leave_now', START),
      ]),
    );
    expect(allText(root)).toContain('Wait 60 minutes');
    press(root, SAC_STATE.name);
    press(root, SFSU.name);
    expect(allText(root)).not.toContain('Wait 60 minutes'); // gone straight away
    await flush(600);
    expect(allText(root)).toContain('Leave now');
  });
});

describe('weather credit', () => {
  it('credits Open-Meteo under a live answer, saying the data was changed', async () => {
    await saveTrip(campusTrip);
    const root = await open(backend([sampleResponse('leave_now', START)]));
    expect(hasText(root, 'Weather data by Open-Meteo.com')).toBe(true);
    expect(hasText(root, 'CC BY 4.0')).toBe(true);
    expect(hasText(root, 'Changed: rain forecasts')).toBe(true);
  });

  it('does not credit it before there is an answer, or on made-up samples', async () => {
    await saveTrip(campusTrip);
    const root = await open(backend([new TypeError('offline')]));
    expect(hasText(root, 'Open-Meteo')).toBe(false);
    press(root, 'Demo options');
    press(root, 'Sample: Wait');
    await flush(600);
    expect(hasText(root, 'Open-Meteo')).toBe(false);
  });

  it('links to Open-Meteo and to the license', async () => {
    await saveTrip(campusTrip);
    const opened = jest.spyOn(Linking, 'openURL').mockResolvedValue();
    try {
      const root = await open(backend([sampleResponse('leave_now', START)]));
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
    await saveTrip(campusTrip);
    const opened = jest
      .spyOn(Linking, 'openURL')
      .mockRejectedValue(new Error('no app to open this'));
    try {
      const root = await open(backend([sampleResponse('leave_now', START)]));
      tapLink(root, 'Open-Meteo.com');
      await flush();
      expect(allText(root)).toContain('Leave now');
    } finally {
      opened.mockRestore();
    }
  });
});
