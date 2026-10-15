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

### How the baseline is computed

The routing service gives the trip's no-traffic time, which already includes signals, ramps and surface streets. PeMS then adds the delay: for each station on the route, how much slower traffic moves at that hour than at that station's free-flow speed (its median overnight speed). A station with no data takes the average delay per mile of the ones that have it. Without a routing time, it falls back to summing PeMS speeds, with road that has no station at an assumed 25 mph.

Checked against two real commutes (Suisun City to Sac State at 7 am, and back at 6 pm), it lands within 2 minutes. Summing PeMS speeds alone was 13 to 14 minutes too low.

If you change how profiles are built, recompute them from the stored readings without re-importing:

```sh
cd backend && npm run rebuild-profiles -- --min-observed 0
```

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

```sh
curl -X POST localhost:3000/verdict -H 'content-type: application/json' -d '{
  "origin": {"lat": 38.2383, "lng": -122.0402},
  "destination": {"lat": 38.5593, "lng": -121.4237},
  "arriveBy": "2026-10-21T17:00:00Z",
  "preferences": {"goal": "balance", "maxWaitMinutes": 90, "minSavingsMinutes": 10}
}'
```

`arriveBy` and `preferences` are optional. `goal` is `minimize_time`, `arrive_by` or `balance` (default). `maxWaitMinutes` is 15 to 180. The server's clock decides "now"; a `now` in the request is ignored. Dates in the response are ISO 8601 UTC strings.

| Status                    | Meaning                                                           |
| ------------------------- | ----------------------------------------------------------------- |
| 400                       | The request is invalid (bad coordinates, out-of-range preference) |
| 422 `no_coverage`         | No PeMS data for the route yet                                    |
| 502 `routing_unavailable` | The routing service could not plan the trip                       |
| 500 `internal`            | Unexpected failure (details are logged, not returned)             |

Route paths come from the public OSRM demo server and rain from Open-Meteo. OSRM is for development only: it is rate limited and has no uptime promise. TomTom replaces it for live traffic and routing.
