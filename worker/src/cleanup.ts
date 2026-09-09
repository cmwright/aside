import { buildCleanupSystemPrompt, buildCleanupUserPrompt, sanitizeModelOutput } from './prompt';
import { ProviderError, providerMessage, type CleanupLevel, type DictionaryEntry } from './types';

const GROQ_CHAT_URL = 'https://api.groq.com/openai/v1/chat/completions';

export const DEFAULT_CLEANUP_MODEL = 'openai/gpt-oss-120b';

/** Resolve CLEANUP_MODEL: unset means the default model, "none" disables cleanup. */
export function resolveCleanupModel(configured: string | undefined): string | null {
  const value = (configured ?? '').trim();
  if (value === '') return DEFAULT_CLEANUP_MODEL;
  if (value.toLowerCase() === 'none') return null;
  return value;
}

/**
 * Run the cleanup pass on Groq's OpenAI-compatible chat endpoint at
 * temperature 0. Returns the cleaned text; the caller still runs the
 * deterministic dictionary post-pass afterwards.
 */
export async function cleanupTranscript(options: {
  rawText: string;
  level: Exclude<CleanupLevel, 'none'>;
  entries: DictionaryEntry[];
  model: string;
  apiKey: string;
  signal: AbortSignal;
}): Promise<string> {
  const { rawText, level, entries, model, apiKey, signal } = options;

  let response: Response;
  try {
    response = await fetch(GROQ_CHAT_URL, {
      method: 'POST',
      headers: {
        Authorization: `Bearer ${apiKey}`,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({
        model,
        temperature: 0,
        max_completion_tokens: 2048,
        // gpt-oss models reason before answering; keep that short for dictation latency.
        ...(model.startsWith('openai/gpt-oss') ? { reasoning_effort: 'low' } : {}),
        messages: [
          { role: 'system', content: buildCleanupSystemPrompt(level, entries) },
          { role: 'user', content: buildCleanupUserPrompt(rawText) },
        ],
      }),
      signal,
    });
  } catch (error) {
    throw new ProviderError('groq', 502, `could not reach Groq: ${(error as Error).message}`);
  }

  if (!response.ok) {
    throw new ProviderError(
      'groq',
      response.status,
      await providerMessage(response, `Groq cleanup returned ${response.status}`),
    );
  }

  let payload: unknown;
  try {
    payload = await response.json();
  } catch {
    throw new ProviderError('groq', 502, 'Groq cleanup returned a response that was not JSON');
  }

  const content = (payload as ChatCompletion | null)?.choices?.[0]?.message?.content;
  if (typeof content !== 'string') {
    throw new ProviderError('groq', 502, 'Groq cleanup response did not contain a message');
  }
  return sanitizeModelOutput(content);
}

interface ChatCompletion {
  choices?: Array<{ message?: { content?: string } }>;
}
