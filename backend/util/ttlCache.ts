/**
 * Remembers the result of an async load for each key for a while.
 *
 * The in-flight promise is stored, so requests for the same key that arrive
 * together share one load instead of each calling the service. A failed load
 * is forgotten, so the next caller retries. The oldest entries are dropped
 * once there are more than `maxEntries`.
 */
export class TtlCache<T> {
  private readonly entries = new Map<
    string,
    { at: number; value: Promise<T> }
  >();

  constructor(
    private readonly ttlMs: number,
    private readonly now: () => number = Date.now,
    private readonly maxEntries = 1000,
  ) {}

  get(key: string, load: () => Promise<T>): Promise<T> {
    const hit = this.entries.get(key);
    if (hit && this.now() - hit.at < this.ttlMs) {
      return hit.value;
    }

    const entry = { at: this.now(), value: load() };
    this.entries.delete(key); // re-insert at the end, so it counts as newest
    this.entries.set(key, entry);
    entry.value.catch(() => {
      if (this.entries.get(key) === entry) {
        this.entries.delete(key);
      }
    });

    if (this.entries.size > this.maxEntries) {
      const oldest = this.entries.keys().next().value;
      if (oldest !== undefined) {
        this.entries.delete(oldest);
      }
    }
    return entry.value;
  }
}
