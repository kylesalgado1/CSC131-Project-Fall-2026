// Runs with Node's built-in test runner (`npm test` in backend/), like the
// other backend tests that need real sockets.
//
// The sender talks to a real HTTP/2 server on this machine that plays APNs:
// nothing here leaves 127.0.0.1. The key pair is made up for the test.
import assert from 'node:assert/strict';
import {
  createPublicKey,
  generateKeyPairSync,
  KeyObject,
  randomUUID,
  verify,
} from 'node:crypto';
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import {
  connect,
  constants,
  createServer,
  Http2Server,
  IncomingHttpHeaders,
  ServerHttp2Session,
  ServerHttp2Stream,
} from 'node:http2';
import { AddressInfo } from 'node:net';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { after, afterEach, before, beforeEach, describe, it } from 'node:test';
import {
  APNS_AUTHORITIES,
  ApnsSender,
  DEFAULT_BUNDLE_ID,
  MAX_PAYLOAD_BYTES,
  NoPushSender,
  PushConfigError,
  PushMessage,
  pushSenderFromEnv,
} from '../apns';

const KEY_ID = 'ABC123DEFG';
const TEAM_ID = 'TEAM456XYZ';
const BUNDLE_ID = 'com.example.waititout';
const TOKEN = 'ab'.repeat(32);
const MINUTE = 60_000;
const START = Date.parse('2026-11-20T14:00:00.000Z');

const { privateKey, publicKey } = generateKeyPairSync('ec', {
  namedCurve: 'prime256v1',
});
const PRIVATE_PEM = privateKey
  .export({ type: 'pkcs8', format: 'pem' })
  .toString();

/** What the fake APNs is told to do with a request. */
type Reply =
  | { status: number; reason?: string; raw?: string }
  /** Never answer. */
  | 'silent'
  /** Drop the connection without answering. */
  | 'drop'
  /** Reset the stream, saying the request was not processed. */
  | 'refuse'
  /** Say the connection is closing, and that this request was not taken. */
  | 'goaway'
  /** Say it is closing, having taken this request, and then answer it. */
  | 'goaway-then-answer';

interface Seen {
  headers: IncomingHttpHeaders;
  body: string;
  session: number;
}

/** A local HTTP/2 server that records requests and answers as told. */
class FakeApns {
  readonly seen: Seen[] = [];
  /** What to answer next, in order. When empty: 200. */
  replies: Reply[] = [];
  private readonly sessions: ServerHttp2Session[] = [];
  private readonly server: Http2Server = createServer();

  constructor() {
    this.server.on('session', session => {
      this.sessions.push(session);
      session.on('error', () => undefined);
    });
    this.server.on(
      'stream',
      (stream: ServerHttp2Stream, headers: IncomingHttpHeaders) => {
        const chunks: Buffer[] = [];
        stream.on('error', () => undefined);
        stream.on('data', (chunk: Buffer) => chunks.push(chunk));
        stream.on('end', () => {
          const session = stream.session as ServerHttp2Session;
          this.seen.push({
            headers,
            body: Buffer.concat(chunks).toString('utf8'),
            session: this.sessions.indexOf(session),
          });
          const reply = this.replies.shift() ?? { status: 200 };
          if (reply === 'silent') {
            return;
          }
          if (reply === 'drop') {
            session.destroy();
            return;
          }
          if (reply === 'refuse') {
            stream.close(constants.NGHTTP2_REFUSED_STREAM);
            return;
          }
          if (reply === 'goaway') {
            // The last request taken is the one before this. (Not for a
            // connection's first request: Node has no way to say "none".)
            session.goaway(constants.NGHTTP2_NO_ERROR, (stream.id ?? 1) - 2);
            return;
          }
          if (reply === 'goaway-then-answer') {
            session.goaway(constants.NGHTTP2_NO_ERROR, stream.id);
            stream.respond({ ':status': 200, 'apns-id': headers['apns-id'] });
            stream.end();
            return;
          }
          stream.respond({
            ':status': reply.status,
            'apns-id': headers['apns-id'],
          });
          stream.end(
            reply.raw ??
              (reply.reason ? JSON.stringify({ reason: reply.reason }) : ''),
          );
        });
      },
    );
  }

