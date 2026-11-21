// Runs with Node's built-in test runner (`npm test` in backend/), like the
// other tests in this directory.
import assert from 'node:assert/strict';
import { describe, it } from 'node:test';
import { EMPTY_SNAPSHOT_DIGEST, snapshotDigest, SnapshotTrip } from '../store';

const NOW = new Date('2026-11-20T15:00:00.000Z');
const minutes = (n: number) => new Date(NOW.getTime() + n * 60_000);

const LAB = 'A1B2C3@2026-11-20';
const GYM = 'D4E5F6@2026-11-20';

const trip = (over: Partial<SnapshotTrip> = {}): SnapshotTrip => ({
  id: LAB,
  title: 'Chem lab',
  origin: { lat: 38.2383, lng: -122.0402 },
  destination: { lat: 38.5593, lng: -121.4237 },
  destinationName: 'Sac State',
  arriveBy: minutes(180),
  startsAt: minutes(190),
  timeZone: 'America/Los_Angeles',
  ...over,
});

describe('the snapshot digest', () => {
  it('does not depend on the order of the trips', () => {
    const a = trip();
    const b = trip({ id: GYM, title: 'Gym' });
    assert.equal(snapshotDigest([a, b]), snapshotDigest([b, a]));
  });

  it('is the SHA-256 of the canonical JSON', () => {
    assert.match(snapshotDigest([trip()]), /^[0-9a-f]{64}$/);
    assert.equal(
      EMPTY_SNAPSHOT_DIGEST,
      // sha256("[]")
      '4f53cda18c2baa0c0354bb5f9a3ecbe5ed12ab4d8e11ba873c2f11161202b945',
    );
  });

  const changes: Array<[string, Partial<SnapshotTrip>]> = [
    ['id', { id: GYM }],
    ['title', { title: 'Lab' }],
    ['origin', { origin: { lat: 38.2383, lng: -122.04 } }],
    ['destination', { destination: { lat: 38.56, lng: -121.4237 } }],
    ['destination name', { destinationName: null }],
    ['arrival time', { arriveBy: minutes(181) }],
    ['start time', { startsAt: null }],
    ['time zone', { timeZone: 'UTC' }],
  ];
  for (const [name, change] of changes) {
    it(`changes with the ${name}`, () => {
      assert.notEqual(snapshotDigest([trip(change)]), snapshotDigest([trip()]));
    });
  }
});
