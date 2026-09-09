import { buildKeyterms } from '../prompt';
import { ProviderError, providerMessage, type DictionaryEntry } from '../types';

const DEEPGRAM_URL = 'https://api.deepgram.com/v1/listen';
const DEEPGRAM_MODEL = 'nova-3';

/**
 * Deepgram Nova-3. Audio goes up as the raw request body; dictionary terms go up
 * as repeated `keyterm=` query params (Nova-3 keyterm prompting). `mip_opt_out`
 * keeps the audio out of Deepgram's model improvement program.
 */
export async function transcribeWithDeepgram(
  audio: Blob,
  entries: DictionaryEntry[],
  apiKey: string,
  signal: AbortSignal,
): Promise<string> {
  const url = new URL(DEEPGRAM_URL);
  url.searchParams.set('model', DEEPGRAM_MODEL);
  url.searchParams.set('smart_format', 'true');
  url.searchParams.set('mip_opt_out', 'true');
  for (const keyterm of buildKeyterms(entries)) {
    url.searchParams.append('keyterm', keyterm);
  }

  let response: Response;
  try {
    response = await fetch(url.toString(), {
      method: 'POST',
      headers: {
        Authorization: `Token ${apiKey}`,
        'Content-Type': audio.type || 'audio/wav',
      },
      body: audio,
      signal,
    });
  } catch (error) {
    throw new ProviderError('deepgram', 502, `could not reach Deepgram: ${(error as Error).message}`);
  }

  if (!response.ok) {
    throw new ProviderError(
      'deepgram',
      response.status,
      await providerMessage(response, `Deepgram returned ${response.status}`),
    );
  }

  let payload: unknown;
  try {
    payload = await response.json();
  } catch {
    throw new ProviderError('deepgram', 502, 'Deepgram returned a response that was not JSON');
  }

  const transcript = (payload as DeepgramResponse | null)?.results?.channels?.[0]?.alternatives?.[0]?.transcript;
  if (typeof transcript !== 'string') {
    throw new ProviderError('deepgram', 502, 'Deepgram response did not contain a transcript');
  }
  return transcript.trim();
}

interface DeepgramResponse {
  results?: {
    channels?: Array<{
      alternatives?: Array<{ transcript?: string }>;
    }>;
  };
}
