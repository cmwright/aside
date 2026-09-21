# Aside 0.4.0

One integrated update on `next-version-reliability`; no intermediate releases.
Mac build 13, iOS build 12. Distribution: signed/notarized Mac release through
GitHub/Sparkle, and a signed iOS upload to App Store Connect for TestFlight.

- [x] Share transcription and cleanup, with cancellation, deadlines and raw-text recovery.
- [x] Isolate Mac recordings and iOS jobs so stale work cannot affect a newer dictation.
- [x] Preserve IPC ordering and associate stop/cancel commands with their recording.
- [x] Fix keyboard deadlines, session heartbeats, interruption recovery and idle expiry.
- [x] Start dictation from a cold keyboard launch and deliver its result after returning.
- [x] Add a Live Activity with recording controls within Apple's microphone restrictions.
- [x] Keep provider URLs/models scoped to their provider.
- [x] Preserve transcripts when Worker cleanup fails.
- [x] Move history writes off the main thread; reduce capture callback allocations.
- [x] Pin dependencies and update documentation.
- [x] Run regression tests and Mac/iOS builds; bump the version once for the finished update.

## Automated verification

Run `bash scripts/verify.sh` (install Worker dependencies with `npm ci` first).
Mac verification uses `mac/build/verification`, separate from the development app
launched by `mac/run.sh`, so tests cannot replace a running development executable
and invalidate its Accessibility approval.

- Mac: 88 tests executed, 85 passed, 3 opt-in model integration tests skipped; no failures.
- iOS: app, keyboard and control/Live Activity extension compile for a generic iOS device.
- Worker: 41 tests passed; TypeScript typecheck passed.
- Patch whitespace and shell syntax checks passed.

The regressions cover cleanup fallback/deadlines/cancellation, late speech completion,
provider profile isolation, history write ordering, capture memory bounds, subsecond IPC
ordering, stale stop commands, heartbeat expiry, keyboard deadlines and cold-handoff
persistence. They do not exercise live microphone hardware or provider credentials.

## Device checks before publishing

- [ ] Mac: cancel during the recording tail or cleanup, immediately record again; only
  the new dictation may finish. Repeat while connecting/disconnecting AirPods.
- [ ] Mac/iPhone: interrupt cleanup connectivity; raw text remains available. Retry
  cleanup; the Mac copies revised text without duplicating insertion, iPhone shows it
  in the app. Cancel a retry and confirm the delivered history entry remains.
- [ ] iPhone: tap the keyboard mic without a session, allow Aside to start recording,
  return via the breadcrumb, stop from the keyboard, and confirm one insertion. Repeat
  after the keyboard process has been recreated and after the result already finished.
- [ ] iPhone: calls/Siri, Bluetooth route changes, locking, and background suspension
  must not leave a false usable session or an endless Transcribing state.
- [ ] iPhone: dictate near idle expiry; the dictation finishes and the timeout renews.
  Force-quit Aside and confirm the keyboard rejects its stale heartbeat within 8 seconds.
- [ ] iOS 26: Lock Screen/Dynamic Island Dictate and Stop controls, stale activity Resume,
  Control Center replacement recordings, and Shortcuts clipboard delivery.

The keyboard still cannot record directly: its cold-start path opens Aside. Returning
to the previous app still uses the iOS breadcrumb. Live Activity controls operate through
the app's audio session. These platform interactions require a signed device build.
