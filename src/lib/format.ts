export const plural = (n: number, unit: string): string =>
  `${n} ${unit}${n === 1 ? '' : 's'}`;

/** "45 min", "1 hr", "1 hr 15 min". */
export function formatDuration(minutes: number): string {
  const whole = Math.round(minutes);
  if (whole < 60) {
    return `${whole} min`;
  }
  const hours = Math.floor(whole / 60);
  const rest = whole % 60;
  return rest === 0 ? `${hours} hr` : `${hours} hr ${rest} min`;
}

/** A time of day on the device's clock, such as "7:05 AM". */
export function formatTime(
  iso: string | Date,
  options: { locale?: string; timeZone?: string } = {},
): string {
  return new Date(iso).toLocaleTimeString(options.locale ?? [], {
    hour: 'numeric',
    minute: '2-digit',
    timeZone: options.timeZone,
  });
}
