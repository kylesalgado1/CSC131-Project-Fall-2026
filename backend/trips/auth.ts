import { createHash, randomBytes, randomUUID, timingSafeEqual } from 'crypto';

/** What a new device is given. Only `secretHash` is ever stored. */
export interface Credential {
  deviceId: string;
  secret: string;
  /** What the device sends as its credential: the id, a dot, the secret. */
  token: string;
  secretHash: string;
}

/** The two halves of a bearer credential. */
export interface BearerCredential {
  deviceId: string;
  secret: string;
}

// The shape every credential has, checked before anything is looked up.
const CREDENTIAL_PATTERN = /^[0-9a-f-]{36}\.[A-Za-z0-9_-]{43}$/;
// The looser pattern above lets 36 dashes through; the database would not.
const UUID_PATTERN =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
const BEARER_PATTERN = /^Bearer ([^\s]+)$/i;

/** SHA-256 of a text, in hex. */
export const sha256Hex = (text: string): string =>
  createHash('sha256').update(text).digest('hex');

/** A new device id with a random 256-bit secret. */
export function issueCredential(): Credential {
  const deviceId = randomUUID();
  const secret = randomBytes(32).toString('base64url');
  return {
    deviceId,
    secret,
    token: `${deviceId}.${secret}`,
    secretHash: sha256Hex(secret),
  };
}

const bearerToken = (header: string | undefined): string | undefined =>
  header === undefined ? undefined : BEARER_PATTERN.exec(header)?.[1];

/**
 * The device id and secret in an Authorization header, or nothing when the
 * header is missing or is not shaped like a credential this server issues.
 */
export function parseBearer(
  header: string | undefined,
): BearerCredential | undefined {
  const token = bearerToken(header);
  if (!token || !CREDENTIAL_PATTERN.test(token)) {
    return undefined;
  }
  const deviceId = token.slice(0, 36);
  if (!UUID_PATTERN.test(deviceId)) {
    return undefined;
  }
  return { deviceId, secret: token.slice(37) };
}

const sameDigest = (a: Buffer, b: Buffer): boolean =>
  a.length === b.length && timingSafeEqual(a, b);

/** Whether a secret is the one whose hash is stored, in constant time. */
export function verifySecret(secret: string, storedHash: string): boolean {
  return sameDigest(
    createHash('sha256').update(secret).digest(),
    Buffer.from(storedHash, 'hex'),
  );
}

/**
 * Whether an Authorization header carries the given shared secret. The two
 * are compared through their SHA-256, so neither the length nor the content
 * of the secret shows in how long it takes.
 */
export function bearerMatches(
  header: string | undefined,
  secret: string,
): boolean {
  const token = bearerToken(header);
  return (
    token !== undefined &&
    sameDigest(
      createHash('sha256').update(token).digest(),
      createHash('sha256').update(secret).digest(),
    )
  );
}
