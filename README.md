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
