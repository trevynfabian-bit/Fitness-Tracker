import type { TimezoneSpec } from "./types";

/**
 * Timezone handling (v2 section 8).
 *
 * Every timestamped row stores three things: the instant, the offset in effect,
 * and the local date the user experienced. local_date is computed once here and
 * stored, never derived at query time: deriving it in a query would make it
 * unindexable and would recompute travel history on every page load.
 *
 * A naive local timestamp with no offset is never stored. When the file carries
 * none and the profile declares a fixed zone, the offset is computed from the
 * IANA zone at that instant, which handles daylight saving correctly for zones
 * that observe it.
 */

export type ResolvedTimestamp = {
  timestampUtc: string;
  tzOffsetMinutes: number;
  tzName: string | null;
  localDate: string;
};

const NAIVE = /^(\d{4})-(\d{2})-(\d{2})[ T](\d{2}):(\d{2})(?::(\d{2}))?$/;
const NAIVE_DATE_ONLY = /^(\d{4})-(\d{2})-(\d{2})$/;
const WITH_OFFSET = /(Z|[+-]\d{2}:?\d{2})$/;

/** Offset in minutes that `tzName` was at `instant`. Deterministic, no clock read. */
export function offsetMinutesAt(tzName: string, instant: Date): number {
  const formatter = new Intl.DateTimeFormat("en-US", {
    timeZone: tzName,
    hour12: false,
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
    hour: "2-digit",
    minute: "2-digit",
    second: "2-digit",
  });
  const parts = Object.fromEntries(
    formatter.formatToParts(instant).map((part) => [part.type, part.value]),
  );
  const asUtc = Date.UTC(
    Number(parts.year),
    Number(parts.month) - 1,
    Number(parts.day),
    Number(parts.hour === "24" ? "00" : parts.hour),
    Number(parts.minute),
    Number(parts.second),
  );
  return Math.round((asUtc - instant.getTime()) / 60000);
}

function localDateFor(timestampUtc: string, offsetMinutes: number): string {
  const shifted = new Date(new Date(timestampUtc).getTime() + offsetMinutes * 60000);
  return shifted.toISOString().slice(0, 10);
}

/**
 * Resolves a source timestamp string against the profile's timezone policy.
 * Throws on an unparseable value: a workout with an unknown instant must not
 * silently acquire one.
 */
export function resolveTimestamp(
  raw: string,
  timezone: TimezoneSpec,
  row: Record<string, string>,
): ResolvedTimestamp {
  const text = raw.trim();
  if (text === "") throw new Error("timestamp is empty");

  // 2. embedded: the string carries its own offset. Highest fidelity after a
  //    per-row zone column, so it is honoured whatever the declared mode.
  if (WITH_OFFSET.test(text)) {
    const instant = new Date(text);
    if (Number.isNaN(instant.getTime())) throw new Error(`cannot parse timestamp "${raw}"`);
    const match = text.match(WITH_OFFSET);
    const suffix = match ? match[1] : "Z";
    let offsetMinutes = 0;
    if (suffix && suffix !== "Z") {
      const normalized = suffix.replace(":", "");
      const sign = normalized.startsWith("-") ? -1 : 1;
      offsetMinutes =
        sign * (Number(normalized.slice(1, 3)) * 60 + Number(normalized.slice(3, 5)));
    }
    const timestampUtc = instant.toISOString();
    return {
      timestampUtc,
      tzOffsetMinutes: offsetMinutes,
      tzName: null,
      localDate: localDateFor(timestampUtc, offsetMinutes),
    };
  }

  const naive = text.match(NAIVE) ?? text.match(NAIVE_DATE_ONLY);
  if (!naive) throw new Error(`cannot parse timestamp "${raw}"`);

  const [, year, month, day, hour = "00", minute = "00", second = "00"] = naive;
  const asIfUtc = Date.UTC(
    Number(year),
    Number(month) - 1,
    Number(day),
    Number(hour),
    Number(minute),
    Number(second),
  );

  // 1. column: the file carries a zone per row.
  // 3. fixed: the profile declares one zone for the whole file.
  let tzName: string | null = null;
  if (timezone.mode === "column") {
    const value = (row[timezone.column] ?? "").trim();
    if (value === "") throw new Error(`timezone column "${timezone.column}" is empty`);
    tzName = value;
  } else if (timezone.mode === "fixed") {
    tzName = timezone.tz_name;
  } else if (timezone.mode === "home") {
    tzName = "UTC";
  } else {
    throw new Error("timestamp carries no offset and the profile declares mode 'embedded'");
  }

  // Resolve the offset by fixed point: the offset depends on the instant, and
  // the instant depends on the offset. One correction is enough outside the
  // ambiguous hour of a daylight saving transition.
  const firstGuess = offsetMinutesAt(tzName, new Date(asIfUtc));
  const instant = new Date(asIfUtc - firstGuess * 60000);
  const offsetMinutes = offsetMinutesAt(tzName, instant);
  const corrected = new Date(asIfUtc - offsetMinutes * 60000);

  const timestampUtc = corrected.toISOString();
  return {
    timestampUtc,
    tzOffsetMinutes: offsetMinutes,
    tzName,
    localDate: localDateFor(timestampUtc, offsetMinutes),
  };
}
