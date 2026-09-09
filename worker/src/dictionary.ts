import { BadRequestError, type DictionaryEntry } from './types';

/**
 * Parse the `dictionary` form field: a JSON string holding an array of
 * `{ term, replacement? }`. Missing / empty input yields an empty dictionary.
 * Entries with a blank `term` are dropped; anything else that is malformed is a
 * 400 so the client learns about it instead of silently losing its dictionary.
 */
export function parseDictionary(raw: string | null | undefined): DictionaryEntry[] {
  if (raw == null) return [];
  const trimmed = raw.trim();
  if (trimmed === '') return [];

  let parsed: unknown;
  try {
    parsed = JSON.parse(trimmed);
  } catch {
    throw new BadRequestError('dictionary must be a JSON array of {term, replacement?}');
  }
  if (!Array.isArray(parsed)) {
    throw new BadRequestError('dictionary must be a JSON array of {term, replacement?}');
  }

  const entries: DictionaryEntry[] = [];
  for (const item of parsed) {
    if (item == null || typeof item !== 'object' || Array.isArray(item)) {
      throw new BadRequestError('dictionary entries must be objects like {term, replacement?}');
    }
    const record = item as Record<string, unknown>;
    const term = record.term;
    if (typeof term !== 'string') {
      throw new BadRequestError('dictionary entry is missing a string "term"');
    }
    const replacement = record.replacement;
    if (replacement != null && typeof replacement !== 'string') {
      throw new BadRequestError('dictionary entry "replacement" must be a string');
    }
    const cleanTerm = term.trim();
    if (cleanTerm === '') continue;
    const cleanReplacement = typeof replacement === 'string' ? replacement.trim() : '';
    entries.push(
      cleanReplacement === '' ? { term: cleanTerm } : { term: cleanTerm, replacement: cleanReplacement },
    );
  }
  return entries;
}

/** The vocabulary hints we hand to the STT provider: terms plus replacements. */
export function vocabularyHints(entries: DictionaryEntry[]): string[] {
  const seen = new Set<string>();
  const hints: string[] = [];
  for (const entry of entries) {
    for (const candidate of [entry.replacement, entry.term]) {
      if (!candidate) continue;
      const key = candidate.toLowerCase();
      if (seen.has(key)) continue;
      seen.add(key);
      hints.push(candidate);
    }
  }
  return hints;
}

function escapeRegExp(value: string): string {
  return value.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
}

const WORDISH = /[\p{L}\p{N}]/u;

/**
 * Regex source that matches `term` case-insensitively, tolerating hyphen /
 * whitespace variation between its words ("hyper comply" also matches
 * "hyper-comply"), and only at word boundaries so "comply" never eats the
 * "comply" inside "compliance".
 */
function termPattern(term: string): string {
  const words = term.trim().split(/\s+/).map(escapeRegExp);
  // Zero or more separators: speech models often join the words of a name
  // ("hypercomply" for "hyper comply"), and the outer word boundaries still apply.
  const body = words.join('[\\s\\u00a0-]*');
  const leading = WORDISH.test(term[0] ?? '') ? '(?<![\\p{L}\\p{N}])' : '';
  const lastChar = term[term.length - 1] ?? '';
  const trailing = WORDISH.test(lastChar) ? '(?![\\p{L}\\p{N}])' : '';
  return `${leading}(?:${body})${trailing}`;
}

/**
 * Deterministic post-pass: rewrite every dictionary term that has a
 * `replacement` with that replacement, case-insensitively, in a single left to
 * right scan so replacements can never cascade into each other. Longer terms
 * win over shorter overlapping ones. Runs after the LLM (which may have missed
 * one) and also when cleanup is disabled.
 */
export function applyReplacements(text: string, entries: DictionaryEntry[]): string {
  if (!text) return text;

  const replaceable = entries
    .filter((entry): entry is Required<DictionaryEntry> => Boolean(entry.replacement))
    .slice()
    .sort((a, b) => b.term.length - a.term.length);
  if (replaceable.length === 0) return text;

  const compiled = replaceable.map((entry) => ({
    entry,
    exact: new RegExp(`^(?:${termPattern(entry.term)})$`, 'iu'),
  }));
  const combined = new RegExp(replaceable.map((entry) => termPattern(entry.term)).join('|'), 'giu');

  return text.replace(combined, (match) => {
    const hit = compiled.find((candidate) => candidate.exact.test(match));
    return hit ? hit.entry.replacement : match;
  });
}
