import { createPrivateKey, KeyObject, sign } from 'crypto';
import { readFileSync } from 'fs';
import {
  ClientHttp2Session,
  ClientHttp2Stream,
  connect as connectHttp2,
  constants as http2Constants,
  OutgoingHttpHeaders,
} from 'http2';
import { MINUTE_MS } from '../util/time';

/**
 * Sending alerts through the Apple Push Notification service (APNs), with
 * Node's own HTTP/2 and crypto and nothing else. Nothing here ever puts the
 * signing key, a provider token or a device token into an error or a log.
 */

/** Which of Apple's two services a device token belongs to. */
export type PushEnvironment = 'sandbox' | 'production';

/** One alert for one device. */
export interface PushMessage {
  /**
   * A UUID, the same for every attempt at one alert. It names the alert in
   * what APNs answers; APNs does not use it to weed out repeats.
   */
  id: string;
  /** The device's APNs token, in hex. */
  deviceToken: string;
  environment: PushEnvironment;
  /**
   * Alerts with the same collapse id replace one another on the device, so
   * at most one entry for a trip remains in Notification Center. A second
   * attempt at an alert that did get through the first time can still make
   * the phone alert again.
   */
  collapseId: string;
  /** When the alert stops being useful. APNs does not deliver it after. */
  expiresAt: Date;
  /** The JSON body, with the aps dictionary. */
  payload: object;
  /**
   * True when hearing the alert twice is better than missing it. A send
   * that may or may not have reached APNs is then tried again at once.
   */
  atLeastOnce?: boolean;
}

/** What became of a send. "ok" means APNs accepted it, not that it arrived. */
export type PushResult =
  | { ok: true; apnsId?: string }
  | {
      ok: false;
      /**
       * invalid_token: the device token is no good and must be forgotten.
       * retryable: worth trying again later. config: something on this
       * server is wrong, and trying again will not help.
       */
      kind: 'invalid_token' | 'retryable' | 'config';
      /** A short code, such as APNs's own "BadDeviceToken". */
      reason: string;
      status?: number;
      /**
       * True when the request was sent in full and no answer came back, so
       * APNs may have accepted the alert all the same. Never set when APNs
       * said outright that it did not process the request.
       */
      unconfirmed?: boolean;
    };

/** Something that can send alerts. */
export interface PushSender {
  /** Whether the server has what it needs to send alerts at all. */
  readonly configured: boolean;
  send(message: PushMessage): Promise<PushResult>;
  close?(): Promise<void>;
}

/** What is used when the server has no APNs credentials: sends nothing. */
export class NoPushSender implements PushSender {
  readonly configured = false;

  async send(): Promise<PushResult> {
    return { ok: false, kind: 'config', reason: 'push_not_configured' };
  }
}

/** The APNs credentials cannot be used. Never says what they are. */
export class PushConfigError extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'PushConfigError';
  }
}

/** The app's bundle id, which is the APNs topic. */
export const DEFAULT_BUNDLE_ID = 'com.waititout.uxprototype';

/** Where APNs listens, per environment. */
export const APNS_AUTHORITIES: Record<PushEnvironment, string> = {
  sandbox: 'https://api.sandbox.push.apple.com:443',
  production: 'https://api.push.apple.com:443',
};

/** APNs refuses a body larger than this. */
export const MAX_PAYLOAD_BYTES = 4096;

/** How long a send waits for APNs to answer. */
export const REQUEST_TIMEOUT_MS = 8000;

/**
 * A provider token is reused for this long. APNs rejects one older than an
 * hour, and rejects a connection that changes tokens more than once in 20
 * minutes.
 */
const TOKEN_LIFETIME_MS = 50 * MINUTE_MS;
const MIN_TOKEN_AGE_MS = 20 * MINUTE_MS;

/**
 * A connection nothing was sent on for this long is replaced before use:
 * networks drop idle connections without saying so, and the first alert in
 * an hour should not be the one to find out.
 */
const IDLE_RECONNECT_MS = 10 * MINUTE_MS;

const HEX = /^[0-9a-fA-F]+$/;
// APNs's reasons are short words run together, such as "BadDeviceToken".
// Anything else, a device token echoed back least of all, is not repeated.
const REASON = /^[A-Za-z]{1,30}$/;

