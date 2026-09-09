# Testing checklist (about 10 minutes)

Two terminals: one for the Worker, one for everything else. All paths are relative to
the repo root.

## 1. Put the Groq key in place (1 min)

1. Get a free key at https://console.groq.com/keys.
2. `cd worker && cp .dev.vars.example .dev.vars`
3. Open `worker/.dev.vars` and set the line `GROQ_API_KEY=""` to your key:
   `GROQ_API_KEY="gsk_..."`. Leave the other lines as they are (`BACKEND_TOKEN=""`
   keeps local calls unauthenticated). The file is git-ignored.

## 2. Start the Worker and prove it works (2 min)

Terminal 1:

```sh
cd worker
npm install
npx wrangler dev          # wait for "Ready on http://localhost:8787"
```

Terminal 2:

```sh
cd worker
./scripts/smoke.sh
```

Expected output, in order:

- `Data format: 1 ch, 16000 Hz, Int16` for `test/fixtures/hello.wav` (generated with
  `say` + `afconvert` on the first run).
- `GET /health` -> `{"ok":true,"stt":"groq","cleanup":"openai/gpt-oss-120b"}`.
- `POST /v1/audio/transcriptions` -> `HTTP 200` and a JSON body whose `text` reads
  roughly "Hello there, this is a test of HyperComply dictation, and it should come out
  clean." (`raw_text` still has "um", "you know" and "hyper comply"; `text` has the
  dictionary replacement `HyperComply` and no fillers), plus `timing_ms`.

If instead you see:

| Response | Meaning |
| --- | --- |
| `Could not reach http://localhost:8787/health` | `npx wrangler dev` is not running. |
| `HTTP 500` `GROQ_API_KEY is not configured on the Worker` | The key is not in `worker/.dev.vars`, or wrangler was started before you saved it. Restart it. |
| `HTTP 502` `groq: Invalid API Key` | The key is wrong. |
| `HTTP 502` any other `groq: ...` message | Groq's own error, for example a rate limit. |

Leave `npx wrangler dev` running.

## 3. Build and launch the app (2 min, longer on the very first build)

```sh
cd mac
./run.sh
```

The first build downloads the KeyboardShortcuts package. A microphone icon appears in
the menu bar; there is no Dock icon and no main window.

## 4. Grant the two permissions (2 min)

On first launch the app asks by itself: a system **Microphone** dialog, a system
**Accessibility** dialog, and its own **Permissions** window (also under the menu-bar
icon -> **Permissions...**). Each row shows a live status: **Granted**, **Not granted**
or **Not asked yet**, with **Request** and **Open Settings** buttons.

- **Microphone**: click Allow in the dialog. If you dismissed it, click **Open Settings**
  on the Microphone row (Privacy & Security -> Microphone) and switch Aside on.
- **Accessibility**: click **Open Settings** on the Accessibility row (Privacy &
  Security -> Accessibility). If Aside is not listed, click **+** and pick
  `mac/build/Build/Products/Debug/Aside.app`. Switch it on. The Permissions window
  flips to **Granted** within a second and the app re-arms the Right Option key by
  itself; no relaunch.

**Ad-hoc signing caveat.** Builds are not signed with an identity, so every
`./build.sh` / `./run.sh` produces a new signature and macOS quietly drops the
Accessibility trust. Symptoms: the app is still listed and switched on, but the
Permissions window says **Not granted** and Right Option does nothing. Fix: select
Aside in the Accessibility list, press **-**, then **+** and add the freshly built
app again. Expect to do this after every rebuild. The Microphone grant survives rebuilds.

## 5. What the menu-bar icon means

Aside's icon is a text cursor with two sound arcs to its right (voice arriving at the
cursor). It is a template image, so it follows the menu bar's light or dark appearance.

| Icon | State |
|---|---|
| Cursor + two thin arcs | Idle, ready |
| Cursor + thick arcs + a dot | Listening (recording) |
| Cursor + three dots | Transcribing / cleaning up |
| Cursor + exclamation mark | Last dictation failed; the menu's first line has the message |

The floating pill near the bottom of the screen carries the same states with text, and
the menu's first lines show the state, the engine in use, and a summary of the last run.

## 6. Dictate: try these four first (3 min)

In each: click to place the cursor, hold **Right Option**, say one sentence, let go. Then try the hands-free gesture: double-tap Right Option, the pill changes to "Listening — tap Right Option to stop", speak, tap once.
While held the pill says Listening; on release it says Transcribing for about a second;
then the text appears at the cursor. The Worker terminal logs one
`POST /v1/audio/transcriptions 200` line per attempt.

1. **Notes** (new note). Text is inserted through the Accessibility path; your clipboard
   is untouched. Type a word, leave the cursor right after its last letter and dictate
   again: a leading space is added automatically (it is not added after punctuation).
2. **Slack** (message box). Electron app: usually the Cmd+V fallback. The text appears, and
   whatever was on your clipboard before is put back 0.4 s later (copy something first,
   dictate, then paste elsewhere to confirm it came back). Nothing is sent to the channel
   until you press Enter.
3. **Chrome** (Gmail compose, a Google Doc, or any text box). Either path may be used
   depending on the page; the text lands at the cursor either way.
4. **Terminal** (at a shell prompt). Terminal has no settable selected-text attribute,
   so the paste path is used; the text lands on the command line without a newline, so
   nothing executes until you press Return. Do not test at a password prompt: secure
   input blocks the key monitor, and a stuck recording is cut off by the 90 s watchdog.

Then, in any of them:

- **Dictionary...**: add term `hyper comply`, replacement `HyperComply`; say "hyper
  comply" and confirm `HyperComply` is inserted.
- **Settings...**: switch Cleanup to **None** and dictate again; fillers and missing
  punctuation come back. Switch to **Medium** to restore the default.
- Hold the key and release within a quarter second: the pill shows "Too short".

## 7. On-device transcription (optional, 3 min plus a one-time download)

1. Menu bar icon → Settings… → Transcription → Engine → **On this Mac (Parakeet v3)**.
   The status line under it reads "Downloading / loading Parakeet v3…" then
   "Parakeet v3 ready". The first time this downloads about 470 MB; if the model is
   already cached (the test suite may have fetched it) it only compiles, about a minute.
2. Hold Right Option and dictate. The pill says "Transcribing on this Mac", then
   "Cleaning up" while the Worker runs the LLM pass on the text.
3. Set Cleanup to **None** and remove any dictionary replacements to see it work with the
   Worker stopped: nothing leaves the Mac.
4. Expect Parakeet to join brand names into one word ("hypercomply"); the dictionary
   post-pass handles that when the entry has a replacement.

## 8. Compare raw speech-model output with the cleaned text

Menu bar icon → **Recent Dictations…** (Cmd-H while the menu is open). Each entry shows
the engine, timings, the raw text from Parakeet or the cloud provider, and the final text
after the LLM pass and dictionary replacements. Entries live in memory only. Switch on
"Also append every dictation to a log file" to get JSON lines at
`~/Library/Logs/Aside/dictations.jsonl`, then `tail -f` it while dictating.

## 9. Stop

Quit from the menu-bar icon (**Quit Aside**), then Ctrl-C the Worker.
