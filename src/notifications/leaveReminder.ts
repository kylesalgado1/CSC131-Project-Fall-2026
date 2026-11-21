import { Platform } from 'react-native';

const CHANNEL = 'leave-reminder';

/** Why a reminder could not be set, in words a person can act on. */
export class ReminderError extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'ReminderError';
  }
}

/**
 * Loaded on first use, not at startup: importing expo-notifications in
 * Expo Go on Android prints a warning about push notifications, which this
 * app does not use.
 */
const notifications = () => import('expo-notifications');

let ready = false;

/** Show reminders even while the app is open, and set up Android's channel. */
async function prepare(): Promise<void> {
  if (ready) {
    return;
  }
  const Notifications = await notifications();
  Notifications.setNotificationHandler({
    handleNotification: async () => ({
      shouldShowBanner: true,
      shouldShowList: true,
      shouldPlaySound: true,
      shouldSetBadge: false,
    }),
  });
  if (Platform.OS === 'android') {
    await Notifications.setNotificationChannelAsync(CHANNEL, {
      name: 'Time to leave',
      importance: Notifications.AndroidImportance.HIGH,
    });
  }
  ready = true;
}

/**
 * Schedules a local notification, asking for permission the first time.
 * Returns an id to cancel it with. Nothing leaves the phone.
 */
export async function scheduleLeaveReminder(
  at: Date,
  body: string,
): Promise<string> {
  await prepare();
  const Notifications = await notifications();
  let permission = await Notifications.getPermissionsAsync();
  if (!permission.granted && permission.canAskAgain) {
    permission = await Notifications.requestPermissionsAsync();
  }
  if (!permission.granted) {
    throw new ReminderError(
      'Notifications are turned off for Wait It Out. Turn them on in Settings to get a reminder.',
    );
  }
  return Notifications.scheduleNotificationAsync({
    content: { title: 'Time to hit the road', body },
    trigger: {
      type: Notifications.SchedulableTriggerInputTypes.DATE,
      date: at,
      channelId: CHANNEL,
    },
  });
}

export async function cancelLeaveReminder(id: string): Promise<void> {
  const Notifications = await notifications();
  await Notifications.cancelScheduledNotificationAsync(id);
}
