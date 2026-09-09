import { buildSttPrompt } from '../prompt';
import { ProviderError, providerMessage, type DictionaryEntry } from '../types';

const GROQ_STT_URL = 'https://api.groq.com/openai/v1/audio/transcriptions';
const GROQ_STT_MODEL = 'whisper-large-v3-turbo';

/**
 * Groq speech-to-text (OpenAI-compatible Whisper endpoint). Dictionary terms go
 * in the `prompt` field, which Whisper uses as a spelling / vocabulary hint.
 */
export async function transcribeWithGroq(
  audio: Blob,
  filename: string,
  entries: DictionaryEntry[],
  apiKey: string,
  signal: AbortSignal,
): Promise<string> {
  const form = new FormData();
  form.append('file', audio, filename);
  form.append('model', GROQ_STT_MODEL);
  form.append('response_format', 'json');
  form.append('temperature', '0');
  const hint = buildSttPrompt(entries);
  if (hint) form.append('prompt', hint);

  let response: Response;
  try {
    response = await fetch(GROQ_STT_URL, {
      method: 'POST',
      headers: { Authorization: `Bearer ${apiKey}` },
      body: form,
      signal,
    });
  } catch (error) {
    throw new ProviderError('groq', 502, `could not reach Groq: ${(error as Error).message}`);
  }

  if (!response.ok) {
    throw new ProviderError('groq', response.status, await providerMessage(response, `Groq returned ${response.status}`));
  }

  let payload: unknown;
  try {
    payload = await response.json();
  } catch {
    throw new ProviderError('groq', 502, 'Groq returned a response that was not JSON');
  }
  const text = (payload as { text?: unknown } | null)?.text;
  if (typeof text !== 'string') {
    throw new ProviderError('groq', 502, 'Groq response did not contain a transcript');
  }
  return text.trim();
}
