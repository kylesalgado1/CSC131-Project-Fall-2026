import React from 'react';
import ReactTestRenderer, { act } from 'react-test-renderer';
import { Place } from '../../api/types';
import { QUICK_PICKS } from '../../trip/quickPicks';
import {
  allText,
  flush,
  hasSpinner,
  hasText,
  press,
  typeInto,
} from '../../testing';
import { PlaceSearchModal } from '../PlaceSearchModal';

jest.mock(
  'react-native-safe-area-context',
  () => require('react-native-safe-area-context/jest/mock').default,
);

const FIELD = 'Search for a place or address';
const place = (id: string, name = `Place ${id}`): Place => ({
  id,
  name,
  address: `${id} Street, Sacramento, CA`,
  lat: 38.5,
  lng: -121.5,
});

type Props = React.ComponentProps<typeof PlaceSearchModal>;

function backend(answer: (q: string) => Place[] | 'fail') {
  const urls: URL[] = [];
  const fetchFn = jest.fn(async (raw: string) => {
    const url = new URL(raw);
    urls.push(url);
    const result = answer(url.searchParams.get('q')!);
    if (result === 'fail') {
      return { ok: false, status: 503, json: async () => ({}) } as Response;
    }
    return {
      ok: true,
      status: 200,
      json: async () => ({ places: result }),
    } as Response;
  });
  return { fetchFn: fetchFn as unknown as typeof fetch, urls };
}

function open(over: Partial<Props> = {}) {
  const api = backend(() => []);
  const props: Props = {
    visible: true,
    mode: 'to',
    onClose: jest.fn(),
    onPick: jest.fn(),
    recents: [],
    baseUrl: 'http://h:3000',
    fetchFn: api.fetchFn,
    ...over,
  };
  let renderer!: ReactTestRenderer.ReactTestRenderer;
  act(() => {
    renderer = ReactTestRenderer.create(<PlaceSearchModal {...props} />);
  });
  return {
    root: renderer.root,
    props,
    renderer,
    api: over.fetchFn ? undefined : api,
    rerender: (next: Partial<Props>) =>
      act(() => renderer.update(<PlaceSearchModal {...props} {...next} />)),
  };
}

beforeEach(() => jest.useFakeTimers());
afterEach(() => jest.useRealTimers());

describe('PlaceSearchModal before anything is typed', () => {
  it('asks where to, and offers well-known places and a hint', () => {
    const { root } = open();
    expect(hasText(root, 'Where to?')).toBe(true);
    for (const p of QUICK_PICKS) {
      expect(hasText(root, p.name)).toBe(true);
    }
    expect(hasText(root, 'Type at least 3 letters to search.')).toBe(true);
    expect(hasText(root, 'Use my current location')).toBe(false); // a destination is a place
  });

  it('offers the current location when choosing where to start', () => {
    const onPickCurrent = jest.fn();
    const { root } = open({ mode: 'from', onPickCurrent });
    expect(hasText(root, 'Start from')).toBe(true);
    press(root, 'Use my current location');
    expect(onPickCurrent).toHaveBeenCalledTimes(1);
  });

  it('lists recent places before the well-known ones', () => {
    const { root } = open({ recents: [place('r1', 'My old place')] });
    const text = allText(root);
    expect(text).toContain('RECENT');
    expect(text.indexOf('My old place')).toBeLessThan(
      text.indexOf(QUICK_PICKS[0].name),
    );
  });

  it('hands back the place that was tapped', () => {
    const { root, props } = open({ recents: [place('r1', 'My old place')] });
    press(root, 'My old place');
    expect(props.onPick).toHaveBeenCalledWith(place('r1', 'My old place'));
    press(root, QUICK_PICKS[0].name);
    expect(props.onPick).toHaveBeenCalledWith(QUICK_PICKS[0]);
  });

  it('closes on Cancel', () => {
    const { root, props } = open();
    press(root, 'Cancel');
    expect(props.onClose).toHaveBeenCalledTimes(1);
  });

  it('is not shown when not visible', () => {
    expect(hasText(open({ visible: false }).root, 'Where to?')).toBe(false);
  });
});

describe('PlaceSearchModal while typing', () => {
  it('searches after a pause, near the user, and shows the places', async () => {
    const api = backend(q => [
      place('1', `${q} Hall`),
      place('2', `${q} Library`),
    ]);
    const { root } = open({
      fetchFn: api.fetchFn,
      near: { lat: 38.2383, lng: -122.0402 },
    });
    typeInto(root, FIELD, 'sac');
    expect(hasSpinner(root)).toBe(true);
    expect(hasText(root, 'Searching...')).toBe(true);
    await flush(400);
    expect(api.urls).toHaveLength(1);
    expect(api.urls[0].searchParams.get('q')).toBe('sac');
    expect(api.urls[0].searchParams.get('lat')).toBe('38.2383');
    expect(allText(root)).toEqual(
      expect.arrayContaining(['sac Hall', 'sac Library']),
    );
    expect(hasText(root, 'Type at least 3 letters')).toBe(false);
  });

  it('hands back the place that was tapped', async () => {
    const api = backend(() => [
      place('1', 'California State University, Sacramento'),
    ]);
    const { root, props } = open({ fetchFn: api.fetchFn });
    typeInto(root, FIELD, 'sac state');
    await flush(400);
    press(root, 'California State University, Sacramento');
    expect(props.onPick).toHaveBeenCalledWith(
      place('1', 'California State University, Sacramento'),
    );
  });

  it('hides the recent and well-known places while there are results', async () => {
    const api = backend(() => [place('1', 'A result')]);
    const { root } = open({
      fetchFn: api.fetchFn,
      recents: [place('r1', 'My old place')],
    });
    typeInto(root, FIELD, 'abc');
    await flush(400);
    expect(hasText(root, 'My old place')).toBe(false);
    expect(hasText(root, QUICK_PICKS[0].name)).toBe(false);
  });

  it('says when nothing matched, and keeps the current-location row for a start', async () => {
    const api = backend(() => []);
    const { root } = open({
      fetchFn: api.fetchFn,
      mode: 'from',
      onPickCurrent: jest.fn(),
    });
    typeInto(root, FIELD, 'zzzz');
    await flush(400);
    expect(hasText(root, 'No matches for "zzzz"')).toBe(true);
    expect(hasText(root, 'Use my current location')).toBe(true);
  });

  it('explains a failed search and still offers recent and well-known places', async () => {
    const api = backend(() => 'fail');
    const { root } = open({
      fetchFn: api.fetchFn,
      recents: [place('r1', 'My old place')],
    });
    typeInto(root, FIELD, 'sac');
    await flush(400);
    expect(hasText(root, 'Place search is not available right now.')).toBe(
      true,
    );
    expect(hasText(root, 'My old place')).toBe(true);
    expect(hasText(root, QUICK_PICKS[0].name)).toBe(true);
  });

  it('starts empty each time it is opened', async () => {
    const api = backend(() => [place('1', 'A result')]);
    const { root, rerender } = open({ fetchFn: api.fetchFn });
    typeInto(root, FIELD, 'abc');
    await flush(400);
    expect(hasText(root, 'A result')).toBe(true);
    rerender({ visible: false });
    rerender({ visible: true });
    await flush();
    expect(hasText(root, 'A result')).toBe(false);
    expect(hasText(root, 'Type at least 3 letters')).toBe(true);
  });
});
