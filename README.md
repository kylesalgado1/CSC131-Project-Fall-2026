# Wait-it-Out

This is our repository for our 131 class project. We are Group 3: Aldrin Quiambao, Terence Sharabati, Kyle Salgado, Nathan Barnes.

The app is built with [React Native](https://reactnative.dev) and [Expo](https://expo.dev) (SDK 57, React Native 0.86). The backend uses PostgreSQL.

## Getting started

Requires Node 22.11 or newer.

```sh
npm install
npm start
```

`npm start` runs the Expo dev server and prints a QR code.

### Run on your phone with Expo Go

1. Install **Expo Go** from the App Store or Google Play.
2. Make sure your phone and computer are on the same Wi-Fi network.
3. Scan the QR code (Camera app on iOS, Expo Go on Android).

If your network blocks the connection (campus Wi-Fi often does), use `npx expo start --tunnel`.

Expo Go can't run everything. Remote push notifications and background location need a development build (see below).

### Try the verdict screen

The app's main screen asks the backend whether to leave now or wait, and shows the answer with both choices, the arrival times, how sure the app is, and any heads-up such as rain.

1. **Start the backend** in one terminal: `cd backend && npm run serve`. It needs `backend/.env` (see Backend below). With `TOMTOM_API_KEY` set it uses live TomTom traffic and adds TomTom to place search; without it, PeMS data only, and place search still works through Photon.
2. **Start the app** in another terminal: `npm start`, then scan the QR code with Expo Go. Your phone and computer must be on the same Wi-Fi.

The app finds the backend at the same address Expo loaded it from, on port 3000. If that does not work (a tunnel, or a firewall), give it the address directly: `EXPO_PUBLIC_API_URL=http://YOUR-COMPUTER-IP:3000 npm start`. Your computer may ask to allow incoming connections for Node the first time.

#### Using a shared, deployed backend

To test from a phone on another network, or without running the backend yourself, deploy it once and point everyone's app at it. `render.yaml` describes the service for [Render](https://render.com) (free plan).

1. Push the repo to GitHub. In Render choose **New, Blueprint** and pick the repo.
2. Enter `DATABASE_URL` (the Supabase Session pooler string, see Supabase below) and, optionally, `TOMTOM_API_KEY`. Render stores them, so they are never committed.
3. When it is live, check `https://YOUR-SERVICE.onrender.com/health`.
4. In the project root `.env`, set `EXPO_PUBLIC_API_URL=https://YOUR-SERVICE.onrender.com`, then run `npm start -- -c` (`-c` clears the cache so the new address is picked up).

The free plan sleeps after about 15 minutes idle, so the first request can take up to a minute. The API has no login, so do not share its address publicly: anyone with it can use your TomTom quota.

#### Testing on a phone that is not on your Wi-Fi

`npm run start:tunnel` serves the app through a tunnel, which needs `@expo/ngrok` (Expo offers to install it). The tunnel only carries the app, not the backend, so also set `EXPO_PUBLIC_API_URL` to a deployed backend as above.

**Choosing a trip.** The card at the top has **From** and **To**. Tap either to search for a place or address (suggestions start at 3 letters), or pick a recent or well-known place. **From** also offers **Use my current location**, the default. The app asks for location permission the first time it needs it, while the app is open, and reads your position once for each answer, so the answer follows you while the app is open. It never tracks you in the background. If the phone cannot say where it is, the screen explains why and offers Settings, a starting address, or another try. The **⇅** button swaps start and destination when both are places. Your last trip and your recent places are remembered on the phone.

**Leave by and Arrive by** sit under the trip card. Tap one and tap **Day** to pick a date from a calendar (today up to a year ahead, with arrows to change month), then scroll the hour, minute and AM/PM wheels (or tap a value). Leave by is the latest you want to be on the road: the app will not tell you to wait past it. Arrive by is the latest you need to be there: the app never suggests an arrival after it, and says how late you may be if leaving now cannot make it. A time on a chosen day means that moment (if that moment has passed, it becomes the next time the clock shows it). The advice plans up to 12 hours ahead, so a farther time is kept and the answer sharpens as it gets closer. "Any time" removes a limit.

**Room to spare and far-off deadlines.** With an Arrive by time, the answer also says when you would arrive, how much room that leaves, and the latest you can leave and still make it. When the deadline is more than 3 hours away, the forecast stretches to it (every 30 minutes on the half hour, up to 12 hours) and the answer becomes a departure time, such as "Leave at 7:00 PM": the latest time that arrives with at least 10 minutes to spare (or, with the Least driving goal, the quietest time if it saves enough). The longest-wait setting does not apply to these plans; Leave by still does. When the deadline is farther than the forecast can reach (more than about 12 hours), the answer is "No need to leave yet" until it comes within range, instead of "Leave now".

**Preferences** (what matters to you, how long you will wait, how much a wait must save) are folded away under their own heading. The screen refreshes itself every 5 minutes while open, and says when the advice changes.

Real traffic on the demo commute rarely says "wait", so under **Demo options** you can switch to **Sample: Wait**, **Sample: Leave now** or **Sample: Running late** to see every state. Samples are labeled as made-up data on screen. Trip setup and preferences overlap Epics 3 and 6, and were built here as working stand-ins.

### Run on an emulator

```sh
npm run ios      # needs Xcode on macOS
npm run android  # needs Android Studio
```

These generate the `ios/` and `android/` folders and build a development build. Those folders are gitignored. They are regenerated from `app.json` and the installed Expo packages, so don't edit them by hand. Put native settings in `app.json` instead.

## Useful commands

```sh
npm test            # Jest (jest-expo)
npm run lint        # ESLint
npx tsc --noEmit    # type-check
npx expo-doctor     # check the project's Expo setup
npx expo install <package>   # add a package at the version this SDK expects
```

Use `npx expo install` instead of `npm install` for React Native libraries. It picks the version that matches the Expo SDK.

## Backend (`backend/`)

The prediction engine and PeMS data pipeline are Node/TypeScript with PostgreSQL. They have their own `package.json`, so the mobile app does not bundle server code.

```sh
cd backend && npm install
cp .env.example .env   # then fill in DATABASE_URL (see Supabase below)
npm run migrate        # creates the tables (backend/db/migrations)
npm run import-pems -- \
  --meta d04_text_meta_<date>.txt --meta d03_text_meta_<date>.txt \
  --data d04_text_station_5min_<date>.txt --data d03_text_station_5min_<date>.txt
```

`import-pems` keeps only stations on the Suisun City to Sac State corridor, loads their readings, and rebuilds the baseline profiles. Pass `--min-observed 0` to keep readings PeMS filled in (District 3 reports most stations as 0% observed). Download the files from the PeMS Data Clearinghouse. Do not commit them.

### Where the numbers come from

**TomTom is the main source** when `TOMTOM_API_KEY` is set in `backend/.env`:

- One "now" request per trip gives the route path, the no-traffic time, the typical time for right now, and the time with traffic right now.
- The typical drive time for each of the 13 departure slots comes from TomTom's departure-time predictions, fetched every hour and interpolated in between (on the Suisun City to Sac State commute that is off by under a minute at rush hour, compared with every 30 minutes). A new trip costs about 8 requests (about 2 seconds); repeats within half an hour are instant, including when the phone's position moves a few metres, because trips are matched to about 100 m.
- **Live delay** is how much slower than typical it is right now, fading out over an hour. **Incidents** are TomTom reports of moderate or major delays, closures, or delays of five minutes or more that lie on the route and are heading the same way as you (a crash on the other side of the freeway does not count). The direction comes from the road label, such as "I-80 W", or from the shape of the incident. An incident drops confidence to Low.
- **Holidays and campus breaks:** TomTom's history is by weekday and knows nothing of holidays, so on a US holiday or a campus break the app asks TomTom about the same time on the coming Saturday instead. That is a rough guess, so the answer is marked as an estimate, confidence reads Low, and the verdict says it is a holiday. To add campus breaks such as spring break, list them in `backend/config/campus-breaks.json` (or point `CAMPUS_BREAKS_FILE` at another file), using dates from your school's official calendar:

  ```json
  [{ "name": "Spring break", "start": "2027-03-22", "end": "2027-03-26" }]
  ```

  Both days are included. The file starts empty, and the server refuses to start if an entry is malformed.

- Everything TomTom sends is kept **in memory only, for minutes**. Do not store it in the database: TomTom's terms on storing responses are not clear for free plans, so check them before extending that. There is one exception, for a trip the iOS client asked the server to monitor (see "iOS client, trips and monitoring" below): the recommendation worked out for that trip (when to leave, the predicted arrival and drive time, the action, the confidence and the sentences that go with them) is kept in the database until the trip ends, and then erased. TomTom's raw responses and route geometry are never stored. **The team should confirm this exception against TomTom's terms** before relying on it.
- The free plan's allowance is per month and per API, not per day: currently about 20,000 routing requests and 2,500 traffic-incident requests a month. It changes, so check the [TomTom pricing page](https://developer.tomtom.com/pricing). It also rate limits bursts. The client spaces requests out, retries when TomTom says "too many requests", and gives up on a request that takes longer than 15 seconds.

**PeMS and OSRM take over if TomTom fails**, and `TRAFFIC_SOURCE=pems` forces them, which is useful for comparing the two. PeMS only covers the roads imported (the Suisun City to Sac State corridor), so outside it the PeMS model understates traffic and says so with low confidence.

The PeMS model adds delay to a routing service's no-traffic time: for each station on the route, how much slower traffic moves at that hour than at that station's free-flow speed (its median overnight speed). A station with no data takes the average delay per mile of the ones that have it. Without a routing time it falls back to summing PeMS speeds, with road that has no station at an assumed 25 mph.

To compare TomTom with the PeMS model for your own trip, without putting coordinates in chat:

```sh
cd backend && npm run check-trip -- --from "LAT,LNG" --to "LAT,LNG" --times "07:00,18:00" --round-trip
```

If you change how profiles are built, recompute them from the stored readings without re-importing:

```sh
cd backend && npm run rebuild-profiles -- --min-observed 0
```

### Location and privacy

A trip that starts at the current location sends the phone's coordinates to our backend in each verdict request, and TomTom receives them as part of the route request. The server does not log requests or coordinates, and for a verdict, a route or a place search it stores nothing about them. The one thing it does store is a trip the iOS client asked it to monitor (see "iOS client, trips and monitoring" below). For an anonymous installation id (no account, name or email, only the hash of a random secret) it then keeps the trip's title, its start and destination coordinates, the destination's name, the arrival time and time zone, the recommendation worked out for it, the text of the alerts made for it, and the phone's push token. When a trip is cancelled or left, its recommendation and its alerts are erased at once. A cancelled trip that no alert was ever queued for is deleted at once too; any other row is deleted 24 hours after the trip is over (`TRIP_RETENTION_HOURS`). A trip past its arrival time is ended, and an installation with no active trip is deleted after 30 days without contact, by a retention run: hourly and a minute after start-up, on every server whether or not it runs the monitor, so on a host that sleeps when idle this happens when the server next runs. An installation is deleted at once when the app asks (`DELETE /devices/me`). Place search sends the typed text, and a rough position to rank nearby places first, to TomTom and to Photon (a search engine over OpenStreetMap data, run by komoot) through the backend. Set `PLACE_SEARCH_PHOTON=off` to keep search on TomTom only, or `PHOTON_URL` to use a Photon server you host. Location permission is asked for only while the app is open ("when in use"), and the app never reads location in the background.

### Tests and checks

```sh
npm test            # Jest: app and prediction logic
npm run test:db     # database and API tests, run with Node's test runner (database on in-memory Postgres)
npm run test:all    # both
npm run typecheck   # app and backend
```

The database tests need no Postgres install. They run the real migrations on PGlite, which is Postgres compiled to WebAssembly.

### Supabase

The shared database is a Supabase Postgres project.

1. In the Supabase dashboard, click **Connect** and copy the **Session pooler** connection string. It works over IPv4 and supports the transactions the importer uses. (The direct connection is IPv6-only on many plans.)
2. Put it in `backend/.env` as `DATABASE_URL`. `.env` is gitignored. Never commit it or paste it in chat or issues.
3. If the connection fails with a certificate error, either download Supabase's CA certificate (Database settings, SSL configuration), set `DATABASE_SSL_CA` to its path and remove `sslmode` from the URL, or as a quick fallback append `?sslmode=no-verify` to the URL (encrypted, but the server's identity is not checked).
4. `npm run migrate` creates the tables and turns on row-level security with no policies. That blocks Supabase's automatic REST API from reading or writing them, so only the backend can.

