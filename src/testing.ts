import { Text, TextInput } from 'react-native';
import { act, ReactTestInstance } from 'react-test-renderer';

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
