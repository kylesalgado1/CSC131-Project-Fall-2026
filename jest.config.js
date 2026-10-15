module.exports = {
  preset: 'jest-expo',
  // These run with Node's test runner: see backend/db/__tests__/db.test.ts.
  testPathIgnorePatterns: ['/node_modules/', '/backend/db/__tests__/'],
};
