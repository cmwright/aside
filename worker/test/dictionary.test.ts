import { describe, expect, it } from 'vitest';
import { applyReplacements, parseDictionary, vocabularyHints } from '../src/dictionary';
import { BadRequestError, type DictionaryEntry } from '../src/types';

const ACME: DictionaryEntry[] = [
  { term: 'acme cloud', replacement: 'AcmeCloud' },
  { term: 'cody wright', replacement: 'Cody Wright' },
];

describe('applyReplacements', () => {
  it('replaces a term with its replacement', () => {
    expect(applyReplacements('I work at acme cloud today.', ACME)).toBe(
      'I work at AcmeCloud today.',
    );
  });

  it('matches case-insensitively and writes the replacement casing exactly', () => {
    expect(applyReplacements('ACME CLOUD and Acme Cloud and acme cloud', ACME)).toBe(
      'AcmeCloud and AcmeCloud and AcmeCloud',
    );
  });

  it('tolerates hyphen and extra whitespace between the words of a term', () => {
    expect(applyReplacements('acme-cloud and acme   cloud', ACME)).toBe(
      'AcmeCloud and AcmeCloud',
    );
  });

  it('respects word boundaries and never rewrites the inside of a longer word', () => {
    const entries: DictionaryEntry[] = [{ term: 'cloud', replacement: 'AcmeCloud' }];
    expect(applyReplacements('cloudy clouding non-cloud cloud.', entries)).toBe(
      'cloudy clouding non-AcmeCloud AcmeCloud.',
    );
  });

  it('does not match a term that is only a suffix of a word', () => {
    const entries: DictionaryEntry[] = [{ term: 'ply', replacement: 'PLY' }];
    expect(applyReplacements('comply supply ply', entries)).toBe('comply supply PLY');
  });

  it('returns the text untouched for an empty dictionary', () => {
    expect(applyReplacements('nothing to do here', [])).toBe('nothing to do here');
  });

  it('returns the text untouched when no entry has a replacement', () => {
    expect(applyReplacements('Kubernetes is fine', [{ term: 'Kubernetes' }])).toBe(
      'Kubernetes is fine',
    );
  });

  it('handles empty input text', () => {
    expect(applyReplacements('', ACME)).toBe('');
  });

  it('prefers the longest matching term when terms overlap', () => {
    const entries: DictionaryEntry[] = [
      { term: 'sock', replacement: 'SOCK' },
      { term: 'sock two', replacement: 'SOC 2' },
    ];
    expect(applyReplacements('we need sock two and a sock', entries)).toBe(
      'we need SOC 2 and a SOCK',
    );
  });

  it('does not let one replacement cascade into another term', () => {
    const entries: DictionaryEntry[] = [
      { term: 'alpha', replacement: 'beta' },
      { term: 'beta', replacement: 'gamma' },
    ];
    expect(applyReplacements('alpha beta', entries)).toBe('beta gamma');
  });

  it('keeps punctuation next to a replaced term', () => {
    expect(applyReplacements('...acme cloud, right?', ACME)).toBe('...AcmeCloud, right?');
  });

  it('handles terms containing regex metacharacters', () => {
    const entries: DictionaryEntry[] = [{ term: 'c plus plus', replacement: 'C++' }];
    expect(applyReplacements('I write c plus plus code', entries)).toBe('I write C++ code');
  });
});

describe('parseDictionary', () => {
  it('returns an empty array for null, empty and whitespace input', () => {
    expect(parseDictionary(null)).toEqual([]);
    expect(parseDictionary(undefined)).toEqual([]);
    expect(parseDictionary('')).toEqual([]);
    expect(parseDictionary('   ')).toEqual([]);
    expect(parseDictionary('[]')).toEqual([]);
  });

  it('parses terms with and without replacements', () => {
    expect(
      parseDictionary('[{"term":"acme cloud","replacement":"AcmeCloud"},{"term":"Kubernetes"}]'),
    ).toEqual([{ term: 'acme cloud', replacement: 'AcmeCloud' }, { term: 'Kubernetes' }]);
  });

  it('drops blank terms and blank replacements', () => {
    expect(parseDictionary('[{"term":"  "},{"term":" soc two ","replacement":"  "}]')).toEqual([
      { term: 'soc two' },
    ]);
  });

  it('rejects malformed JSON, non-arrays and bad entries', () => {
    expect(() => parseDictionary('not json')).toThrow(BadRequestError);
    expect(() => parseDictionary('{"term":"x"}')).toThrow(BadRequestError);
    expect(() => parseDictionary('[42]')).toThrow(BadRequestError);
    expect(() => parseDictionary('[{"replacement":"x"}]')).toThrow(BadRequestError);
    expect(() => parseDictionary('[{"term":"x","replacement":5}]')).toThrow(BadRequestError);
  });
});

describe('vocabularyHints', () => {
  it('lists replacements first, then terms, case-insensitively deduped', () => {
    expect(vocabularyHints(ACME)).toEqual([
      'AcmeCloud',
      'acme cloud',
      'Cody Wright',
    ]);
  });

  it('is empty for an empty dictionary', () => {
    expect(vocabularyHints([])).toEqual([]);
  });

  it('matches a multi-word term whose words the speech model joined together', () => {
    const entries = [{ term: 'acme cloud', replacement: 'AcmeCloud' }];
    expect(applyReplacements('a test of acmecloud dictation', entries)).toBe('a test of AcmeCloud dictation');
    expect(applyReplacements('a test of acme-cloud dictation', entries)).toBe('a test of AcmeCloud dictation');
    expect(applyReplacements('acmeclouding is not a word', entries)).toBe('acmeclouding is not a word');
  });
});