  /** How many connections were opened to it. */
  get connections(): number {
    return this.sessions.length;
  }

  async start(): Promise<string> {
    await new Promise<void>(resolve =>
      this.server.listen(0, '127.0.0.1', resolve),
    );
    const { port } = this.server.address() as AddressInfo;
    return `http://127.0.0.1:${port}`;
  }

  /** Closes every connection, as APNs does to one it is done with. */
  dropConnections(): void {
    for (const session of this.sessions) {
      session.destroy();
    }
  }

  /** Tells every connection to wind down, as APNs does before closing. */
  goAway(): void {
    for (const session of this.sessions) {
      if (!session.destroyed) {
        session.goaway();
      }
    }
  }

  async stop(): Promise<void> {
    this.dropConnections();
    await new Promise<void>(resolve => this.server.close(() => resolve()));
  }
}

let apns: FakeApns;
let url: string;
let nowMs: number;
let asked: string[];
let senders: ApnsSender[];

beforeEach(async () => {
  apns = new FakeApns();
  url = await apns.start();
  nowMs = START;
  asked = [];
  senders = [];
});

afterEach(async () => {
  for (const sender of senders) {
    await sender.close();
  }
  await apns.stop();
});

const sender = (over: { requestTimeoutMs?: number; to?: string } = {}) => {
  const made = new ApnsSender({
    keyId: KEY_ID,
    teamId: TEAM_ID,
    bundleId: BUNDLE_ID,
    privateKeyPem: PRIVATE_PEM,
    connect: authority => {
      asked.push(authority);
      return connect(over.to ?? url);
    },
    now: () => nowMs,
    requestTimeoutMs: over.requestTimeoutMs ?? 2000,
  });
  senders.push(made);
  return made;
};

const PAYLOAD = {
  aps: {
    alert: {
      title: 'Heads up: Chem lab',
      body: 'Plan to leave around 7:30 AM.',
    },
    sound: 'default',
    'thread-id': 'trip-A1B2C3@2026-11-20',
    category: 'WAIT_IT_OUT_TRIP',
  },
  tripId: 'A1B2C3@2026-11-20',
  kind: 'heads_up',
  departAt: '2026-11-20T15:30:00.000Z',
  arriveBy: '2026-11-20T16:00:00.000Z',
};

const message = (over: Partial<PushMessage> = {}): PushMessage => ({
  id: 'd2c7a3f0-6a59-4a3e-9d2b-0c1f5b7e8a90',
  deviceToken: TOKEN,
  environment: 'sandbox',
  collapseId: '7b0b2c7e-3f0e-4a57-9f38-0d0c3a1b2c3d',
  expiresAt: new Date('2026-11-20T15:30:00.500Z'),
  payload: PAYLOAD,
  ...over,
});

const jwtOf = (seen: Seen): string => {
  const header = seen.headers.authorization;
  assert.equal(typeof header, 'string');
  assert.match(header as string, /^bearer [\w-]+\.[\w-]+\.[\w-]+$/);
  return (header as string).slice('bearer '.length);
};

const decode = (part: string) =>
  JSON.parse(Buffer.from(part, 'base64url').toString('utf8'));

const verifies = (jwt: string, key: KeyObject): boolean => {
  const [header, claims, signature] = jwt.split('.');
  return verify(
    'sha256',
    Buffer.from(`${header}.${claims}`),
    { key, dsaEncoding: 'ieee-p1363' },
    Buffer.from(signature, 'base64url'),
  );
};

