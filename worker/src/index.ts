import { cleanupTranscript, resolveCleanupModel } from './cleanup';
import { applyReplacements, parseDictionary } from './dictionary';
import { parseCleanupLevel } from './prompt';
import { transcribeWithDeepgram } from './stt/deepgram';
import { transcribeWithGroq } from './stt/groq';
import {
  BadRequestError,
  ProviderError,
  type CleanupLevel,
  type DictionaryEntry,
  type Env,
  type TranscriptionResponse,
} from './types';

/** Upper bound on an upload. A minute of 16 kHz mono 16-bit PCM is ~1.9 MB. */
const MAX_AUDIO_BYTES = 25 * 1024 * 1024;
/** Hard ceiling on one request end to end; the Mac app gives up at 30 s. */
const REQUEST_TIMEOUT_MS = 28_000;
/** Upper bound on a `/v1/cleanup` transcript. */
const MAX_TEXT_CHARS = 20_000;

type SttProvider = 'groq' | 'deepgram';

function resolveSttProvider(env: Env): SttProvider {
  return (env.STT_PROVIDER ?? '').trim().toLowerCase() === 'deepgram' ? 'deepgram' : 'groq';
}

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      'Content-Type': 'application/json; charset=utf-8',
      'Cache-Control': 'no-store',
    },
  });
}

function errorResponse(message: string, status: number): Response {
  return json({ error: message }, status);
}

/**
 * Bearer check. When BACKEND_TOKEN is unset (the local dev default) we accept
 * everything, which is what makes `wrangler dev` usable with no configuration.
 */
function authorize(request: Request, env: Env): Response | null {
  const expected = (env.BACKEND_TOKEN ?? '').trim();
  if (expected === '') return null;

  const header = request.headers.get('Authorization') ?? '';
  const match = /^Bearer\s+(.+)$/i.exec(header.trim());
  const presented = match?.[1]?.trim() ?? '';
  if (presented === '' || !timingSafeEqual(presented, expected)) {
    return errorResponse('invalid or missing bearer token', 401);
  }
  return null;
}

function timingSafeEqual(a: string, b: string): boolean {
  const encoder = new TextEncoder();
  const left = encoder.encode(a);
  const right = encoder.encode(b);
  let diff = left.length ^ right.length;
  const length = Math.max(left.length, right.length);
  for (let i = 0; i < length; i += 1) {
    diff |= (left[i] ?? 0) ^ (right[i] ?? 0);
  }
  return diff === 0;
}

async function handleTranscription(request: Request, env: Env): Promise<Response> {
  const startedAt = Date.now();

  const unauthorized = authorize(request, env);
  if (unauthorized) return unauthorized;

  const contentType = request.headers.get('Content-Type') ?? '';
  if (!contentType.toLowerCase().includes('multipart/form-data')) {
    return errorResponse('expected multipart/form-data', 400);
  }

  let form: FormData;
  try {
    form = await request.formData();
  } catch {
    return errorResponse('could not parse multipart/form-data body', 400);
  }

  const file = form.get('file');
  if (file === null || typeof file === 'string') {
    return errorResponse('missing "file" part (16 kHz mono 16-bit WAV)', 400);
  }
  const audio = file;
  if (audio.size === 0) {
    return errorResponse('"file" part is empty', 400);
  }
  if (audio.size > MAX_AUDIO_BYTES) {
    return errorResponse(`"file" part is larger than ${MAX_AUDIO_BYTES} bytes`, 400);
  }

  let entries: DictionaryEntry[];
  let level: CleanupLevel;
  try {
    entries = parseDictionary(asString(form.get('dictionary')));
    level = parseCleanupLevel(asString(form.get('cleanup')));
  } catch (error) {
    if (error instanceof BadRequestError) return errorResponse(error.message, 400);
    throw error;
  }

  const provider = resolveSttProvider(env);
  const groqKey = (env.GROQ_API_KEY ?? '').trim();
  const deepgramKey = (env.DEEPGRAM_API_KEY ?? '').trim();
  const cleanupModel = resolveCleanupModel(env.CLEANUP_MODEL);

  if (provider === 'groq' && groqKey === '') {
    return errorResponse('GROQ_API_KEY is not configured on the Worker', 500);
  }
  if (provider === 'deepgram' && deepgramKey === '') {
    return errorResponse('DEEPGRAM_API_KEY is not configured on the Worker', 500);
  }
  const wantsCleanup = level !== 'none' && cleanupModel !== null;
  if (wantsCleanup && groqKey === '') {
    return errorResponse('GROQ_API_KEY is not configured on the Worker (needed for cleanup)', 500);
  }

  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), REQUEST_TIMEOUT_MS);
  try {
    const sttStartedAt = Date.now();
    const rawText =
      provider === 'deepgram'
        ? await transcribeWithDeepgram(audio, entries, deepgramKey, controller.signal)
        : await transcribeWithGroq(
            audio,
            audio.name || 'audio.wav',
            entries,
            groqKey,
            controller.signal,
          );
    const sttMs = Date.now() - sttStartedAt;

    const { text, cleanupMs } = await cleanAndReplace({
      rawText,
      level,
      entries,
      cleanupModel: wantsCleanup ? (cleanupModel as string) : null,
      groqKey,
      signal: controller.signal,
    });

    const body: TranscriptionResponse = {
      text,
      raw_text: rawText,
      timing_ms: { stt: sttMs, cleanup: cleanupMs, total: Date.now() - startedAt },
    };
    return json(body);
  } catch (error) {
    return providerFailure(error);
  } finally {
    clearTimeout(timeout);
  }
}

