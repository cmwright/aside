# Aside Worker (optional backend)

A small Cloudflare Worker that takes audio or a transcript, runs speech-to-text and the
cleanup pass at the provider you configure, applies the dictionary, and returns text. It
stores nothing and logs only method, path, status and timing.

You do not need it for personal use: the Mac and iPhone apps can transcribe on-device
and call providers directly with your own keys. The Worker earns its keep when several
devices or people should share one configuration and one set of keys, or when you want a
stable URL in front of a model of your own.

## Run locally

```sh
cd worker
npm install
cp .dev.vars.example .dev.vars   # paste your GROQ_API_KEY
npx wrangler dev                 # http://localhost:8787
curl http://localhost:8787/health
./scripts/smoke.sh               # posts test/fixtures/hello.wav and prints the result
```

Point the app at it: Settings → Worker backend, URL `http://localhost:8787`, then choose
**The Worker** as the transcription and/or cleanup engine.

## Configuration

`.dev.vars` (git-ignored) locally; `wrangler secret put` when deployed.

| Variable | Default | What it does |
| --- | --- | --- |
| `STT_PROVIDER` | `groq` | `groq` (Whisper large v3 turbo) or `deepgram` (Nova-3, sent with `mip_opt_out=true`). |
| `GROQ_API_KEY` | — | Groq speech-to-text, and cleanup on either provider. |
| `DEEPGRAM_API_KEY` | — | Only when `STT_PROVIDER=deepgram`. |
| `CLEANUP_MODEL` | `openai/gpt-oss-120b` | Groq chat model for cleanup; `none` returns the raw transcript. |
| `BACKEND_TOKEN` | unset | When set, callers must send `Authorization: Bearer <token>`. **Set one before deploying.** |

## Deploy

```sh
npx wrangler login
npx wrangler deploy
npx wrangler secret put GROQ_API_KEY
npx wrangler secret put BACKEND_TOKEN     # e.g. openssl rand -base64 32
```

Then put the `workers.dev` URL and the token into the app's Worker backend settings. The
free plan covers a single user's traffic comfortably.

## HTTP contract

`POST /v1/audio/transcriptions`, `multipart/form-data`:

| Field | Value |
| --- | --- |
| `file` | `audio/wav`, 16 kHz mono 16-bit PCM, filename `audio.wav` |
| `model` | ignored; present for OpenAI-client compatibility |
| `dictionary` | JSON string: `[{"term": "...", "replacement": "..."}]` (`replacement` optional) |
| `cleanup` | `none` \| `light` \| `medium` (default `medium`) |
| `app_name` | optional; the frontmost app, reserved for per-app tone |

Response `200 application/json`:

```json
{
  "text": "The cleaned text to paste.",
  "raw_text": "the raw provider transcript",
  "timing_ms": { "stt": 412, "cleanup": 380, "total": 802 }
}
```

`POST /v1/cleanup` with a JSON body `{ "text", "dictionary"?, "cleanup"?, "app_name"? }`
runs only the cleanup pass and dictionary post-pass on a transcript the client already
has, for on-device transcription. Same response shape, `timing_ms.stt` is 0.

`GET /health` → `{ "ok": true, "stt": "groq", "cleanup": "openai/gpt-oss-120b" }`.

Errors are `{ "error": "..." }` with 400 (bad input), 401 (bad token), 502 (provider
failure, with the provider's message) or 500 (misconfiguration).

## Developing

```sh
npx vitest run     # dictionary post-pass and prompt assembly
npx tsc --noEmit
```

Source map: `src/index.ts` (router, auth, timing), `src/stt/groq.ts`, `src/stt/deepgram.ts`,
`src/cleanup.ts`, `src/dictionary.ts` (parsing and the deterministic replacement pass),
`src/prompt.ts` (all prompt text; kept in step with `mac/Sources/CleanupPrompt.swift`),
`src/types.ts`.