describe('a request to APNs', () => {
  it('is a POST to the device’s path with every header APNs needs and the payload as its body', async () => {
    const result = await sender().send(message());
    assert.deepEqual(result, {
      ok: true,
      apnsId: 'd2c7a3f0-6a59-4a3e-9d2b-0c1f5b7e8a90',
    });
    assert.equal(apns.seen.length, 1);
    const { headers, body } = apns.seen[0];
    assert.equal(headers[':method'], 'POST');
    assert.equal(headers[':path'], `/3/device/${TOKEN}`);
    assert.equal(headers['apns-topic'], BUNDLE_ID);
    assert.equal(headers['apns-push-type'], 'alert');
    assert.equal(headers['apns-priority'], '10');
    assert.equal(headers['apns-id'], 'd2c7a3f0-6a59-4a3e-9d2b-0c1f5b7e8a90');
    assert.equal(
      headers['apns-collapse-id'],
      '7b0b2c7e-3f0e-4a57-9f38-0d0c3a1b2c3d',
    );
    // Whole seconds since 1970, rounded down.
    assert.equal(
      headers['apns-expiration'],
      String(Date.parse('2026-11-20T15:30:00.000Z') / 1000),
    );
    assert.equal(headers['content-type'], 'application/json');
    assert.equal(headers['content-length'], String(Buffer.byteLength(body)));
    assert.deepEqual(JSON.parse(body), PAYLOAD);
    // Exactly these, beside what HTTP/2 itself adds.
    assert.deepEqual(
      Object.keys(headers)
        .filter(name => !name.startsWith(':'))
        .sort(),
      [
        'apns-collapse-id',
        'apns-expiration',
        'apns-id',
        'apns-priority',
        'apns-push-type',
        'apns-topic',
        'authorization',
        'content-length',
        'content-type',
      ],
    );
  });

  it('goes to the sandbox or the production host as the message says', async () => {
    const push = sender();
    await push.send(message({ environment: 'sandbox' }));
    await push.send(message({ environment: 'production' }));
    await push.send(message({ environment: 'sandbox' }));
    // One connection per host, opened when first needed and then reused.
    assert.deepEqual(asked, [
      'https://api.sandbox.push.apple.com:443',
      'https://api.push.apple.com:443',
    ]);
    assert.deepEqual(APNS_AUTHORITIES, {
      sandbox: 'https://api.sandbox.push.apple.com:443',
      production: 'https://api.push.apple.com:443',
    });
    assert.deepEqual(
      apns.seen.map(seen => seen.session),
      [0, 1, 0],
    );
  });

  it('is signed with a JWT that names the key and the team and verifies with the public key', async () => {
    await sender().send(message());
    const jwt = jwtOf(apns.seen[0]);
    const [header, claims, signature] = jwt.split('.');
    assert.deepEqual(decode(header), { alg: 'ES256', kid: KEY_ID });
    assert.deepEqual(decode(claims), {
      iss: TEAM_ID,
      iat: Math.floor(START / 1000),
    });
    // ES256 as JWTs carry it: r and s side by side, 32 bytes each.
    assert.equal(Buffer.from(signature, 'base64url').length, 64);
    assert.equal(verifies(jwt, publicKey), true);
    const other = generateKeyPairSync('ec', { namedCurve: 'prime256v1' });
    assert.equal(verifies(jwt, other.publicKey), false);
    assert.equal(verifies(jwt, createPublicKey(PRIVATE_PEM)), true);
  });
});

