/**
 * Starts the fixture server: the whole API with simulated traffic, a clock
 * that only moves when told, and alerts that are recorded instead of sent.
 * For running the app end to end without a database, TomTom or Apple.
 * Nothing in it is real, and it refuses to start in production.
 *
 *   npm run serve:fixture          # PORT defaults to 3100
 *
 * Then, for example (see fixture.ts for every route):
 *
 *   curl localhost:3100/fixture/state
 *   curl -X POST localhost:3100/fixture/traffic \
 *     -H 'content-type: application/json' -d '{"driveMinutes": 40}'
 *   curl -X POST localhost:3100/fixture/clock \
 *     -H 'content-type: application/json' \
 *     -d '{"advanceMinutes": 30, "tick": true}'
 *   curl localhost:3100/fixture/pushes
 *
 * The port is 3100 and never 3000, where a real backend would be: the app
 * must be pointed at the fixture on purpose. FIXTURE_NOW sets the starting
 * time (an ISO date and time); otherwise it is the real time, to the minute.
 */
import { buildFixture } from './fixture';

/** Where the fixture listens unless PORT says otherwise. */
const DEFAULT_PORT = 3100;

async function main() {
  const startAt = process.env.FIXTURE_NOW
    ? new Date(process.env.FIXTURE_NOW)
    : undefined;
  if (startAt && Number.isNaN(startAt.getTime())) {
    throw new Error('FIXTURE_NOW is not a date and time.');
  }
  // Refuses, with an error, when NODE_ENV is "production".
  const fixture = await buildFixture({ now: startAt });
  const port = Number(process.env.PORT ?? DEFAULT_PORT);
  await fixture.app.listen({ port, host: '0.0.0.0' });
  console.log('FIXTURE SERVER — simulated traffic, not live data');
  console.log(
    `Listening on port ${port}. The fixture clock reads ${fixture
      .now()
      .toISOString()} and only moves through POST /fixture/clock.`,
  );
  const stop = async () => {
    await fixture.close();
    process.exit(0);
  };
  process.on('SIGINT', stop);
  process.on('SIGTERM', stop);
}

main().catch(error => {
  console.error(error);
  process.exit(1);
});
