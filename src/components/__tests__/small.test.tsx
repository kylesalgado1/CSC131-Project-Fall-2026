import React from 'react';
import ReactTestRenderer, { act } from 'react-test-renderer';
import { allText, hasSpinner, hasText, press } from '../../testing';
import { Collapsible } from '../Collapsible';
import { EmptyState } from '../EmptyState';
import { Notice } from '../Notice';
import { TripCard } from '../TripCard';
import { QUICK_PICKS } from '../../trip/quickPicks';

function render(element: React.ReactElement) {
  let renderer!: ReactTestRenderer.ReactTestRenderer;
  act(() => {
    renderer = ReactTestRenderer.create(element);
  });
  return renderer.root;
}

describe('TripCard', () => {
  const base = {
    fromLabel: 'Current location',
    fromIsCurrent: true,
    locating: false,
    onPressFrom: jest.fn(),
    onPressTo: jest.fn(),
  };

  it('shows where from and where to', () => {
    const root = render(<TripCard {...base} toLabel="Sacramento State" />);
    expect(allText(root)).toEqual(
      expect.arrayContaining([
        'FROM',
        'Current location',
        'TO',
        'Sacramento State',
      ]),
    );
  });

  it('invites the user to choose a destination when there is none', () => {
    const root = render(<TripCard {...base} />);
    expect(hasText(root, 'Where are you going?')).toBe(true);
  });

  it('opens the right chooser from each row', () => {
    const onPressFrom = jest.fn();
    const onPressTo = jest.fn();
    const root = render(
      <TripCard
        {...base}
        onPressFrom={onPressFrom}
        onPressTo={onPressTo}
        toLabel="Sacramento State"
      />,
    );
    press(root, 'Current location');
    expect(onPressFrom).toHaveBeenCalledTimes(1);
    press(root, 'Sacramento State');
    expect(onPressTo).toHaveBeenCalledTimes(1);
  });

  it('offers a swap only when there is something to swap', () => {
    const onSwap = jest.fn();
    expect(hasText(render(<TripCard {...base} toLabel="X" />), '⇅')).toBe(
      false,
    );
    const root = render(<TripCard {...base} toLabel="X" onSwap={onSwap} />);
    press(root, '⇅');
    expect(onSwap).toHaveBeenCalledTimes(1);
  });

  it("shows a spinner next to the start only while finding the phone's position", () => {
    expect(
      hasSpinner(render(<TripCard {...base} locating toLabel="X" />)),
    ).toBe(true);
    expect(hasSpinner(render(<TripCard {...base} toLabel="X" />))).toBe(false);
    expect(
      hasSpinner(
        render(
          <TripCard {...base} fromIsCurrent={false} locating toLabel="X" />,
        ),
      ),
    ).toBe(false);
  });
});

describe('Collapsible', () => {
  it('is folded away to begin with, showing its summary', () => {
    const root = render(
      <Collapsible title="Preferences" summary="Balanced · wait up to 1 hr">
        <></>
      </Collapsible>,
    );
    expect(hasText(root, 'Preferences')).toBe(true);
    expect(hasText(root, 'Balanced · wait up to 1 hr')).toBe(true);
  });

  it('opens and closes, hiding the summary while open', () => {
    const { Text } = jest.requireActual('react-native');
    const root = render(
      <Collapsible title="Preferences" summary="the summary">
        <Text>inside the section</Text>
      </Collapsible>,
    );
    expect(hasText(root, 'inside the section')).toBe(false);
    press(root, 'Preferences');
    expect(hasText(root, 'inside the section')).toBe(true);
    expect(hasText(root, 'the summary')).toBe(false);
    press(root, 'Preferences');
    expect(hasText(root, 'inside the section')).toBe(false);
    expect(hasText(root, 'the summary')).toBe(true);
  });

  it('can start open', () => {
    const { Text } = jest.requireActual('react-native');
    const root = render(
      <Collapsible title="T" defaultOpen>
        <Text>shown at once</Text>
      </Collapsible>,
    );
    expect(hasText(root, 'shown at once')).toBe(true);
  });
});

describe('Notice', () => {
  it('shows a title and message, and buttons that do something', () => {
    const onRetry = jest.fn();
    const root = render(
      <Notice
        kind="error"
        title="Oops"
        actions={[{ label: 'Try again', onPress: onRetry }]}
      >
        Something broke.
      </Notice>,
    );
    expect(allText(root)).toEqual(
      expect.arrayContaining(['Oops', 'Something broke.', 'Try again']),
    );
    press(root, 'Try again');
    expect(onRetry).toHaveBeenCalledTimes(1);
  });

  it('needs no title or buttons', () => {
    expect(
      allText(render(<Notice kind="info">Just so you know.</Notice>)),
    ).toEqual(['Just so you know.']);
  });
});

describe('EmptyState', () => {
  it('asks where the user is going and offers a search and well-known places', () => {
    const root = render(
      <EmptyState onChooseDestination={jest.fn()} onPick={jest.fn()} />,
    );
    expect(hasText(root, 'Where are you going?')).toBe(true);
    expect(hasText(root, 'Search for a place')).toBe(true);
    for (const place of QUICK_PICKS) {
      expect(hasText(root, place.name)).toBe(true);
    }
  });

  it('hands back the place that was tapped, or opens the search', () => {
    const onPick = jest.fn();
    const onChoose = jest.fn();
    const root = render(
      <EmptyState onChooseDestination={onChoose} onPick={onPick} />,
    );
    press(root, QUICK_PICKS[1].name);
    expect(onPick).toHaveBeenCalledWith(QUICK_PICKS[1]);
    press(root, 'Search for a place');
    expect(onChoose).toHaveBeenCalledTimes(1);
  });
});