Migration `005_trip_monitoring.sql` adds the tables for devices and monitored trips (the iOS client). Until it has been run, the device and trip routes answer 503 and the rest of the API works as before. Once it has been applied to the shared database it is frozen: put later changes in `006`. While working on it, use the tests (PGlite) or a private Postgres rather than the shared database.

### API

```sh
cd backend && npm run serve    # PORT defaults to 3000
```

`POST /verdict` takes a trip and returns the stay-or-go verdict plus the 13 departure slots behind it (15-minute steps over 3 hours). The response also carries `source`, which says where the figures came from: `baseline` (`tomtom`, `pems`, `fixture` or `unknown`), `fallback` (true when the main source failed and the fallback answered) and `live` (true when live conditions were available). It is an added field, so a client that does not know it is unaffected. `GET /health` reports ok.

`POST /route` takes the same `origin` and `destination` and returns the driving path for drawing the trip on a map: `points` (at most 400, start to end), `distanceMiles`, `source` (`tomtom`, `osrm`, `fixture` or `unknown`) and `fallback`. It answers 502 `routing_unavailable` when no service can draw the path. The path comes from the cache the verdict already fills and is never stored.

`GET /places?q=sac&lat=38.2&lng=-122.0` returns up to 5 places matching text being typed (at least 2 characters), closest to `lat`/`lng` first. Give both `lat` and `lng`, or neither. Short and informal names are matched first from a built-in list of campuses, stadiums and airports ("csus", "sac state", "ucla", "sofi" and so on, in `backend/places/aliases.ts`), then results from TomTom and Photon are merged, taking turns so neither crowds out the other and dropping repeats of the same place. The key stays on the server. A source that fails is skipped; the endpoint returns 502 only when every source fails and the text is not a known name. Results are kept in memory for 10 minutes and never stored. Photon's public server asks for fair use, and its results are credited to OpenStreetMap contributors under the results in the app.

