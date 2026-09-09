import { createHash } from "node:crypto";

import type { Template } from "./types";

/**
 * Natural key construction (v2 section 7.1, ADR-08).
 *
 * Two strategies, selected per row:
 *
 *   A. external id present (preferred): identity is the source's stable id, so
 *      a source correcting the timestamp becomes an update rather than a new
 *      record.
 *   B. no external id: identity is the timestamp, truncated to the granularity
 *      the metric is recorded at.
 *
 * The value never participates in either. Value-based identity turns every
 * source correction into a phantom duplicate.
 */

export type NaturalKeyParts = {
  userId: string;
  sourceKey: string;
  template: Template;
  /** The kind of row inside the template: 'workout', 'set', a metric key. */
  entityKey: string;
  /** Part of identity: a laterality, a set ordinal, a sleep stage. */
  qualifier: string;
  /** Strategy A input when present, otherwise the truncated timestamp. */
  identity: string;
};

export function naturalKey(parts: NaturalKeyParts): string {
  const material = [
    parts.userId,
    parts.sourceKey,
    parts.template,
    parts.entityKey,
    parts.qualifier,
    parts.identity,
  ].join("|");
  return createHash("sha256").update(material, "utf8").digest("hex");
}

/**
 * Truncates an instant to the granularity identity is recorded at.
 * A daily metric truncated to the second would create a new record every time a
 * scale reported a slightly different sync time (v2 section 7.1).
 */
export function truncateForKey(
  isoUtc: string,
  granularity: "second" | "minute" | "day",
): string {
  const date = new Date(isoUtc);
  if (Number.isNaN(date.getTime())) {
    throw new Error(`truncateForKey: "${isoUtc}" is not a valid instant`);
  }
  const iso = date.toISOString();
  if (granularity === "day") return iso.slice(0, 10);
  if (granularity === "minute") return `${iso.slice(0, 16)}Z`;
  return `${iso.slice(0, 19)}Z`;
}

/**
 * Strength identity, derived from the generic construction above.
 *
 * A workout is identified by its external id when the source emits one, and
 * otherwise by its start instant truncated to the second.
 *
 * A set is identified by its workout, the exercise's position in that workout,
 * the resolved exercise key and the set ordinal. Position participates because
 * v2 section 2.3 already gives strength_exercises its identity by
 * (workout_id, order_index); a source that reorders exercises within a workout
 * therefore changes set identity, which is the same instability v2 section 6.2
 * flags for derived set numbers.
 */
export function workoutNaturalKey(args: {
  userId: string;
  sourceKey: string;
  externalId: string | null;
  startUtc: string;
}): string {
  return naturalKey({
    userId: args.userId,
    sourceKey: args.sourceKey,
    template: "strength",
    entityKey: "workout",
    qualifier: "",
    identity: args.externalId ?? truncateForKey(args.startUtc, "second"),
  });
}

export function setNaturalKey(args: {
  userId: string;
  sourceKey: string;
  workoutIdentity: string;
  exerciseOrderIndex: number;
  exerciseKey: string;
  setNumber: number;
}): string {
  return naturalKey({
    userId: args.userId,
    sourceKey: args.sourceKey,
    template: "strength",
    entityKey: "set",
    qualifier: `${args.exerciseOrderIndex}|${args.exerciseKey}|${args.setNumber}`,
    identity: args.workoutIdentity,
  });
}

/**
 * Scalar metric identity.
 *
 * The metric key is the entity, a laterality or site is the qualifier, and the
 * instant truncated to the recording granularity is the identity. The value
 * never participates, so a correction to a reading is an update to the same
 * record rather than a phantom second reading.
 */
export function metricNaturalKey(args: {
  userId: string;
  sourceKey: string;
  metricKey: string;
  qualifier: string | null;
  timestampUtc: string;
  granularity: "second" | "minute" | "day";
}): string {
  return naturalKey({
    userId: args.userId,
    sourceKey: args.sourceKey,
    template: "metrics",
    entityKey: args.metricKey,
    qualifier: args.qualifier ?? "",
    identity: truncateForKey(args.timestampUtc, args.granularity),
  });
}

/** sha256 of a canonicalised payload, the intra-file duplicate guard. */
export function rowHash(payload: Record<string, unknown>): string {
  const canonical = JSON.stringify(payload, Object.keys(payload).sort());
  return createHash("sha256").update(canonical, "utf8").digest("hex");
}
