module.exports = {
  preset: 'jest-expo',
  // These run with Node's test runner: see `npm run test:db`.
  testPathIgnorePatterns: [
    '/node_modules/',
    '/backend/db/__tests__/',
    '/backend/api/__tests__/',
  ],
};