describe('the provider token', () => {
  it('is reused from one send to the next, on the same connection', async () => {
    const push = sender();
    await push.send(message());
    nowMs += 9 * MINUTE;
    await push.send(message({ id: randomUUID() }));
    assert.equal(jwtOf(apns.seen[0]), jwtOf(apns.seen[1]));
    assert.equal(apns.connections, 1);
  });

  it('is kept for 50 minutes and then renewed', async () => {
    const push = sender();
    await push.send(message());
    nowMs = START + 49 * MINUTE;
    await push.send(message());
    nowMs = START + 50 * MINUTE;
    await push.send(message());
    const [first, second, third] = apns.seen.map(jwtOf);
    assert.equal(first, second);
    assert.notEqual(second, third);
    assert.equal(decode(third.split('.')[1]).iat, (START + 50 * MINUTE) / 1000);
    assert.equal(verifies(third, publicKey), true);
  });

  it('is renewed, and the alert sent once more, when APNs says it has expired', async () => {
    const push = sender();
    await push.send(message());
    // 25 minutes on, APNs rejects the token as expired.
    nowMs = START + 25 * MINUTE;
    apns.replies = [{ status: 403, reason: 'ExpiredProviderToken' }];
    const result = await push.send(message());
    assert.deepEqual(result, {
      ok: true,
      apnsId: 'd2c7a3f0-6a59-4a3e-9d2b-0c1f5b7e8a90',
    });
    const [first, rejected, renewed] = apns.seen.map(jwtOf);
    assert.equal(apns.seen.length, 3);
    assert.equal(first, rejected);
    assert.notEqual(rejected, renewed);
    assert.equal(
      decode(renewed.split('.')[1]).iat,
      (START + 25 * MINUTE) / 1000,
    );
    // The renewed one is then kept.
    await push.send(message());
    assert.equal(jwtOf(apns.seen[3]), renewed);
  });

  it('is not renewed twice for one alert', async () => {
    const push = sender();
    await push.send(message());
    nowMs = START + 25 * MINUTE;
    apns.replies = [
      { status: 403, reason: 'ExpiredProviderToken' },
      { status: 403, reason: 'ExpiredProviderToken' },
    ];
    assert.deepEqual(await push.send(message()), {
      ok: false,
      kind: 'config',
      reason: 'ExpiredProviderToken',
      status: 403,
    });
    assert.equal(apns.seen.length, 3);
  });

  it('is not renewed when it is too new to have expired: the clocks disagree', async () => {
    const push = sender();
    await push.send(message());
    nowMs = START + 19 * MINUTE;
    apns.replies = [{ status: 403, reason: 'ExpiredProviderToken' }];
    assert.deepEqual(await push.send(message()), {
      ok: false,
      kind: 'config',
      reason: 'clock_skew',
      status: 403,
    });
    // No second request, and no new token on this connection.
    assert.equal(apns.seen.length, 2);
    nowMs = START + 19 * MINUTE + 1000;
    await push.send(message());
    assert.equal(jwtOf(apns.seen[2]), jwtOf(apns.seen[0]));
  });
});

describe('what APNs answers', () => {
  const cases: Array<
    [
      number,
      string | undefined,
      'invalid_token' | 'retryable' | 'config',
      string,
    ]
  > = [
    [400, 'BadDeviceToken', 'invalid_token', 'BadDeviceToken'],
    [400, 'DeviceTokenNotForTopic', 'invalid_token', 'DeviceTokenNotForTopic'],
    [410, 'Unregistered', 'invalid_token', 'Unregistered'],
    [410, 'ExpiredToken', 'invalid_token', 'ExpiredToken'],
    [429, 'TooManyRequests', 'retryable', 'TooManyRequests'],
    [
      429,
      'TooManyProviderTokenUpdates',
      'retryable',
      'TooManyProviderTokenUpdates',
    ],
    [500, 'InternalServerError', 'retryable', 'InternalServerError'],
    [503, 'ServiceUnavailable', 'retryable', 'ServiceUnavailable'],
    [503, 'Shutdown', 'retryable', 'Shutdown'],
    [400, 'BadTopic', 'config', 'BadTopic'],
    [400, 'BadCollapseId', 'config', 'BadCollapseId'],
    [403, 'InvalidProviderToken', 'config', 'InvalidProviderToken'],
    [403, 'BadEnvironmentKeyIdInToken', 'config', 'BadEnvironmentKeyIdInToken'],
    [413, 'PayloadTooLarge', 'config', 'PayloadTooLarge'],
    [404, undefined, 'config', 'http_404'],
    [502, undefined, 'retryable', 'http_502'],
  ];
  for (const [status, reason, kind, code] of cases) {
    it(`maps ${status} ${reason ?? 'with no reason'} to ${kind}`, async () => {
      apns.replies = [{ status, reason }];
      assert.deepEqual(await sender().send(message()), {
        ok: false,
        kind,
        reason: code,
        status,
      });
      assert.equal(apns.seen.length, 1);
    });
  }

  it('accepts a 200 that names no id', async () => {
    const result = await sender().send(message());
    assert.equal(result.ok, true);
  });

  it('reports a body that is not JSON, or a reason that is not a plain code, by its status alone', async () => {
    apns.replies = [
      { status: 503, raw: '<html>Service Unavailable</html>' },
      { status: 400, raw: JSON.stringify({ reason: `Bad token ${TOKEN}` }) },
      { status: 400, raw: JSON.stringify({ reason: 42 }) },
    ];
    const push = sender();
    assert.deepEqual(await push.send(message()), {
      ok: false,
      kind: 'retryable',
      reason: 'http_503',
      status: 503,
    });
    assert.deepEqual(await push.send(message()), {
      ok: false,
      kind: 'config',
      reason: 'http_400',
      status: 400,
    });
    assert.deepEqual(await push.send(message()), {
      ok: false,
      kind: 'config',
      reason: 'http_400',
      status: 400,
    });
  });
});

