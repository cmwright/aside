/** Shared types for the Worker. Kept in one small file on purpose. */

/** Bindings from wrangler.jsonc `vars` and from secrets / `.dev.vars`. */
export interface Env {
  /** "groq" (default) or "deepgram". */
  STT_PROVIDER?: string;
  /** Groq key. Required for Groq STT and for any cleanup model. */
  GROQ_API_KEY?: string;
  /** Deepgram key. Required only when STT_PROVIDER is "deepgram". */
  DEEPGRAM_API_KEY?: string;
  /** Groq chat model used for cleanup, or "none" to disable cleanup entirely. */
  CLEANUP_MODEL?: string;
  /** When set, clients must send `Authorization: Bearer <BACKEND_TOKEN>`. */
  BACKEND_TOKEN?: string;
}

/** One user dictionary entry. `replacement` is optional. */
export interface DictionaryEntry {
  /** A word or phrase the user wants recognized as spelled. */
  term: string;
  /** What to write instead when the transcript contains `term`. */
  replacement?: string;
}

export type CleanupLevel = 'none' | 'light' | 'medium';

export interface TranscriptionResponse {
  text: string;
  raw_text: string;
  timing_ms: {
    stt: number;
    cleanup: number;
    total: number;
  };
}

/** Thrown when an upstream provider answers with a non-2xx status. */
export class ProviderError extends Error {
  readonly provider: string;
  readonly status: number;

  constructor(provider: string, status: number, message: string) {
    super(message);
    this.name = 'ProviderError';
    this.provider = provider;
    this.status = status;
  }
}

/** Thrown for bad client input; surfaces as a 400. */
export class BadRequestError extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'BadRequestError';
  }
}

/** Pull the most useful message out of a provider error body without logging audio. */
export async function providerMessage(response: Response, fallback: string): Promise<string> {
  let body = '';
  try {
    body = (await response.text()).slice(0, 2000);
  } catch {
    return fallback;
  }
  if (!body) return fallback;
  try {
    const parsed = JSON.parse(body) as Record<string, unknown>;
    const error = parsed.error;
    if (typeof error === 'string' && error) return error;
    if (error && typeof error === 'object') {
      const message = (error as Record<string, unknown>).message;
      if (typeof message === 'string' && message) return message;
    }
    const message = parsed.message;
    if (typeof message === 'string' && message) return message;
    const err_msg = parsed.err_msg;
    if (typeof err_msg === 'string' && err_msg) return err_msg;
  } catch {
    // Not JSON; fall through and use the raw text.
  }
  return body;
}
