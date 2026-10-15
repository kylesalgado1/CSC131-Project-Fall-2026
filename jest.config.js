module.exports = {
  preset: 'jest-expo',
  setupFiles: ['<rootDir>/jest.setup.js'],
  // These run with Node's test runner: see `npm run test:db`.
  testPathIgnorePatterns: [
    '/node_modules/',
    '/backend/db/__tests__/',
    '/backend/api/__tests__/',
  ],
};
