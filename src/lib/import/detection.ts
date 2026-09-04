import { headerTokens, jaccard, normalizeHeaderToken, signatureHash } from "./profiling";
import type { FileProfile, MatchConfidence, ProfileDescriptor, ProfileMatch } from "./types";

/**
 * Import profile detection (v2 section 6.3).
 *
 * Exact signature match is the fast path. Vendors add columns without warning,
 * so exact hashing alone would stop matching after a single upstream release
 * and drop the user back into full manual mapping. Token-set similarity is the
 * fallback, with confidence bands that decide how much of the wizard is
 * pre-filled and how much the user must confirm.
 *
 *   exact signature      -> HIGH    auto-apply, show a summary
 *   similarity >= 0.85   -> MEDIUM  pre-fill, require confirmation
 *   0.60 <= sim < 0.85   -> LOW     pre-fill mapped columns, highlight the rest
 *   similarity < 0.60    -> NONE    full manual mapping
 *
 * This function knows nothing about any vendor. It compares token sets.
 */

export const CONFIDENCE_THRESHOLDS = { medium: 0.85, low: 0.6 } as const;

export type DetectionCandidate = {
  profileId: string;
  name: string;
  template: ProfileDescriptor["template"];
  sourceKey: string;
  signatureHash: string;
  headerTokens: string[];
  requiredColumns: string[];
  minSimilarity: number;
};

/** A stored or built-in profile, reduced to what detection needs. */
export function toCandidate(profile: ProfileDescriptor): DetectionCandidate {
  const declared = profile.detection.signature_tokens.length
    ? profile.detection.signature_tokens
    : profile.detection.required_columns;
  const tokens = headerTokens(declared);
  return {
    profileId: profile.profile_id,
    name: profile.name,
    template: profile.template,
    sourceKey: profile.source_key,
    signatureHash: signatureHash(declared),
    headerTokens: tokens,
    requiredColumns: profile.detection.required_columns,
    minSimilarity: profile.detection.min_similarity,
  };
}

function bandFor(similarity: number, exact: boolean, minSimilarity: number): MatchConfidence {
  if (exact) return "high";
  if (similarity >= Math.max(CONFIDENCE_THRESHOLDS.medium, minSimilarity)) return "medium";
  if (similarity >= CONFIDENCE_THRESHOLDS.low) return "low";
  return "none";
}

/**
 * Scores every candidate against a profiled file, best first.
 *
 * A candidate whose required columns are absent can never be applied, whatever
 * its token similarity, so its confidence is forced to "none" and the missing
 * columns are reported.
 */
export function detectProfiles(
  file: FileProfile,
  candidates: DetectionCandidate[],
): ProfileMatch[] {
  const fileTokenSet = new Set(file.headerTokens);
  const fileHeaderTokens = new Map(
    file.headers.map((header) => [normalizeHeaderToken(header), header] as const),
  );

  const matches = candidates.map((candidate): ProfileMatch => {
    const exact = candidate.signatureHash === file.signatureHash;
    const similarity = jaccard(file.headerTokens, candidate.headerTokens);

    const missingRequiredColumns = candidate.requiredColumns.filter(
      (column) => !fileHeaderTokens.has(normalizeHeaderToken(column)),
    );

    const candidateTokenSet = new Set(candidate.headerTokens);
    const newColumns = [...fileTokenSet].filter((t) => !candidateTokenSet.has(t));
    const missingColumns = [...candidateTokenSet].filter((t) => !fileTokenSet.has(t));

    const confidence: MatchConfidence =
      missingRequiredColumns.length > 0
        ? "none"
        : bandFor(similarity, exact, candidate.minSimilarity);

    return {
      profileId: candidate.profileId,
      name: candidate.name,
      template: candidate.template,
      sourceKey: candidate.sourceKey,
      confidence,
      similarity: Number(similarity.toFixed(4)),
      missingRequiredColumns,
      newColumns,
      missingColumns,
    };
  });

  const order: Record<MatchConfidence, number> = { high: 0, medium: 1, low: 2, none: 3 };
  return matches.sort(
    (a, b) => order[a.confidence] - order[b.confidence] || b.similarity - a.similarity,
  );
}

/**
 * Whether detection settled the question on its own. When it did not, the user
 * picks a template and maps columns by hand (v2 section 6.3 case 4).
 */
export function isDecisive(matches: ProfileMatch[]): boolean {
  const best = matches[0];
  if (!best) return false;
  if (best.confidence !== "high") return false;
  const runnerUp = matches[1];
  return !runnerUp || runnerUp.confidence !== "high";
}