/**
 * `POST /v1/cleanup`: the same cleanup pass and dictionary post-pass as the audio route,
 * for a transcript the client already produced (on-device Parakeet in the Mac app).
 * Body: `{ text, dictionary?, cleanup?, app_name? }` as JSON. Response shape matches
 * `/v1/audio/transcriptions` with `timing_ms.stt` = 0.
 */
async function handleCleanup(request: Request, env: Env): Promise<Response> {
  const startedAt = Date.now();

  const unauthorized = authorize(request, env);
  if (unauthorized) return unauthorized;

  let payload: unknown;
  try {
    payload = await request.json();
  } catch {
    return errorResponse('expected a JSON body', 400);
  }
  if (typeof payload !== 'object' || payload === null) {
    return errorResponse('expected a JSON object', 400);
  }
  const body = payload as Record<string, unknown>;
  const rawText = typeof body.text === 'string' ? body.text : '';
  if (typeof body.text !== 'string') {
    return errorResponse('missing "text" string', 400);
  }
  if (rawText.length > MAX_TEXT_CHARS) {
    return errorResponse(`"text" is longer than ${MAX_TEXT_CHARS} characters`, 400);
  }

  let entries: DictionaryEntry[];
  let level: CleanupLevel;
  try {
    const dictionaryField =
      typeof body.dictionary === 'string'
        ? body.dictionary
        : body.dictionary === undefined || body.dictionary === null
          ? null
          : JSON.stringify(body.dictionary);
    entries = parseDictionary(dictionaryField);
    level = parseCleanupLevel(typeof body.cleanup === 'string' ? body.cleanup : null);
  } catch (error) {
    if (error instanceof BadRequestError) return errorResponse(error.message, 400);
    throw error;
  }

  const groqKey = (env.GROQ_API_KEY ?? '').trim();
  const cleanupModel = resolveCleanupModel(env.CLEANUP_MODEL);
  const wantsCleanup = level !== 'none' && cleanupModel !== null;
  if (wantsCleanup && groqKey === '') {
    return errorResponse('GROQ_API_KEY is not configured on the Worker (needed for cleanup)', 500);
  }

  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), REQUEST_TIMEOUT_MS);
  try {
    const { text, cleanupMs } = await cleanAndReplace({
      rawText,
      level,
      entries,
      cleanupModel: wantsCleanup ? (cleanupModel as string) : null,
      groqKey,
      signal: controller.signal,
    });
    const response: TranscriptionResponse = {
      text,
      raw_text: rawText,
      timing_ms: { stt: 0, cleanup: cleanupMs, total: Date.now() - startedAt },
    };
    return json(response);
  } catch (error) {
    return providerFailure(error);
  } finally {
    clearTimeout(timeout);
  }
}

/** LLM cleanup (when enabled) followed by the deterministic dictionary post-pass. */
async function cleanAndReplace(options: {
  rawText: string;
  level: CleanupLevel;
  entries: DictionaryEntry[];
  cleanupModel: string | null;
  groqKey: string;
  signal: AbortSignal;
}): Promise<{ text: string; cleanupMs: number }> {
  const { rawText, level, entries, cleanupModel, groqKey, signal } = options;
  let text = rawText;
  let cleanupMs = 0;
  if (cleanupModel !== null && level !== 'none' && rawText.trim() !== '') {
    const cleanupStartedAt = Date.now();
    text = await cleanupTranscript({
      rawText,
      level,
      entries,
      model: cleanupModel,
      apiKey: groqKey,
      signal,
    });
    cleanupMs = Date.now() - cleanupStartedAt;
    if (text.trim() === '') text = rawText;
  }
  // Deterministic dictionary post-pass: runs whether or not the LLM ran.
  return { text: applyReplacements(text, entries).trim(), cleanupMs };
}

function providerFailure(error: unknown): Response {
  if (error instanceof ProviderError) {
    return errorResponse(`${error.provider}: ${error.message}`, 502);
  }
  if ((error as Error)?.name === 'AbortError') {
    return errorResponse('provider request timed out', 502);
  }
  return errorResponse(`unexpected error: ${(error as Error).message}`, 500);
}

function asString(value: File | string | null): string | null {
  return typeof value === 'string' ? value : null;
}

function handleHealth(env: Env): Response {
  const cleanupModel = resolveCleanupModel(env.CLEANUP_MODEL);
  return json({
    ok: true,
    stt: resolveSttProvider(env),
    cleanup: cleanupModel ?? 'none',
  });
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);
    const startedAt = Date.now();
    let response: Response;

    if (url.pathname === '/health' && request.method === 'GET') {
      response = handleHealth(env);
    } else if (url.pathname === '/v1/audio/transcriptions') {
      response =
        request.method === 'POST'
          ? await handleTranscription(request, env)
          : errorResponse('method not allowed', 405);
    } else if (url.pathname === '/v1/cleanup') {
      response =
        request.method === 'POST'
          ? await handleCleanup(request, env)
          : errorResponse('method not allowed', 405);
    } else {
      response = errorResponse('not found', 404);
    }

    // Request bodies and transcripts are never logged. Method, path, status, timing only.
    console.log(`${request.method} ${url.pathname} ${response.status} ${Date.now() - startedAt}ms`);
    return response;
  },
} satisfies ExportedHandler<Env>;
