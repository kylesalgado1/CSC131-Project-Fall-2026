// Expo replaces EXPO_PUBLIC_* with their values when it bundles the app. This
// declares just that, instead of pulling Node's types into the app.
declare const process: {
  env: { EXPO_PUBLIC_API_URL?: string };
};
