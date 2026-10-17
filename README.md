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

1. **Start the backend** in one terminal: `cd backend && npm run serve`. It needs `backend/.env` (see Backend below). With `TOMTOM_API_KEY` set it uses live TomTom traffic and place search; without it, PeMS data only and no search.
2. **Start the app** in another terminal: `npm start`, then scan the QR code with Expo Go. Your phone and computer must be on the same Wi-Fi.

The app finds the backend at the same address Expo loaded it from, on port 3000. If that does not work (a tunnel, or a firewall), give it the address directly: `EXPO_PUBLIC_API_URL=http://YOUR-COMPUTER-IP:3000 npm start`. Your computer may ask to allow incoming connections for Node the first time.

**Choosing a trip.** The card at the top has **From** and **To**. Tap either to search for a place or address (suggestions start at 3 letters), or pick a recent or well-known place. **From** also offers **Use my current location**, the default. The app asks for location permission the first time it needs it, while the app is open, and reads your position once for each answer, so the answer follows you while the app is open. It never tracks you in the background. If the phone cannot say where it is, the screen explains why and offers Settings, a starting address, or another try. The **⇅** button swaps start and destination when both are places. Your last trip and your recent places are remembered on the phone.

**Leave by and Arrive by** sit under the trip card. Tap one and tap **Day** to pick a date from a calendar (today up to a year ahead, with arrows to change month), then scroll the hour, minute and AM/PM wheels (or tap a value). Leave by is the latest you want to be on the road: the app will not tell you to wait past it. Arrive by is the latest you need to be there: the app never suggests an arrival after it, and says how late you may be if leaving now cannot make it. A time on a chosen day means that moment (if that moment has passed, it becomes the next time the clock shows it). The advice plans up to 12 hours ahead, so a farther time is kept and the answer sharpens as it gets closer. "Any time" removes a limit.

**Room to spare and far-off deadlines.** With an Arrive by time, the answer also says when you would arrive, how much room that leaves, and the latest you can leave and still make it. When the deadline is more than 3 hours away, the forecast stretches to it (every 30 minutes on the half hour, up to 12 hours) and the answer becomes a departure time, such as "Leave at 7:00 PM": the latest time that arrives with at least 10 minutes to spare (or, with the Least driving goal, the quietest time if it saves enough). The longest-wait setting does not apply to these plans; Leave by still does.

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
- The typical drive time for each of the 13 departure slots comes from TomTom's departure-time predictions, fetched every 30 minutes and interpolated in between. A new trip costs about 10 requests (about 2.7 seconds); repeats within half an hour are instant.
- **Live delay** is how much slower than typical it is right now, fading out over an hour. **Incidents** are TomTom reports of moderate or major delays, closures, or delays of five minutes or more that lie on the route and are heading the same way as you (a crash on the other side of the freeway does not count). The direction comes from the road label, such as "I-80 W", or from the shape of the incident. An incident drops confidence to Low.
- **Holidays and campus breaks:** TomTom's history is by weekday and knows nothing of holidays, so on a US holiday or a campus break the app asks TomTom about the same time on the coming Saturday instead. That is a rough guess, so the answer is marked as an estimate, confidence reads Low, and the verdict says it is a holiday. To add campus breaks such as spring break, list them in `backend/config/campus-breaks.json` (or point `CAMPUS_BREAKS_FILE` at another file), using dates from your school's official calendar:

  ```json
  [{ "name": "Spring break", "start": "2027-03-22", "end": "2027-03-26" }]
  ```

  Both days are included. The file starts empty, and the server refuses to start if an entry is malformed.

- Everything TomTom sends is kept **in memory only, for minutes**. Do not store it in the database: TomTom's terms on storing responses are not clear for free plans, so check them before extending that.
- The free plan allows about 2,500 requests a day and rate limits bursts. The client spaces requests out and retries when TomTom says "too many requests".

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

A trip that starts at the current location sends the phone's coordinates to our backend in each verdict request, and TomTom receives them as part of the route request. The server does not log requests or coordinates and stores nothing about them. Place search sends the typed text, and a rough position to rank nearby places first, to TomTom through the backend. Location permission is asked for only while the app is open ("when in use"), and the app never reads location in the background.

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

### API

```sh
cd backend && npm run serve    # PORT defaults to 3000
```

`POST /verdict` takes a trip and returns the stay-or-go verdict plus the 13 departure slots behind it (15-minute steps over 3 hours). `GET /health` reports ok.

`GET /places?q=sac&lat=38.2&lng=-122.0` returns up to 5 places matching text being typed (at least 2 characters), closest to `lat`/`lng` first. Give both `lat` and `lng`, or neither. It uses TomTom's search, so the key stays on the server. It returns 503 `search_unavailable` when TomTom is not set up, and 502 when TomTom fails. Results are kept in memory for 10 minutes and never stored.

```sh
curl -X POST localhost:3000/verdict -H 'content-type: application/json' -d '{
  "origin": {"lat": 38.2383, "lng": -122.0402},
  "destination": {"lat": 38.5593, "lng": -121.4237},
  "arriveBy": "2026-10-21T17:00:00Z",
  "leaveBy": "2026-10-21T16:00:00Z",
  "preferences": {"goal": "balance", "minSavingsMinutes": 10}
}'
```

`arriveBy`, `leaveBy` and `preferences` are optional. `leaveBy` caps how long the answer may tell you to wait; leaving now is always allowed. `verdict.action` is `leave_now`, `wait` or `leave_later`; with a deadline the verdict also carries `deadline` (`arriveBy`, `marginMinutes` and, when it can be found, `latestDeparture`). A deadline more than 3 hours out makes the response carry more slots. `goal` is `minimize_time`, `arrive_by` or `balance` (default). `maxWaitMinutes` is optional, 15 to 180; leave it out for no limit (the default). The server's clock decides "now"; a `now` in the request is ignored. Dates in the response are ISO 8601 UTC strings.

| Status                    | Meaning                                                           |
| ------------------------- | ----------------------------------------------------------------- |
| 400                       | The request is invalid (bad coordinates, out-of-range preference) |
| 422 `no_coverage`         | No PeMS data for the route yet                                    |
| 502 `routing_unavailable` | The routing service could not plan the trip                       |
| 500 `internal`            | Unexpected failure (details are logged, not returned)             |

Route paths and traffic come from TomTom, with the public OSRM demo server as a development-only fallback, and rain from Open-Meteo. Open-Meteo's data is CC BY 4.0 and its free service is non-commercial only, so the app credits it under every live answer, with a link and a note that the data is changed. Keep that credit if you move the weather display, and look into a paid plan before any commercial launch.
