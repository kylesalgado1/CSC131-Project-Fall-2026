// Runs with Node's built-in test runner (`npm test` in backend/), like the
// other tests in this directory.
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { describe, it } from 'node:test';
import {
  bearerMatches,
  issueCredential,
  parseBearer,
  sha256Hex,
  verifySecret,
} from '../auth';

const DEVICE_ID = '7b0b2c7e-3f0e-4a57-9f38-0d0c3a1b2c3d';
const SECRET = 'A'.repeat(43);

describe('issueCredential', () => {
  it('makes a UUID, a 43-character secret and the token that joins them', () => {
    const credential = issueCredential();
    assert.match(
      credential.deviceId,
      /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/,
    );
    assert.match(credential.secret, /^[A-Za-z0-9_-]{43}$/);
    assert.equal(
      credential.token,
      `${credential.deviceId}.${credential.secret}`,
    );
  });

  it('gives the SHA-256 of the secret to store, in hex', () => {
    const credential = issueCredential();
    assert.equal(
      credential.secretHash,
      createHash('sha256').update(credential.secret).digest('hex'),
    );
    assert.match(credential.secretHash, /^[0-9a-f]{64}$/);
  });

  it('never repeats itself', () => {
    const a = issueCredential();
    const b = issueCredential();
    assert.notEqual(a.deviceId, b.deviceId);
    assert.notEqual(a.secret, b.secret);
  });

  it('issues a token its own parser accepts', () => {
    const credential = issueCredential();
    assert.deepEqual(parseBearer(`Bearer ${credential.token}`), {
      deviceId: credential.deviceId,
      secret: credential.secret,
    });
  });
});

describe('parseBearer', () => {
  it('reads the device id and the secret', () => {
    assert.deepEqual(parseBearer(`Bearer ${DEVICE_ID}.${SECRET}`), {
      deviceId: DEVICE_ID,
      secret: SECRET,
    });
  });

  it('does not mind how the scheme is capitalised', () => {
    assert.ok(parseBearer(`bearer ${DEVICE_ID}.${SECRET}`));
  });

  const malformed: Array<[string, string | undefined]> = [
    ['a missing header', undefined],
    ['an empty header', ''],
    ['another scheme', `Basic ${DEVICE_ID}.${SECRET}`],
    ['no scheme', `${DEVICE_ID}.${SECRET}`],
    ['no secret', `Bearer ${DEVICE_ID}`],
    ['a short secret', `Bearer ${DEVICE_ID}.${'A'.repeat(42)}`],
    ['a long secret', `Bearer ${DEVICE_ID}.${'A'.repeat(44)}`],
    ['a secret with other characters', `Bearer ${DEVICE_ID}.${'+'.repeat(43)}`],
    ['an upper-case id', `Bearer ${DEVICE_ID.toUpperCase()}.${SECRET}`],
    ['an id that is not a UUID', `Bearer ${'-'.repeat(36)}.${SECRET}`],
    [
      'an id with its dashes misplaced',
      `Bearer 7b0b2c7e3-f0e-4a57-9f38-0d0c3a1b2c3d.${SECRET}`,
    ],
    ['two tokens', `Bearer ${DEVICE_ID}.${SECRET} ${DEVICE_ID}.${SECRET}`],
    ['SQL in place of an id', `Bearer ' OR 1=1 --${'x'.repeat(24)}.${SECRET}`],
  ];
  for (const [name, header] of malformed) {
    it(`rejects ${name}`, () => {
      assert.equal(parseBearer(header), undefined);
    });
  }
});

describe('verifySecret', () => {
  it('accepts the secret whose hash is stored', () => {
    assert.equal(verifySecret(SECRET, sha256Hex(SECRET)), true);
  });

  it('rejects any other secret', () => {
    assert.equal(verifySecret('B'.repeat(43), sha256Hex(SECRET)), false);
    assert.equal(verifySecret('', sha256Hex(SECRET)), false);
  });

  it('rejects a stored value that is not a hash', () => {
    assert.equal(verifySecret(SECRET, ''), false);
    assert.equal(verifySecret(SECRET, 'not hex'), false);
    assert.equal(verifySecret(SECRET, SECRET), false);
  });
});

describe('bearerMatches', () => {
  const secret = 's3cr3t-'.repeat(6);

  it('accepts the shared secret as a bearer credential', () => {
    assert.equal(bearerMatches(`Bearer ${secret}`, secret), true);
  });

  it('rejects anything else', () => {
    assert.equal(bearerMatches(undefined, secret), false);
    assert.equal(bearerMatches('', secret), false);
    assert.equal(bearerMatches(secret, secret), false);
    assert.equal(bearerMatches(`Bearer ${secret}x`, secret), false);
    assert.equal(bearerMatches(`Bearer ${secret.slice(1)}`, secret), false);
    assert.equal(bearerMatches('Bearer ', secret), false);
  });
});