describe('a message that cannot be sent as it is', () => {
  it('is refused without a request when its payload is over 4096 bytes', async () => {
    const push = sender();
    const filler = (bytes: number) => ({ text: 'x'.repeat(bytes) });
    const overhead = Buffer.byteLength(JSON.stringify(filler(0)));
    assert.equal(MAX_PAYLOAD_BYTES, 4096);
    assert.deepEqual(
      await push.send(message({ payload: filler(4097 - overhead) })),
      { ok: false, kind: 'config', reason: 'PayloadTooLarge' },
    );
    assert.equal(apns.seen.length, 0);
    assert.equal(
      (await push.send(message({ payload: filler(4096 - overhead) }))).ok,
      true,
    );
    // Bytes, not characters.
    assert.deepEqual(
      await push.send(message({ payload: { text: 'é'.repeat(2100) } })),
      { ok: false, kind: 'config', reason: 'PayloadTooLarge' },
    );
  });

  it('is refused without a request when its device token is not hex', async () => {
    for (const deviceToken of ['', 'not-a-token', `${TOKEN}/../x`]) {
      assert.deepEqual(await sender().send(message({ deviceToken })), {
        ok: false,
        kind: 'invalid_token',
        reason: 'BadDeviceToken',
        status: 400,
      });
    }
    assert.equal(apns.seen.length, 0);
    assert.deepEqual(asked, []);
  });
});

