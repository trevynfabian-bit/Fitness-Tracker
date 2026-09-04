import hevyStrengthV1 from "../../../profiles/hevy.strength.v1.json";

import { profileDescriptorSchema, type ProfileDescriptor } from "./types";

/**
 * Built-in profiles (v3 section 3.1).
 *
 * They ship as versioned JSON and are seeded into import_profiles with
 * user_id IS NULL. A user-created profile is an ordinary row with the identical
 * schema, so a community profile and a built-in one are indistinguishable to
 * the engine.
 *
 * This file is the only place a vendor name appears in the source tree, and it
 * appears as an import path and a data value, never as a branch. Nothing under
 * src/lib/import reads profile.source_key to decide behaviour.
 */

const RAW_PROFILES: unknown[] = [hevyStrengthV1];

export const BUILT_IN_PROFILES: ProfileDescriptor[] = RAW_PROFILES.map((raw, index) => {
  const parsed = profileDescriptorSchema.safeParse(raw);
  if (!parsed.success) {
    throw new Error(
      `built-in profile at index ${index} is invalid:\n${parsed.error.issues
        .map((i) => `  - ${i.path.join(".")}: ${i.message}`)
        .join("\n")}`,
    );
  }
  return parsed.data;
});

export function findBuiltInProfile(profileId: string): ProfileDescriptor | undefined {
  return BUILT_IN_PROFILES.find((p) => p.profile_id === profileId);
}
