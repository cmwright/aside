import { afterEach, describe, expect, it, vi } from 'vitest';
import worker from '../src/index';

afterEach(() => vi.unstubAllGlobals());

describe('transcription recovery', () => {
  it('returns speech and dictionary replacements when cleanup fails', async () => {
    vi.stubGlobal('fetch', vi.fn(async (url: string) =>
      url.includes('audio/transcriptions')
        ? Response.json({ text: 'hello acme cloud' })
        : Response.json({ error: { message: 'temporary outage' } }, { status: 503 })));
    const form = new FormData();
    form.set('file', new Blob(['test audio'], { type: 'audio/wav' }), 'audio.wav');
    form.set('dictionary', JSON.stringify([{ term: 'acme cloud', replacement: 'AcmeCloud' }]));
    const response = await worker.fetch(new Request('https://test.invalid/v1/audio/transcriptions', {
      method: 'POST', body: form,
    }), { GROQ_API_KEY: 'fake-key' });
    expect(response.status).toBe(200);
    expect(await response.json()).toMatchObject({
      text: 'hello AcmeCloud', raw_text: 'hello acme cloud', warning: expect.any(String),
    });
  });

  it('returns the supplied transcript when cleanup has no key', async () => {
    const fetch = vi.fn();
    vi.stubGlobal('fetch', fetch);
    const response = await worker.fetch(new Request('https://test.invalid/v1/cleanup', {
      method: 'POST', body: JSON.stringify({ text: 'preserve this', cleanup: 'medium' }),
    }), {});
    expect(response.status).toBe(200);
    expect(await response.json()).toMatchObject({ text: 'preserve this', warning: expect.any(String) });
    expect(fetch).not.toHaveBeenCalled();
  });

  it('still reports a speech failure instead of claiming an empty success', async () => {
    vi.stubGlobal('fetch', vi.fn(async () => Response.json({ error: 'failed' }, { status: 503 })));
    const form = new FormData();
    form.set('file', new Blob(['audio']), 'audio.wav');
    const response = await worker.fetch(new Request('https://test.invalid/v1/audio/transcriptions', {
      method: 'POST', body: form,
    }), { GROQ_API_KEY: 'fake-key' });
    expect(response.status).toBe(502);
  });
});