/** What an ApnsSender is built from. */
export interface ApnsOptions {
  /** The 10-character id of the signing key. */
  keyId: string;
  /** The 10-character id of the developer team. */
  teamId: string;
  /** The app's bundle id. */
  bundleId: string;
  /** The .p8 signing key, as PEM text. */
  privateKeyPem: string;
  /** Opens the HTTP/2 connection. Overridable so tests can use a local one. */
  connect?: (authority: string) => ClientHttp2Session;
  /** The clock, in epoch milliseconds. Overridable for tests. */
  now?: () => number;
  requestTimeoutMs?: number;
}

/** What one exchange with APNs came to: an answer, or none. */
type Attempt =
  | { status: number; apnsId?: string; body: string }
  | {
      failure: 'timeout' | 'connection_failed';
      /**
       * True when the whole request had been handed to the connection and
       * APNs did not say it left it unprocessed: it may have taken it.
       */
      written: boolean;
    };

const base64url = (value: object): string =>
  Buffer.from(JSON.stringify(value)).toString('base64url');

const reasonOf = (attempt: { status: number; body: string }): string => {
  try {
    const { reason } = JSON.parse(attempt.body) as { reason?: unknown };
    if (typeof reason === 'string' && REASON.test(reason)) {
      return reason;
    }
  } catch {
    // Not JSON: fall through to the status.
  }
  return `http_${attempt.status}`;
};

/**
 * Sends alerts to APNs with token-based authentication: a short ES256 JWT
 * signed with the team's key, over one long-lived HTTP/2 connection per APNs
 * host.
 */
export class ApnsSender implements PushSender {
  readonly configured = true;

  private readonly keyId: string;
  private readonly teamId: string;
  private readonly bundleId: string;
  private readonly key: KeyObject;
  private readonly connect: (authority: string) => ClientHttp2Session;
  private readonly now: () => number;
  private readonly requestTimeoutMs: number;

  private token?: { value: string; issuedAt: number };
  private readonly sessions = new Map<
    string,
    { session: ClientHttp2Session; lastUsedAt: number }
  >();

  constructor({
    keyId,
    teamId,
    bundleId,
    privateKeyPem,
    connect = authority => connectHttp2(authority),
    now = Date.now,
    requestTimeoutMs = REQUEST_TIMEOUT_MS,
  }: ApnsOptions) {
    this.keyId = keyId;
    this.teamId = teamId;
    this.bundleId = bundleId;
    try {
      this.key = createPrivateKey(privateKeyPem);
    } catch {
      // Node's own error is dropped: this one is safe to print.
      throw new PushConfigError('The APNs signing key could not be read');
    }
    if (this.key.asymmetricKeyType !== 'ec') {
      throw new PushConfigError('The APNs signing key is not an EC key');
    }
    this.connect = connect;
    this.now = now;
    this.requestTimeoutMs = requestTimeoutMs;
  }

  /**
   * Sends one alert and says what APNs made of it.
   *
   * - 200: accepted.
   * - 400 BadDeviceToken or DeviceTokenNotForTopic, and 410: the token is
   *   no good.
   * - 429, 5xx, a timeout or a dropped connection: worth another try.
   * - 403 ExpiredProviderToken: the JWT is renewed and the alert sent once
   *   more, if the JWT was old enough to have expired. If it was not, this
   *   server's clock is wrong ('clock_skew').
   * - Anything else is this server's mistake ('config').
   */
  async send(message: PushMessage): Promise<PushResult> {
    if (!HEX.test(message.deviceToken)) {
      return {
        ok: false,
        kind: 'invalid_token',
        reason: 'BadDeviceToken',
        status: 400,
      };
    }
    const body = JSON.stringify(message.payload);
    if (Buffer.byteLength(body) > MAX_PAYLOAD_BYTES) {
      return { ok: false, kind: 'config', reason: 'PayloadTooLarge' };
    }
    const first = await this.exchange(message, body);
    if (
      'failure' in first ||
      first.status !== 403 ||
      reasonOf(first) !== 'ExpiredProviderToken'
    ) {
      return this.resultOf(first);
    }
    const age = this.token ? this.now() - this.token.issuedAt : Infinity;
    if (age < MIN_TOKEN_AGE_MS) {
      // A token this new cannot have expired, and APNs refuses a second
      // new one so soon: it is the clocks that disagree.
      return { ok: false, kind: 'config', reason: 'clock_skew', status: 403 };
    }
    this.token = undefined;
    return this.resultOf(await this.exchange(message, body));
  }

  /** Closes every connection. The sender can still be used afterwards. */
  async close(): Promise<void> {
    for (const [authority, { session }] of [...this.sessions]) {
      this.discard(authority, session);
    }
  }

