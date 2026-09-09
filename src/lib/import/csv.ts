import Papa from "papaparse";

import type { SourceRow } from "./types";

/**
 * CSV parsing (v2 section 5.2). PapaParse in streaming mode, the same library
 * on the client for files under the threshold and in the worker above it.
 *
 * Values are kept as raw text. Type coercion belongs to normalization, where it
 * is versioned and can reject rather than guess.
 */

export const CLIENT_PARSE_BYTE_LIMIT = 20 * 1024 * 1024;

export type ParsedCsv = {
  headers: string[];
  rows: SourceRow[];
  errors: string[];
};

export function parseCsv(text: string): ParsedCsv {
  const result = Papa.parse<Record<string, string>>(text, {
    header: true,
    skipEmptyLines: "greedy",
    dynamicTyping: false,
    transformHeader: (header) => header.trim(),
  });

  const headers = result.meta.fields ?? [];
  const rows: SourceRow[] = (result.data ?? []).map((row) => {
    const normalized: SourceRow = {};
    for (const header of headers) {
      const value = row[header];
      normalized[header] = value === undefined || value === null ? "" : String(value);
    }
    return normalized;
  });

  const errors = (result.errors ?? [])
    .filter((e) => e.code !== "TooFewFields" && e.code !== "TooManyFields")
    .map((e) => `row ${e.row ?? "?"}: ${e.message}`);

  return { headers, rows, errors };
}
