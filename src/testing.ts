import { ActivityIndicator, Text, TextInput } from 'react-native';
import { createElement } from 'react';
import ReactTestRenderer, { act, ReactTestInstance } from 'react-test-renderer';

const flatten = (children: unknown): string =>
  Array.isArray(children)
    ? children.map(flatten).join('')
    : children === null ||
      children === undefined ||
      typeof children === 'boolean'
    ? ''
    : String(children);

/** Every piece of text on screen, in order. */
export const allText = (root: ReactTestInstance): string[] =>
  root.findAllByType(Text).map(node => flatten(node.props.children));

export const hasText = (root: ReactTestInstance, text: string): boolean =>
  allText(root).some(t => t.includes(text));

/** The button whose text contains the given label. */
export function pressable(root: ReactTestInstance, label: string) {
  const found = root
    .findAll(
      node =>
        node.props.accessibilityRole === 'button' &&
        typeof node.props.onPress === 'function',
    )
    .find(node => allText(node).some(t => t.includes(label)));
  if (!found) {
    throw new Error(`No button with text "${label}"`);
  }
  return found;
}

export const arriveByInput = (root: ReactTestInstance) =>
  root
    .findAllByType(TextInput)
    .find(node => node.props.accessibilityLabel === 'Arrive by time')!;

/**
 * Taps a button. The handler's return value is dropped on purpose: a handler
 * that returns a promise would make `act` think it is asynchronous.
 */
export function press(root: ReactTestInstance, label: string): void {
  const button = pressable(root, label);
  act(() => {
    button.props.onPress();
  });
}

/** Types into the arrive-by box. */
export function typeArriveBy(root: ReactTestInstance, text: string): void {
  const input = arriveByInput(root);
  act(() => {
    input.props.onChangeText(text);
  });
}

/** Taps a link by its text. */
export function tapLink(root: ReactTestInstance, label: string): void {
  const link = root
    .findAll(
      node =>
        node.props.accessibilityRole === 'link' &&
        typeof node.props.onPress === 'function',
    )
    .find(node => allText(node).some(t => t.includes(label)));
  if (!link) {
    throw new Error(`No link with text "${label}"`);
  }
  act(() => {
    link.props.onPress();
  });
}

/**
 * Runs a hook inside a throwaway component and hands back its latest value,
 * so hooks can be tested without a screen.
 */
export function renderHook<T>(hook: () => T) {
  const result = { current: undefined as unknown as T };
  let run = hook;
  function Probe() {
    result.current = run();
    return null;
  }
  let renderer!: ReactTestRenderer.ReactTestRenderer;
  act(() => {
    renderer = ReactTestRenderer.create(createElement(Probe));
  });
  return {
    result,
    /** Runs again with a different hook body, as if its inputs changed. */
    rerender(next: () => T) {
      run = next;
      act(() => {
        renderer.update(createElement(Probe));
      });
    },
    unmount() {
      act(() => renderer.unmount());
    },
  };
}

/** Lets time pass under fake timers, with React caught up after each step. */
export async function flush(ms = 0): Promise<void> {
  await act(async () => {
    await jest.advanceTimersByTimeAsync(ms);
  });
}

export const hasSpinner = (root: ReactTestInstance): boolean =>
  root.findAllByType(ActivityIndicator).length > 0;

/** Types into any text box, found by its accessibility label. */
export function typeInto(
  root: ReactTestInstance,
  label: string,
  text: string,
): void {
  const input = root
    .findAllByType(TextInput)
    .find(node => node.props.accessibilityLabel === label);
  if (!input) {
    throw new Error(`No text box labeled "${label}"`);
  }
  act(() => {
    input.props.onChangeText(text);
  });
}

/** Taps the button whose text is exactly the given text, not just containing it. */
export function pressExact(root: ReactTestInstance, label: string): void {
  const button = root
    .findAll(
      node =>
        node.props.accessibilityRole !== 'adjustable' &&
        typeof node.props.onPress === 'function' &&
        allText(node).length > 0 &&
        allText(node).every(text => text === label),
    )
    .find(Boolean);
  if (!button) {
    throw new Error(`No button with exactly "${label}"`);
  }
  act(() => {
    button.props.onPress();
  });
}

/** Taps something that has an accessibility label but no text of its own. */
export function pressLabeled(root: ReactTestInstance, label: string): void {
  const target = root
    .findAll(
      node =>
        node.props.accessibilityLabel === label &&
        typeof node.props.onPress === 'function',
    )
    .find(Boolean);
  if (!target) {
    throw new Error(`Nothing labeled "${label}"`);
  }
  act(() => {
    target.props.onPress();
  });
}