describe('a connection that fails', () => {
  it('reports a request APNs never answered as unconfirmed, and starts the next on a new connection', async () => {
    const push = sender({ requestTimeoutMs: 40 });
    apns.replies = ['silent'];
    assert.deepEqual(await push.send(message()), {
      ok: false,
      kind: 'retryable',
      reason: 'timeout',
      unconfirmed: true,
    });
    // It was not tried again by itself: APNs may have taken it.
    assert.equal(apns.seen.length, 1);
    assert.equal(apns.connections, 1);

    assert.equal((await push.send(message())).ok, true);
    assert.equal(apns.connections, 2);
    assert.deepEqual(
      apns.seen.map(seen => seen.session),
      [0, 1],
    );
  });

  it('tries an unanswered alert again at once, on a new connection, when it is worth hearing twice', async () => {
    const push = sender({ requestTimeoutMs: 40 });
    apns.replies = ['silent'];
    assert.deepEqual(await push.send(message({ atLeastOnce: true })), {
      ok: true,
      apnsId: 'd2c7a3f0-6a59-4a3e-9d2b-0c1f5b7e8a90',
    });
    assert.deepEqual(
      apns.seen.map(seen => seen.session),
      [0, 1],
    );
    // The same alert both times.
    assert.equal(
      apns.seen[0].headers['apns-id'],
      apns.seen[1].headers['apns-id'],
    );
    assert.equal(jwtOf(apns.seen[0]), jwtOf(apns.seen[1]));
  });

  it('gives up after that one extra try', async () => {
    const push = sender({ requestTimeoutMs: 40 });
    apns.replies = ['silent', 'silent'];
    assert.deepEqual(await push.send(message({ atLeastOnce: true })), {
      ok: false,
      kind: 'retryable',
      reason: 'timeout',
      unconfirmed: true,
    });
    assert.equal(apns.seen.length, 2);
    assert.equal(apns.connections, 2);
  });

  it('treats a connection dropped after the request was sent the same way', async () => {
    const push = sender();
    apns.replies = ['drop'];
    assert.deepEqual(await push.send(message()), {
      ok: false,
      kind: 'retryable',
      reason: 'connection_failed',
      unconfirmed: true,
    });
    assert.equal(apns.seen.length, 1);

    apns.replies = ['drop'];
    assert.equal((await push.send(message({ atLeastOnce: true }))).ok, true);
    assert.equal(apns.seen.length, 3);
    assert.equal(apns.connections, 3);
  });

  it('tries a request APNs refused to process again at once, whatever the alert', async () => {
    const push = sender();
    // The whole request was written, and APNs reset the stream with
    // REFUSED_STREAM: by HTTP/2 that means it did nothing with it.
    apns.replies = ['refuse'];
    assert.deepEqual(await push.send(message()), {
      ok: true,
      apnsId: 'd2c7a3f0-6a59-4a3e-9d2b-0c1f5b7e8a90',
    });
    assert.deepEqual(
      apns.seen.map(seen => seen.session),
      [0, 1],
    );
    assert.equal(
      apns.seen[0].headers['apns-id'],
      apns.seen[1].headers['apns-id'],
    );
  });

  it('reports a request refused twice as not sent, with nothing unconfirmed about it', async () => {
    const push = sender();
    apns.replies = ['refuse', 'refuse'];
    // No "unconfirmed": APNs cannot have taken it, so even a heads-up may
    // be tried again later.
    assert.deepEqual(await push.send(message()), {
      ok: false,
      kind: 'retryable',
      reason: 'connection_failed',
    });
    assert.equal(apns.seen.length, 2);
  });

  it('tries a request again at once when APNs goes away having passed it over', async () => {
    // Long enough that waiting it out would be noticed.
    const push = sender({ requestTimeoutMs: 5000 });
    assert.equal((await push.send(message())).ok, true);
    // The second request on the connection is written in full, and APNs
    // answers with a GOAWAY that names the first as the last one it took.
    apns.replies = ['goaway'];
    const started = Date.now();
    assert.deepEqual(await push.send(message()), {
      ok: true,
      apnsId: 'd2c7a3f0-6a59-4a3e-9d2b-0c1f5b7e8a90',
    });
    assert.ok(Date.now() - started < 2500);
    assert.deepEqual(
      apns.seen.map(seen => seen.session),
      [0, 0, 1],
    );
  });

  it('waits for the answer to a request APNs took before it said it was going away', async () => {
    const push = sender();
    apns.replies = ['goaway-then-answer'];
    assert.deepEqual(await push.send(message()), {
      ok: true,
      apnsId: 'd2c7a3f0-6a59-4a3e-9d2b-0c1f5b7e8a90',
    });
    assert.equal(apns.seen.length, 1);
    // The next alert starts on a new connection.
    assert.equal((await push.send(message())).ok, true);
    assert.equal(apns.connections, 2);
  });

  it('tries once more at once, whatever the alert, when the request never left', async () => {
    // Nothing listens here, so no request can be written at all.
    await apns.stop();
    const push = sender();
    assert.deepEqual(await push.send(message()), {
      ok: false,
      kind: 'retryable',
      reason: 'connection_failed',
    });
    // Two connections were tried.
    assert.equal(asked.length, 2);
    assert.equal(apns.seen.length, 0);
  });

  it('opens a new connection after APNs closes the old one', async () => {
    const push = sender();
    await push.send(message());
    apns.dropConnections();
    // Let the client notice.
    await new Promise(resolve => setImmediate(resolve));
    assert.equal((await push.send(message())).ok, true);
    assert.equal(apns.connections, 2);
  });

  it('opens a new connection after APNs says it is going away', async () => {
    const push = sender();
    await push.send(message());
    apns.goAway();
    // Let the client hear it.
    await new Promise(resolve => setImmediate(resolve));
    await new Promise(resolve => setImmediate(resolve));
    assert.equal((await push.send(message())).ok, true);
    assert.equal((await push.send(message())).ok, true);
    assert.equal(apns.seen.length, 3);
    assert.ok(apns.connections >= 2);
  });

  it('replaces a connection that sat idle for more than ten minutes before using it', async () => {
    const push = sender();
    await push.send(message());
    nowMs += 10 * MINUTE;
    await push.send(message());
    assert.equal(apns.connections, 1);
    nowMs += 10 * MINUTE + 1;
    await push.send(message());
    assert.equal(apns.connections, 2);
    assert.deepEqual(
      apns.seen.map(seen => seen.session),
      [0, 0, 1],
    );
  });

  it('can be closed, and used again afterwards', async () => {
    const push = sender();
    await push.send(message());
    await push.close();
    await push.close();
    assert.equal((await push.send(message())).ok, true);
    assert.equal(apns.connections, 2);
  });
});