```sh
curl -X POST localhost:3000/verdict -H 'content-type: application/json' -d '{
  "origin": {"lat": 38.2383, "lng": -122.0402},
  "destination": {"lat": 38.5593, "lng": -121.4237},
  "arriveBy": "2026-10-21T17:00:00Z",
  "leaveBy": "2026-10-21T16:00:00Z",
  "preferences": {"goal": "minimize_time", "minSavingsMinutes": 10}
}'
```

`arriveBy`, `leaveBy` and `preferences` are optional. `leaveBy` caps how long the answer may tell you to wait; leaving now is always allowed. `verdict.action` is `leave_now`, `wait`, `leave_later` or `no_rush`; with a deadline the verdict also carries `deadline` (`arriveBy`, `marginMinutes` and, when it can be found, `latestDeparture`). A deadline more than 3 hours out makes the response carry more slots. A deadline more than about 12 hours out (past the farthest the forecast reaches) gets `no_rush`: no departure is recommended yet, `recommended` repeats `leaveNow`, and the reason says how far off the deadline is and when a plan will appear. `no_rush` is also given for a deadline that can be planned when the Least driving goal finds that waiting would save less than the minimum; `deadline.latestDeparture` then shows the window. It is also given when the deadline is within the forecast but traffic is steady (waiting saves less than the minimum and does not get worse) and there are at least 30 minutes before the latest departure. `goal` is `minimize_time` (default) or `arrive_by`; there is no longer a `balance` goal, and the server answers 400 to it. `maxWaitMinutes` is optional, 15 to 180; leave it out for no limit (the default). The server's clock decides "now"; a `now` in the request is ignored. Dates in the response are ISO 8601 UTC strings.