  private resultOf(attempt: Attempt): PushResult {
    if ('failure' in attempt) {
      return {
        ok: false,
        kind: 'retryable',
        reason: attempt.failure,
        ...(attempt.written ? { unconfirmed: true } : {}),
      };
    }
    const { status } = attempt;
    if (status === 200) {
      return { ok: true, apnsId: attempt.apnsId };
    }
    const reason = reasonOf(attempt);
    const badToken =
      status === 410 ||
      (status === 400 &&
        (reason === 'BadDeviceToken' || reason === 'DeviceTokenNotForTopic'));
    if (badToken) {
      return { ok: false, kind: 'invalid_token', reason, status };
    }
    if (status === 429 || status >= 500) {
      return { ok: false, kind: 'retryable', reason, status };
    }
    return { ok: false, kind: 'config', reason, status };
  }

  /**
   * One request to APNs, and a second on a new connection when the first
   * got no answer at all and a second can do no harm: the request never
   * left in full, or APNs said it did not process it, or the alert is one
   * worth hearing twice. A request that left in full and went unanswered is
   * otherwise reported as unconfirmed, for the caller to decide.
   */
  private async exchange(message: PushMessage, body: string): Promise<Attempt> {
    const authority = APNS_AUTHORITIES[message.environment];
    const headers: OutgoingHttpHeaders = {
      ':method': 'POST',
      ':path': `/3/device/${message.deviceToken}`,
      authorization: `bearer ${this.providerToken()}`,
      'apns-topic': this.bundleId,
      'apns-push-type': 'alert',
      'apns-priority': '10',
      'apns-id': message.id,
      'apns-collapse-id': message.collapseId,
      'apns-expiration': String(Math.floor(message.expiresAt.getTime() / 1000)),
      'content-type': 'application/json',
      'content-length': String(Buffer.byteLength(body)),
    };
    const first = await this.attempt(authority, headers, body);
    if (!('failure' in first) || (first.written && !message.atLeastOnce)) {
      return first;
    }
    const second = await this.attempt(authority, headers, body);
    return 'failure' in second
      ? { failure: second.failure, written: first.written || second.written }
      : second;
  }

  /**
   * Sends the request on the host's connection and waits for the answer.
   * Never rejects. A connection that failed or went quiet is destroyed
   * before this returns, so the next alert starts on a new one.
   *
   * HTTP/2 has two ways of saying "this request was not processed, and is
   * safe to send again": resetting the stream with REFUSED_STREAM, and
   * closing the connection with a GOAWAY that names an earlier stream as
   * the last one it took. Either is reported as a request that never left,
   * however much of it had been written.
   */
  private attempt(
    authority: string,
    headers: OutgoingHttpHeaders,
    body: string,
  ): Promise<Attempt> {
    return new Promise(resolve => {
      let session: ClientHttp2Session;
      let stream: ClientHttp2Stream;
      try {
        session = this.sessionFor(authority);
        stream = session.request(headers);
      } catch {
        this.sessions.delete(authority);
        resolve({ failure: 'connection_failed', written: false });
        return;
      }
      let status: number | undefined;
      let apnsId: string | undefined;
      let written = false;
      let passedOver = false;
      let settled = false;
      const chunks: Buffer[] = [];

      const settle = (failure?: 'timeout' | 'connection_failed'): void => {
        if (settled) {
          return;
        }
        settled = true;
        clearTimeout(timer);
        session.off('goaway', onGoaway);
        const unprocessed =
          passedOver ||
          stream.rstCode === http2Constants.NGHTTP2_REFUSED_STREAM;
        if (failure) {
          this.discard(authority, session);
        }
        resolve(
          status === undefined
            ? {
                failure: failure ?? 'connection_failed',
                written: written && !unprocessed,
              }
            : { status, apnsId, body: Buffer.concat(chunks).toString('utf8') },
        );
      };
      // Destroying the connection, as a failure does, ends the stream too.
      const timer = setTimeout(() => settle('timeout'), this.requestTimeoutMs);
      // APNs is closing the connection, and names the last request it took.
      // One after that will get no answer here, so there is none to wait for.
      const onGoaway = (_code: number, lastStreamId: number): void => {
        if (stream.id === undefined || lastStreamId < stream.id) {
          passedOver = true;
          settle('connection_failed');
        }
      };
      session.on('goaway', onGoaway);

      stream.on('response', responseHeaders => {
        status = Number(responseHeaders[':status']);
        const id = responseHeaders['apns-id'];
        apnsId = typeof id === 'string' ? id : undefined;
      });
      stream.on('data', (chunk: Buffer) => chunks.push(chunk));
      stream.on('finish', () => {
        written = true;
      });
      stream.on('end', () => {
        if (status !== undefined) {
          settle();
        }
      });
      stream.on('error', () => settle('connection_failed'));
      stream.on('close', () =>
        settle(status === undefined ? 'connection_failed' : undefined),
      );
      stream.end(body);
    });
  }