describe('what the sender gives away', () => {
  it('is never the device token, the provider token or the key, whatever goes wrong', async () => {
    const push = sender({ requestTimeoutMs: 40 });
    apns.replies = [
      { status: 400, reason: 'BadDeviceToken' },
      { status: 403, reason: 'InvalidProviderToken' },
      { status: 500, raw: `{"reason":"${TOKEN}"}` },
      'drop',
      'silent',
    ];
    const results = [];
    for (let i = 0; i < 5; i++) {
      results.push(await push.send(message()));
    }
    const said = JSON.stringify(results);
    const jwt = jwtOf(apns.seen[0]);
    assert.ok(!said.includes(TOKEN));
    assert.ok(!said.includes(jwt));
    assert.ok(!said.includes(jwt.split('.')[2]));
    assert.ok(!said.includes('PRIVATE KEY'));
    for (const result of results) {
      assert.equal(result.ok, false);
      assert.match(
        (result as { reason: string }).reason,
        /^[A-Za-z0-9_]{1,64}$/,
      );
    }
  });
});

describe('the signing key', () => {
  it('must be readable, and the error does not repeat it', () => {
    const garbage =
      '-----BEGIN PRIVATE KEY-----\nSECRETSECRET\n-----END PRIVATE KEY-----';
    assert.throws(
      () =>
        new ApnsSender({
          keyId: KEY_ID,
          teamId: TEAM_ID,
          bundleId: BUNDLE_ID,
          privateKeyPem: garbage,
        }),
      (error: Error) => {
        assert.ok(error instanceof PushConfigError);
        assert.equal(error.message, 'The APNs signing key could not be read');
        assert.ok(!error.message.includes('SECRET'));
        return true;
      },
    );
  });

  it('must be an EC key', () => {
    const rsa = generateKeyPairSync('rsa', { modulusLength: 2048 })
      .privateKey.export({ type: 'pkcs8', format: 'pem' })
      .toString();
    assert.throws(
      () =>
        new ApnsSender({
          keyId: KEY_ID,
          teamId: TEAM_ID,
          bundleId: BUNDLE_ID,
          privateKeyPem: rsa,
        }),
      PushConfigError,
    );
  });
});

describe('NoPushSender', () => {
  it('is not configured and sends nothing', async () => {
    const none = new NoPushSender();
    assert.equal(none.configured, false);
    assert.deepEqual(await none.send(), {
      ok: false,
      kind: 'config',
      reason: 'push_not_configured',
    });
  });
});