| Status                    | Meaning                                                           |
| ------------------------- | ----------------------------------------------------------------- |
| 400                       | The request is invalid (bad coordinates, out-of-range preference) |
| 422 `no_coverage`         | No PeMS data for the route yet                                    |
| 502 `routing_unavailable` | The routing service could not plan the trip                       |
| 500 `internal`            | Unexpected failure (details are logged, not returned)             |

Route paths and traffic come from TomTom, with the public OSRM demo server as a development-only fallback, and rain from Open-Meteo. Open-Meteo's data is CC BY 4.0 and its free service is non-commercial only, so the app credits it under every live answer, with a link and a note that the data is changed. Keep that credit if you move the weather display, and look into a paid plan before any commercial launch.

### iOS client, trips and monitoring

The SwiftUI client (`CSC131UX/`) can ask the server to watch its trips and send alerts while the app is closed. None of this changes `/verdict`, `/places` or `/health`, which the React Native app keeps using as before, with no login.

**How a trip is monitored.** A trip is "arrive at this place by this time". A server that runs the monitoring worker (see "Turning monitoring on" below) gives it a recommended departure as soon as the arrival time is within 11.5 hours, using the same verdict as `/verdict`. From 2 hours before that departure it checks traffic every 15 minutes. It sends one heads-up 90 minutes before the departure, an update when the departure moves by a 15-minute slot (at once when it moves earlier, after two checks agree when it moves later, at most 3 a trip), "Time to leave" at the departure, and "Running late" instead if the arrival time can no longer be met. Monitoring ends at the arrival time, or when the user taps "I've left". Alerts never promise to arrive: `sent` in the API means Apple accepted the alert, not that the phone showed it.

