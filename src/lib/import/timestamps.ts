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

// ---------------------------------------------------------------------------
// Declared formats (v2 section 4.2).
//
// mapping_spec.timestamp.format existed in the schema from Phase 2 and nothing
// read it. The Hevy profile declared "yyyy-MM-dd HH:mm:ss" while Hevy actually
// emits "5 Sep 2026, 19:03", and because the field was inert the mismatch was
// invisible until a real export was tried: every row failed on a timestamp the
// profile claimed to describe. See docs/architecture-implementation-notes.md
// N-15.
//
// The vocabulary is a closed set, in the same spirit as the named transform
// library: a profile declares a shape from a fixed list, never a pattern the
// engine interprets freely. Anything outside a token is a literal. Tokens are
// matched longest-first so `yyyy` wins over `y` and `MMM` over `MM`; case
// separates month (`MM`) from minute (`mm`).
// ---------------------------------------------------------------------------

type DateParts = {
  year: number;
  month: number;
  day: number;
  hour: number;
  minute: number;
  second: number;
};

type FormatField = keyof DateParts | "monthName";

const FORMAT_TOKENS: readonly (readonly [string, string, FormatField])[] = [
  ["yyyy", "(\\d{4})", "year"],
  ["MMM", "([A-Za-z]{3})", "monthName"],
  ["MM", "(\\d{2})", "month"],
  ["dd", "(\\d{2})", "day"],
  ["d", "(\\d{1,2})", "day"],
  ["HH", "(\\d{2})", "hour"],
  ["mm", "(\\d{2})", "minute"],
  ["ss", "(\\d{2})", "second"],
];

const MONTH_NAMES = [
  "jan", "feb", "mar", "apr", "may", "jun",
  "jul", "aug", "sep", "oct", "nov", "dec",
];

/** Compiled formats are cached: a 5,000-row import declares one format, not 5,000. */
const COMPILED = new Map<string, { pattern: RegExp; fields: FormatField[] }>();

function compileFormat(format: string): { pattern: RegExp; fields: FormatField[] } {
  const cached = COMPILED.get(format);
  if (cached) return cached;

  let source = "^";
  const fields: FormatField[] = [];
  let i = 0;
  while (i < format.length) {
    const token = FORMAT_TOKENS.find(([literal]) => format.startsWith(literal, i));
    if (token) {
      source += token[1];
      fields.push(token[2]);
      i += token[0].length;
    } else {
      source += format[i]!.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
      i += 1;
    }
  }
  source += "$";

  const compiled = { pattern: new RegExp(source), fields };
  COMPILED.set(format, compiled);
  return compiled;
}

/**
 * Parses a value against a declared format, or returns null if it does not
 * match. Pure: no clock read, no locale dependence, no randomness (I-3).
 *
 * A value that parses into an impossible date (31 February) is rejected rather
 * than rolled over, because a silently shifted instant is worse than a refused
 * row.
 */
export function parseByFormat(text: string, format: string): DateParts | null {
  const { pattern, fields } = compileFormat(format);
  const match = text.match(pattern);
  if (!match) return null;

  const parts: DateParts = { year: 1970, month: 1, day: 1, hour: 0, minute: 0, second: 0 };
  let sawYear = false;
  let sawMonth = false;
  let sawDay = false;

  fields.forEach((field, index) => {
    const value = match[index + 1]!;
    if (field === "monthName") {
      const found = MONTH_NAMES.indexOf(value.toLowerCase());
      if (found === -1) {
        parts.month = -1;
        return;
      }
      parts.month = found + 1;
      sawMonth = true;
      return;
    }
    parts[field] = Number(value);
    if (field === "year") sawYear = true;
    if (field === "month") sawMonth = true;
    if (field === "day") sawDay = true;
  });

  if (!sawYear || !sawMonth || !sawDay) return null;
  if (parts.month < 1 || parts.month > 12) return null;
  if (parts.day < 1 || parts.day > 31) return null;
  if (parts.hour > 23 || parts.minute > 59 || parts.second > 59) return null;

  // Round-trip through UTC to reject a date that does not exist in its month.
  const probe = new Date(
    Date.UTC(parts.year, parts.month - 1, parts.day, parts.hour, parts.minute, parts.second),
  );
  if (
    probe.getUTCFullYear() !== parts.year ||
    probe.getUTCMonth() !== parts.month - 1 ||
    probe.getUTCDate() !== parts.day
  ) {
    return null;
  }

  return parts;
}

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
  format?: string,
): ResolvedTimestamp {
  const text = raw.trim();
  if (text === "") throw new Error("timestamp is empty");

  // A DECLARED FORMAT GOVERNS, and a value that does not match it is refused.
  //
  // Falling back to shape-sniffing here would restore exactly the bug this
  // parameter exists to close: a profile whose declared format is wrong would
  // keep working for as long as its data happened to look ISO, and would fail
  // only on the day a real export arrived. Refusing loudly means a wrong
  // format is found by the profile's own fixture test, not by a user.
  if (format !== undefined && format !== "") {
    const parts = parseByFormat(text, format);
    if (!parts) {
      throw new Error(
        `timestamp "${raw}" does not match the profile's declared format "${format}"`,
      );
    }
    return resolveNaiveParts(parts, timezone, row);
  }

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
  return resolveNaiveParts(
    {
      year: Number(year),
      month: Number(month),
      day: Number(day),
      hour: Number(hour),
      minute: Number(minute),
      second: Number(second),
    },
    timezone,
    row,
  );
}

/**
 * Applies the profile's timezone policy to a naive local date and time.
 *
 * Shared by both parsing paths, so a value read through a declared format and
 * the same value read through the built-in shapes resolve identically.
 */
function resolveNaiveParts(
  parts: DateParts,
  timezone: TimezoneSpec,
  row: Record<string, string>,
): ResolvedTimestamp {
  const asIfUtc = Date.UTC(
    parts.year,
    parts.month - 1,
    parts.day,
    parts.hour,
    parts.minute,
    parts.second,
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