describe('pushSenderFromEnv', () => {
  let dir: string;

  before(() => {
    dir = mkdtempSync(join(tmpdir(), 'apns-test-'));
  });

  after(() => {
    rmSync(dir, { recursive: true, force: true });
  });

  const read = (env: Record<string, string | undefined>) => {
    const warnings: string[] = [];
    const made = pushSenderFromEnv(env, text => warnings.push(text), {
      connect: authority => {
        asked.push(authority);
        return connect(url);
      },
      now: () => nowMs,
    });
    if (made instanceof ApnsSender) {
      senders.push(made);
    }
    return { made, warnings };
  };

  it('sends nothing, quietly, when APNs is not set up at all', () => {
    const { made, warnings } = read({});
    assert.ok(made instanceof NoPushSender);
    assert.equal(made.configured, false);
    assert.deepEqual(warnings, []);
  });

  it('reads the key as PEM text, with "\\n" for line breaks, and uses the app’s bundle id by default', async () => {
    const oneLine = PRIVATE_PEM.trim().replace(/\n/g, '\\n');
    assert.ok(!oneLine.includes('\n'));
    const { made, warnings } = read({
      APNS_KEY_ID: KEY_ID,
      APNS_TEAM_ID: TEAM_ID,
      APNS_PRIVATE_KEY: oneLine,
    });
    assert.deepEqual(warnings, []);
    assert.ok(made instanceof ApnsSender);
    assert.equal(made.configured, true);
    assert.equal((await made.send(message())).ok, true);
    assert.equal(
      apns.seen[0].headers['apns-topic'],
      'com.waititout.uxprototype',
    );
    assert.equal(DEFAULT_BUNDLE_ID, 'com.waititout.uxprototype');
    const jwt = jwtOf(apns.seen[0]);
    assert.deepEqual(decode(jwt.split('.')[0]), { alg: 'ES256', kid: KEY_ID });
    assert.equal(decode(jwt.split('.')[1]).iss, TEAM_ID);
    assert.equal(verifies(jwt, publicKey), true);
  });

  it('reads the key as PEM text with real line breaks, and the bundle id it is given', async () => {
    const { made } = read({
      APNS_KEY_ID: ` ${KEY_ID} `,
      APNS_TEAM_ID: TEAM_ID,
      APNS_BUNDLE_ID: BUNDLE_ID,
      APNS_PRIVATE_KEY: PRIVATE_PEM,
    });
    assert.equal((await made.send(message())).ok, true);
    assert.equal(apns.seen[0].headers['apns-topic'], BUNDLE_ID);
  });

  it('reads the key from a file', async () => {
    const path = join(dir, 'AuthKey_TEST.p8');
    writeFileSync(path, PRIVATE_PEM);
    const { made, warnings } = read({
      APNS_KEY_ID: KEY_ID,
      APNS_TEAM_ID: TEAM_ID,
      APNS_PRIVATE_KEY_FILE: path,
    });
    assert.deepEqual(warnings, []);
    assert.equal(made.configured, true);
    assert.equal((await made.send(message())).ok, true);
    assert.equal(verifies(jwtOf(apns.seen[0]), publicKey), true);
  });

  it('warns, naming the variable and not the path, when the key file cannot be read', () => {
    const path = join(dir, 'missing.p8');
    const { made, warnings } = read({
      APNS_KEY_ID: KEY_ID,
      APNS_TEAM_ID: TEAM_ID,
      APNS_PRIVATE_KEY_FILE: path,
    });
    assert.equal(made.configured, false);
    assert.equal(warnings.length, 1);
    assert.ok(warnings[0].includes('APNS_PRIVATE_KEY_FILE'));
    assert.ok(!warnings[0].includes(path));
  });

  for (const [name, env] of [
    ['the key id', { APNS_TEAM_ID: TEAM_ID, APNS_PRIVATE_KEY: PRIVATE_PEM }],
    ['the team id', { APNS_KEY_ID: KEY_ID, APNS_PRIVATE_KEY: PRIVATE_PEM }],
    ['the key', { APNS_KEY_ID: KEY_ID, APNS_TEAM_ID: TEAM_ID }],
  ] as const) {
    it(`warns once and sends nothing when only ${name} is missing`, () => {
      const { made, warnings } = read(env);
      assert.equal(made.configured, false);
      assert.equal(warnings.length, 1);
      assert.ok(warnings[0].includes('APNS_KEY_ID'));
      assert.ok(!warnings[0].includes('PRIVATE KEY-----'));
      assert.ok(!warnings[0].includes(KEY_ID));
    });
  }

  it('warns, without repeating it, when the key is not a key', () => {
    const { made, warnings } = read({
      APNS_KEY_ID: KEY_ID,
      APNS_TEAM_ID: TEAM_ID,
      APNS_PRIVATE_KEY: 'hunter2-not-a-key',
    });
    assert.equal(made.configured, false);
    assert.equal(warnings.length, 1);
    assert.ok(!warnings[0].includes('hunter2'));
  });
});
