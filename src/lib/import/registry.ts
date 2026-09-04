import type { SupabaseClient } from "@supabase/supabase-js";

import type { RegistrySnapshot } from "./types";

/**
 * Loads the registry snapshot normalization is handed.
 *
 * Read once per batch and passed in, which is what keeps normalize() free of
 * database reads (I-3) and unit-testable against fixtures. Works with either a
 * user-scoped client or the worker's elevated one; a user-scoped client sees
 * system rows plus its own, which is exactly the resolution scope.
 */
export async function loadRegistrySnapshotFor(
  db: SupabaseClient,
  userId: string,
): Promise<RegistrySnapshot> {
  const scope = `user_id.is.null,user_id.eq.${userId}`;
  const [definitions, aliases, units, conversions] = await Promise.all([
    db.from("exercise_definitions").select("id, key").or(scope),
    db.from("exercise_aliases").select("alias_normalized, exercise_definition_id").or(scope),
    db.from("units").select("id, key, dimension").or(scope),
    db.from("unit_conversions").select("from_unit_id, to_unit_id, factor, offset").or(scope),
  ]);

  for (const result of [definitions, aliases, units, conversions]) {
    if (result.error) throw new Error(`registry snapshot: ${result.error.message}`);
  }

  const unitById = new Map<string, { id: string; key: string; dimension: string }>();
  const unitByKey = new Map<string, { id: string; key: string; dimension: string }>();
  for (const unit of units.data ?? []) {
    const entry = {
      id: unit.id as string,
      key: unit.key as string,
      dimension: unit.dimension as string,
    };
    unitById.set(entry.id, entry);
    unitByKey.set(entry.key, entry);
  }

  const unitConversions = new Map<string, { factor: string; offset: string }>();
  for (const row of conversions.data ?? []) {
    const from = unitById.get(row.from_unit_id as string);
    const to = unitById.get(row.to_unit_id as string);
    if (from && to) {
      unitConversions.set(`${from.key}->${to.key}`, {
        factor: String(row.factor),
        offset: String(row.offset),
      });
    }
  }

  return {
    exerciseDefinitions: new Map(
      (definitions.data ?? []).map((d) => [
        d.id as string,
        { id: d.id as string, key: d.key as string },
      ]),
    ),
    exerciseAliases: new Map(
      (aliases.data ?? []).map((a) => [
        a.alias_normalized as string,
        a.exercise_definition_id as string,
      ]),
    ),
    metricAliases: new Map(),
    metricDefinitions: new Map(),
    units: unitByKey,
    unitConversions,
  };
}
