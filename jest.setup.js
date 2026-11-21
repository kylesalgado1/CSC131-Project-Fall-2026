/* eslint-env jest */
// Saved trips and recent places live in AsyncStorage, which needs a phone. Tests
// get an in-memory copy instead.
jest.mock('@react-native-async-storage/async-storage', () =>
  require('@react-native-async-storage/async-storage/jest/async-storage-mock'),
);