**Endpoints.** There are no accounts. An installation registers once and gets a bearer credential; it can only see and change its own trips.

| Endpoint                       | What it does                                                                                                                 |
| ------------------------------ | ---------------------------------------------------------------------------------------------------------------------------- |
| `POST /devices`                | Registers an installation. Returns its `deviceId` and its `token`, shown once. No credential needed; 20 an hour per address. |
| `PUT /devices/me/push`         | Stores the phone's APNs token and whether notifications are allowed.                                                         |
| `DELETE /devices/me`           | Deletes the installation, its trips and its waiting alerts.                                                                  |
| `PUT /trips`                   | Sends the complete list of trips to monitor, with a `revision`. Trips left out are cancelled. Safe to retry. 120 an hour.    |
| `GET /trips`, `GET /trips/:id` | The state of each trip: its phase, recommendation, alerts sent, and whether the monitor can be counted on.                   |
| `POST /trips/:id/departed`     | "I've left": ends that trip's monitoring.                                                                                    |
| `POST /internal/monitor/tick`  | For a scheduler, not for the app: runs one round of monitoring. Needs `MONITOR_TICK_SECRET`.                                 |

All but the first and the last need `Authorization: Bearer <token>`. Until migration `005` has been run they answer 503 `monitoring_unavailable`, and that is all that code means: the tables are not there. When the database cannot be reached they answer 503 `temporarily_unavailable` instead, which says nothing about what the server holds and is worth sending again. A value of the wrong JSON type (a `null` coordinate, say) is a 400; nothing is converted.

**Turning monitoring on.** The worker is opt-in: a server only plans trips, checks them and sends alerts when started with `MONITOR=on`, and exactly one deployment should have it. `render.yaml` declares `MONITOR` for the shared deployment and ships it `"off"`, so merging and deploying changes nothing about the running service. To turn it on there, deliberately:

1. Run migration `005` against the shared database (`cd backend && npm run migrate`).
2. Set `MONITOR_TICK_SECRET` in the Render dashboard and have a scheduler call the tick route every minute (the recipes are below), or use an always-on instance with `MONITOR_ALWAYS_ON=true`.
3. Set the `APNS_*` variables in the Render dashboard if alerts are to be sent.
4. Change the value of `MONITOR` to `"on"` in `render.yaml` and deploy. If the service is managed by the Blueprint, change it there and not only in the dashboard: a value set in `render.yaml` can replace a dashboard edit the next time the Blueprint syncs.

A server without `MONITOR=on` still takes devices and trips and stores them, but it plans nothing, checks nothing and sends nothing, and the app is told so (`monitor.enabled` is false; a trip stays in `planning` with no recommendation). The app then asks `/verdict` itself and says that the server is not running trip monitoring.