  /** The host's connection: the one in use, or a new one if it cannot be. */
  private sessionFor(authority: string): ClientHttp2Session {
    const now = this.now();
    const held = this.sessions.get(authority);
    if (held) {
      const usable = !held.session.closed && !held.session.destroyed;
      if (usable && now - held.lastUsedAt <= IDLE_RECONNECT_MS) {
        held.lastUsedAt = now;
        return held.session;
      }
      this.discard(authority, held.session);
    }
    const session = this.connect(authority);
    const forget = (): void => {
      if (this.sessions.get(authority)?.session === session) {
        this.sessions.delete(authority);
      }
    };
    // Without a listener an 'error' here would stop the server.
    session.on('error', forget);
    session.on('close', forget);
    // APNs is closing the connection: finish what is under way on it, and
    // start the next alert on a new one.
    session.on('goaway', forget);
    this.sessions.set(authority, { session, lastUsedAt: now });
    return session;
  }

  private discard(authority: string, session: ClientHttp2Session): void {
    if (this.sessions.get(authority)?.session === session) {
      this.sessions.delete(authority);
    }
    if (!session.destroyed) {
      session.destroy();
    }
  }

  /** The JWT that says who is sending, reused until it is 50 minutes old. */
  private providerToken(): string {
    const now = this.now();
    if (this.token && now - this.token.issuedAt < TOKEN_LIFETIME_MS) {
      return this.token.value;
    }
    const input = [
      base64url({ alg: 'ES256', kid: this.keyId }),
      base64url({ iss: this.teamId, iat: Math.floor(now / 1000) }),
    ].join('.');
    // ES256 as JWTs carry it: the two halves of the signature side by side.
    const signature = sign('sha256', Buffer.from(input), {
      key: this.key,
      dsaEncoding: 'ieee-p1363',
    }).toString('base64url');
    this.token = { value: `${input}.${signature}`, issuedAt: now };
    return this.token.value;
  }
}

/** Where warnings go unless the caller says otherwise: the server's log. */
const defaultWarn = (message: string): void => console.warn(message);

/**
 * The push sender the environment describes: APNS_KEY_ID, APNS_TEAM_ID,
 * APNS_BUNDLE_ID (optional) and the signing key, either as PEM text in
 * APNS_PRIVATE_KEY (a literal "\n" stands for a line break, for hosts that
 * only take one line) or as a file named by APNS_PRIVATE_KEY_FILE. With any
 * of them missing or unusable, alerts are not sent at all, and warn is told
 * which variable to look at, never what was in it.
 */
export function pushSenderFromEnv(
  env: Record<string, string | undefined> = process.env,
  warn: (message: string) => void = defaultWarn,
  /** The connection, clock and timeout, for tests. */
  overrides: Pick<ApnsOptions, 'connect' | 'now' | 'requestTimeoutMs'> = {},
): PushSender {
  const keyId = env.APNS_KEY_ID?.trim();
  const teamId = env.APNS_TEAM_ID?.trim();
  const bundleId = env.APNS_BUNDLE_ID?.trim() || DEFAULT_BUNDLE_ID;
  let privateKeyPem = env.APNS_PRIVATE_KEY?.trim()
    ? env.APNS_PRIVATE_KEY.replace(/\\n/g, '\n')
    : undefined;
  const keyFile = env.APNS_PRIVATE_KEY_FILE?.trim();
  if (!privateKeyPem && keyFile) {
    try {
      privateKeyPem = readFileSync(keyFile, 'utf8');
    } catch {
      warn('APNS_PRIVATE_KEY_FILE could not be read; alerts will not be sent.');
      return new NoPushSender();
    }
  }
  if (!keyId || !teamId || !privateKeyPem) {
    if (keyId || teamId || privateKeyPem) {
      warn(
        'APNs is only partly set up (APNS_KEY_ID, APNS_TEAM_ID and a private key are all needed); alerts will not be sent.',
      );
    }
    return new NoPushSender();
  }
  try {
    return new ApnsSender({
      ...overrides,
      keyId,
      teamId,
      bundleId,
      privateKeyPem,
    });
  } catch {
    warn('The APNs private key is not a usable key; alerts will not be sent.');
    return new NoPushSender();
  }
}
