# Getting Aside for iPhone into external TestFlight

Every uploaded build already lands in TestFlight for internal testers (your team) with no
review. External testers, and a public link, need Test Information filled in and a
one-time Beta App Review. Here is the whole path, with the text to paste.

## Before you start

- **Agreements.** App Store Connect > Business (or Agreements, Tax, and Banking): the
  free-apps agreement must be accepted. No paid agreement is needed.
- **Trader status (EU).** The banner on the Apps page. Under your account's Business
  section, declare whether you are a trader. For a free app by an individual, "I am not a
  trader" is the usual answer. Not required for TestFlight, but it removes the banner and
  is required before an App Store submission.
- **Privacy policy URL.** `PRIVACY.md` in this repository is the policy. Its address once
  pushed: `https://github.com/cmwright/aside/blob/main/PRIVACY.md`. Fill in the contact
  email at the bottom of that file before you point Apple at it.

## Steps

1. **App Store Connect > Apps > Aside iOS > TestFlight tab.** In the iOS builds list, wait
   until build 8 (0.3.3) reads *Ready to Submit* or *Ready to Test*, not *Processing*.
2. **Export compliance.** The first time a build is used it asks "Does your app use
   encryption?" The app declares `ITSAppUsesNonExemptEncryption = false`, so this is
   usually already answered; if asked, choose *None of the algorithms mentioned above* /
   exempt (the app only uses HTTPS).
3. **Test Information** (left sidebar, under General). Fill in the fields from the "Test
   Information" section below and Save.
4. **Create an external group.** Sidebar > External Testing > "+" > name it `Beta`.
5. **Add the build to the group.** In the group, Builds > "+" > pick build 8 (0.3.3).
   The *What to Test* field appears; paste the text below.
6. **Beta App Review information.** The same sheet asks for contact details and review
   notes the first time. Paste the "Review notes" below. Sign-in required: No.
7. **Submit for review.** Beta App Review typically takes one to two days. You get an
   email; the build's status becomes *Approved*.
8. **Invite testers.** In the `Beta` group either add testers by email (up to 10,000), or
   turn on **Public Link** and share it. Testers install TestFlight from the App Store,
   open the link, and get the build. Each later build you add to the group goes out
   automatically without a new review unless it changes significantly.

## Test Information

**Beta App Name:** Aside

**Beta App Description:**

> Aside is push-to-talk dictation. Tap the mic, speak, and the words are transcribed on
> your iPhone by the Parakeet v3 model and tidied by Apple's on-device model, so nothing
> leaves the phone unless you choose a provider yourself. The Aside keyboard dictates
> straight into any app, and the Control Center control dictates to the clipboard.
>
> To try it: open Aside, let the one-time ~600 MB model download finish, tap Start
> Session, then switch to any app, pick the Aside keyboard (Settings > General > Keyboard
> > Keyboards > Add New Keyboard > Aside, and turn on Allow Full Access), and tap its
> mic. Full Access is only used so the keyboard can hand the recording to the app.

**Feedback Email:** [your contact email]

**Marketing URL:** `https://github.com/cmwright/aside` (optional)

**Privacy Policy URL:** `https://github.com/cmwright/aside/blob/main/PRIVACY.md`

## What to Test (for build 8, 0.3.3)

> Dictation from three places: the mic on the Home tab (a single tap keeps listening
> until you tap again; holding also works), the Aside keyboard inside another app after
> starting a session, and the Aside control in Control Center. Please try it with AirPods
> or another Bluetooth headset if you have one, in both light and dark mode, and tell us
> if the keyboard ever shows "Start a session" while a session is running. The Recent tab
> keeps the last dictations; the Dictionary tab teaches spellings.

## Review notes (Beta App Review Information)

**First name / Last name / Phone / Email:** yours.

**Sign-in required:** No.

**Notes:**

> Aside is a dictation app with a custom keyboard extension. The keyboard requests Allow
> Full Access only because iOS requires it for an extension to read and write the App
> Group shared with its containing app. The keyboard never records audio, never makes
> network requests, and does not read the document beyond a few characters before the
> cursor to decide on a leading space. Recording happens in the Aside app: the keyboard
> writes a start/stop request into the App Group, the app records and transcribes, and
> returns the text.
>
> The app works with no account and no API key. Transcription runs on the device
> (Parakeet v3, a ~600 MB one-time download shown with a progress bar on first launch;
> please allow it to finish) and text cleanup uses Apple's on-device model on iOS 26.
> Connecting a third-party provider with your own API key is optional.
>
> To test: open Aside, wait for "Ready", tap the mic and speak, tap again to stop. For the
> keyboard: tap Start Session in Aside, open Notes, choose the Aside keyboard, tap its
> mic, speak, tap again; the text is inserted at the cursor. The Control Center control
> (iOS 26) records to the clipboard.
>
> Microphone usage: only while dictating, or while a user-started session keeps the
> microphone available in the background for the keyboard (declared with the audio
> background mode). Audio outside a dictation is discarded and never stored.

## App Information that Apple may also ask for before review

These live under the App Store tab > App Information and are required for an App Store
submission; Beta App Review sometimes asks for them too.

- **Category:** Productivity. Secondary: Utilities.
- **Age Rating:** answer *No* to everything; the result is 4+.
- **Content rights:** the app contains no third-party content you need rights for.
- **App Privacy (nutrition label):** *Data Not Collected* is accurate for the default
  configuration; if you want to be conservative, declare *Audio Data* and *User Content*
  as "not linked to you, not used for tracking", noting it only applies when the user
  configures a third-party provider.

## Screenshots

Not required for TestFlight; required for an App Store submission. A set at the 6.9-inch
size (1320 x 2868) is in `ios/screenshots/`, captured on the iPhone 17 Pro Max simulator;
App Store Connect scales that size down for the smaller iPhones. Upload them under App
Store > the version > iPhone 6.9" Display.
