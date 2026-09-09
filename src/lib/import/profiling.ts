import { createHash } from "node:crypto";

import { PROFILE_SAMPLE_SIZE, type ColumnProfile, type FileProfile, type SourceRow } from "./types";

/**
 * File profiling (v2 section 5.2).
 *
 * Produces headers, a stable signature, per-column inferred types, null ratios,
 * distinct-value samples and a sample of rows. Profiling never writes canonical
 * data and never touches the database.
 *
 * The same functions run client-side for files under the parse threshold and
 * server-side above it, so the signature a browser computes and the signature a
 * worker computes are the same string.
 */

/**
 * Header token normalisation (v2 section 6.3): lowercased, punctuation and
 * bracketed unit suffixes stripped, whitespace collapsed.
 *
 * Deliberately distinct from public.normalize_alias: alias normalisation keeps
 * a unit because "weight kg" and "weight lb" are different aliases, whereas a
 * header token drops it so that a vendor renaming "Weight (kg)" to "Weight" is
 * still recognised as the same file shape.
 */
export function normalizeHeaderToken(header: string): string {
  return header
    .toLowerCase()
    .replace(/\([^)]*\)/g, " ")
    .replace(/\[[^\]]*\]/g, " ")
    .replace(/[^a-z0-9]+/g, " ")
    .trim()
    .replace(/\s+/g, " ");
}

/** sha256 over the sorted normalised header tokens (v2 section 2.2). */
export function signatureHash(headers: string[]): string {
  const tokens = headers.map(normalizeHeaderToken).filter((t) => t !== "");
  const sorted = [...new Set(tokens)].sort();
  return createHash("sha256").update(sorted.join("|"), "utf8").digest("hex");
}

export function headerTokens(headers: string[]): string[] {
  return [...new Set(headers.map(normalizeHeaderToken).filter((t) => t !== ""))].sort();
}

/** Jaccard similarity over two token sets (v2 section 6.3). */
export function jaccard(a: string[], b: string[]): number {
  const left = new Set(a);
  const right = new Set(b);
  if (left.size === 0 && right.size === 0) return 1;
  let intersection = 0;
  for (const token of left) if (right.has(token)) intersection += 1;
  const union = left.size + right.size - intersection;
  return union === 0 ? 0 : intersection / union;
}

const ISO_DATE = /^\d{4}-\d{2}-\d{2}([ T]\d{2}:\d{2}(:\d{2})?)?/;
const NUMERIC = /^-?\d+(\.\d+)?$/;
const BOOLEAN = /^(true|false|yes|no|y|n|0|1)$/i;

function inferType(values: string[]): ColumnProfile["inferredType"] {
  const present = values.filter((v) => v.trim() !== "");
  if (present.length === 0) return "empty";
  if (present.every((v) => ISO_DATE.test(v.trim()))) return "date";
  if (present.every((v) => NUMERIC.test(v.trim()))) return "number";
  if (present.every((v) => BOOLEAN.test(v.trim()))) return "boolean";
  return "text";
}

/**
 * Builds a profile from already-parsed rows. Pure: no clock, no randomness, no
 * I/O, so a profile is reproducible from the same file.
 */
export function profileRows(headers: string[], rows: SourceRow[]): FileProfile {
  const columns: ColumnProfile[] = headers.map((name) => {
    const values = rows.map((row) => row[name] ?? "");
    const blank = values.filter((v) => v.trim() === "").length;
    const distinct = [...new Set(values.filter((v) => v.trim() !== ""))].slice(0, 10);
    return {
      name,
      inferredType: inferType(values),
      nullRatio: values.length === 0 ? 0 : blank / values.length,
      distinctSample: distinct,
    };
  });

  return {
    headers,
    headerTokens: headerTokens(headers),
    signatureHash: signatureHash(headers),
    rowCount: rows.length,
    columns,
    sampleRows: rows.slice(0, PROFILE_SAMPLE_SIZE),
  };
}

export { PROFILE_SAMPLE_SIZE };