That is what one server says about itself, not about the database. The trips, the waiting alerts and the daily budget live in the database, so a server without `MONITOR=on` that shares its database with the deployment that has it (a laptop pointed at the shared `DATABASE_URL`, for example) reports `monitor.enabled` false while that deployment's worker picks its trips up, spends the shared budget on them and sends real alerts. For development use a private database or `npm run serve:fixture`.

| Variable                                                                                       | Meaning                                                                                                                                                                                |
| ---------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `MONITOR`                                                                                      | `on` runs the worker in this server. Anything else, or unset, leaves it off.                                                                                                           |
| `MONITOR_TICK_SECONDS`                                                                         | How often the worker ticks inside the server (default 60).                                                                                                                             |
| `MONITOR_TICK_SECRET`                                                                          | The secret for `POST /internal/monitor/tick`, at least 32 characters. Unset, the route answers 404.                                                                                    |
| `MONITOR_ALWAYS_ON`                                                                            | `true` only on a host that never sleeps: tells the app the monitor can be counted on without a scheduler.                                                                              |
| `MONITOR_DAILY_EVALUATION_BUDGET`                                                              | The most trip evaluations in a UTC day (default 150), to stay inside the TomTom allowance. `backend/.env.example` shows the arithmetic.                                                |
| `APNS_KEY_ID`, `APNS_TEAM_ID`, `APNS_BUNDLE_ID`, `APNS_PRIVATE_KEY` or `APNS_PRIVATE_KEY_FILE` | Apple push credentials (a paid Apple Developer membership). Without them trips are still planned and monitored, and the app is told alerts cannot be sent. Never commit the `.p8` key. |
| `TRUST_PROXY`                                                                                  | `1` behind Render's proxy, so the limit on new installations counts per client.                                                                                                        |

The lead times and limits can be changed too; `backend/.env.example` lists them all.

**Why the free Render plan alone is not a dependable worker.** The worker ticks inside the web service, and Render's free plan puts a service to sleep after about 15 minutes without an incoming request. A sleeping service checks nothing and sends nothing, so an alert can be late or missing exactly when the app is closed. The app is told (`monitor.dependable` is false) and says so. There are two ways to make it dependable:

- An always-on instance (a paid plan), with `MONITOR_ALWAYS_ON=true`.
- An outside scheduler that calls the tick route every minute, which also keeps the service awake. The route answers `202` at once and runs the tick behind the answer, because schedulers give up after a couple of seconds. Any cron service will do:

  ```sh
  curl -X POST https://YOUR-SERVICE.onrender.com/internal/monitor/tick \
    -H "Authorization: Bearer $MONITOR_TICK_SECRET"
  ```

  Or from the Supabase database itself, with the `pg_cron` and `pg_net` extensions (turn both on under Database, Extensions), in the SQL editor:

  ```sql
  select cron.schedule(
    'wait-it-out-monitor-tick',
    '* * * * *',
    $$
    select net.http_post(
      url := 'https://YOUR-SERVICE.onrender.com/internal/monitor/tick',
      headers := '{"Content-Type": "application/json", "Authorization": "Bearer YOUR-MONITOR-TICK-SECRET"}'::jsonb
    );
    $$
  );
  ```

  This recipe has not been run against our project yet. Check that both extensions are available on the project's plan. The secret sits in the job's SQL, where anyone with database access can read it. `cron.job_run_details` grows by a row a minute and is never cleaned up automatically. The first call after the service has slept is expected to time out while Render starts it.

`cd backend && npm run monitor:tick` runs one tick from the command line (with `MONITOR=on`), for a scheduler that starts a process instead of calling a URL. It starts with nothing cached, so each tick costs more TomTom requests than calling the route. The web service needs `MONITOR=on` as well: what the app is told about the monitor comes from the web service, which only says monitoring is running when it runs it itself.

**Trying it without a database, TomTom or Apple.** `cd backend && npm run serve:fixture` starts the whole API on port 3100 with simulated traffic, a clock that only moves when told, and alerts that are recorded instead of sent. Its answers are labelled as fixture data. `backend/scripts/serve-fixture.ts` lists the `/fixture` routes that move the clock, change the traffic and show what would have been sent. It is for development only and refuses to start in production.
