# Aside privacy policy

Aside is a dictation app for Mac and iPhone. You press a key or a button, speak, and the
words are typed where your cursor is. This page describes what the apps do with your data.
Last updated 2026-09-11.

## The short version

- Aside does not operate any server that receives your audio or your text. There are no
  accounts and no analytics.
- By default everything happens on your device: speech recognition runs on the Neural
  Engine (the Parakeet v3 model), and text cleanup uses Apple's on-device model.
- If you choose to connect a third-party provider with your own API key, your audio and
  transcripts are sent to that provider, under that provider's terms.
- Your dictation history and dictionary stay on your device.

## What Aside records

The microphone is used only while you are dictating: while you hold the dictation key or
button, or between a tap that starts listening and the tap that stops it. On the iPhone, a
"session" keeps the microphone open in the background so the keyboard and the Control
Center control can dictate without switching apps; audio captured outside a dictation is
discarded immediately and never stored.

## Where speech becomes text

Aside offers three ways to turn speech into text. You choose one in Settings.

1. **On this device (default).** The Parakeet v3 model is downloaded once from the
   FluidAudio project's public model hosting and runs entirely on your device. No audio
   leaves the device.
2. **A provider, directly, with your API key.** Audio is sent from your device straight to
   the OpenAI-compatible service you configured (for example Groq or Cerebras), using a
   key you supply. The key is stored in your device's keychain. What that provider does
   with the audio is governed by its own privacy policy.
3. **A self-hosted Worker (Mac only).** Audio is sent to a backend you run yourself, at the
   URL you enter.

## Text cleanup

After transcription, Aside can tidy the text (punctuation, fillers, grammar). By default
this uses Apple's on-device model and nothing leaves the device. If you select a direct
provider for cleanup, the transcript is sent to that provider with your key.

## What stays on your device

- **Recent dictations.** Kept in memory for the current launch by default. If you choose a
  retention period in Settings, they are stored in the app's own container on the device
  and pruned by age. Nothing is uploaded.
- **Dictionary.** Your custom terms and replacements are stored on the device. On the
  iPhone they live in the app group shared with the Aside keyboard.
- **Settings and API keys.** Settings are stored in the app's preferences; API keys in the
  keychain.

## The iPhone keyboard and Full Access

The Aside keyboard asks for **Allow Full Access**. iOS requires it for a keyboard to read
and write files shared with its companion app, and that is the only reason Aside needs it.
The keyboard itself never records audio, never makes network requests, and never reads
what you type in other apps beyond the few characters before the cursor that it uses to
decide whether to add a leading space. It hands a "start" or "stop" request to the Aside
app through the shared app group, and the app returns the text.

## Control Center and the clipboard

A dictation started from the Aside control in Control Center or from the Shortcuts action
is copied to the clipboard, so it can be pasted anywhere. You choose in Settings how long
iOS keeps it before clearing it.

## Updates (Mac)

The Mac app checks a public GitHub release feed for updates once a day. That request
carries no personal data beyond what any web request includes.

## Children

Aside is not directed at children under 13 and does not knowingly collect information
from them.

## Changes and contact

If this policy changes, the new version will be published at this address with a new
date. Questions: open an issue at https://github.com/cmwright/aside/issues.
