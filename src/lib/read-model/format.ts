/**
 * Presentation helpers for the training read model.
 *
 * Pure and dependency free, so every rule below is unit testable and so a
 * number is formatted the same way on the dashboard, in the history list and
 * on a workout page. Nothing here recomputes a metric: the database read model
 * decides what a value is, this decides how it reads.
 */

/**
 * PostgREST returns `numeric` as a JSON number, but the wire format is allowed
 * to widen to a string for values outside the IEEE754 safe range. Everything
 * that touches a numeric column goes through here so neither case leaks into
 * arithmetic as a string concatenation.
 */
export function toNumber(value: unknown): number | null {
  if (value === null || value === undefined) return null;
  const n = typeof value === "number" ? value : Number(value);
  return Number.isFinite(n) ? n : null;
}

export function toInt(value: unknown): number {
  return Math.trunc(toNumber(value) ?? 0);
}

/** A count. Always an integer, always grouped. */
export function formatCount(value: number | null | undefined): string {
  if (value === null || value === undefined) return "—";
  return new Intl.NumberFormat("en-GB").format(Math.trunc(value));
}

/**
 * Volume in kilograms. Training volume runs to hundreds of thousands quickly,
 * so past 10 t it is shown in tonnes: "412,300 kg" is unreadable at a glance
 * and the last three digits carry no meaning to the reader.
 */
export function formatVolumeKg(value: number | null | undefined): string {
  const n = toNumber(value);
  if (n === null) return "—";
  if (n >= 10_000) {
    return `${new Intl.NumberFormat("en-GB", { maximumFractionDigits: 1 }).format(n / 1000)} t`;
  }
  return `${new Intl.NumberFormat("en-GB", { maximumFractionDigits: 0 }).format(n)} kg`;
}

/** A load on a bar. Half-kilo plates are real, so one decimal is kept. */
export function formatWeightKg(value: number | null | undefined): string {
  const n = toNumber(value);
  if (n === null) return "—";
  return `${new Intl.NumberFormat("en-GB", { maximumFractionDigits: 1 }).format(n)} kg`;
}

export function formatDistanceM(value: number | null | undefined): string {
  const n = toNumber(value);
  if (n === null) return "—";
  if (n >= 1000) {
    return `${new Intl.NumberFormat("en-GB", { maximumFractionDigits: 2 }).format(n / 1000)} km`;
  }
  return `${new Intl.NumberFormat("en-GB", { maximumFractionDigits: 0 }).format(n)} m`;
}

/** Seconds as a training duration: "48m", "1h 12m", "45s". */
export function formatDuration(seconds: number | null | undefined): string {
  const n = toNumber(seconds);
  if (n === null) return "—";
  const total = Math.max(0, Math.round(n));
  if (total < 60) return `${total}s`;
  const hours = Math.floor(total / 3600);
  const minutes = Math.round((total % 3600) / 60);
  if (hours === 0) return `${minutes}m`;
  return minutes === 0 ? `${hours}h` : `${hours}h ${minutes}m`;
}

/**
 * A local_date is a plain calendar date the user experienced (v2 section 8.1).
 * It is formatted as UTC deliberately: parsing "2026-09-04" in a local zone
 * behind UTC shifts it to the third, which is exactly the class of bug the
 * stored local_date exists to prevent.
 */
export function formatLocalDate(
  date: string | null | undefined,
  style: "short" | "long" = "short",
): string {
  if (!date) return "—";
  const parsed = new Date(`${date.slice(0, 10)}T00:00:00Z`);
  if (Number.isNaN(parsed.getTime())) return "—";
  return new Intl.DateTimeFormat("en-GB", {
    timeZone: "UTC",
    day: "numeric",
    month: style === "long" ? "long" : "short",
    year: "numeric",
  }).format(parsed);
}

/** Axis ticks want "4 Sep", not "4 September 2026". */
export function formatAxisDate(date: string | null | undefined): string {
  if (!date) return "";
  const parsed = new Date(`${date.slice(0, 10)}T00:00:00Z`);
  if (Number.isNaN(parsed.getTime())) return "";
  return new Intl.DateTimeFormat("en-GB", {
    timeZone: "UTC",
    day: "numeric",
    month: "short",
  }).format(parsed);
}

export function formatDateSpan(
  from: string | null | undefined,
  to: string | null | undefined,
): string {
  if (!from && !to) return "—";
  if (from && to && from === to) return formatLocalDate(from);
  return `${formatLocalDate(from)} – ${formatLocalDate(to)}`;
}

/** Whole days between two calendar dates, inclusive of neither end. */
export function daysBetween(from: string, to: string): number {
  const a = Date.parse(`${from.slice(0, 10)}T00:00:00Z`);
  const b = Date.parse(`${to.slice(0, 10)}T00:00:00Z`);
  if (!Number.isFinite(a) || !Number.isFinite(b)) return 0;
  return Math.round((b - a) / 86_400_000);
}

export function formatRpe(value: number | null | undefined): string {
  const n = toNumber(value);
  if (n === null) return "—";
  return new Intl.NumberFormat("en-GB", { maximumFractionDigits: 1 }).format(n);
}
