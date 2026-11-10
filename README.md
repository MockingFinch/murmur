# Murmur

Dictation for macOS, and nothing else. Press **⌃X**, speak, press **⌃X** again: Doubao transcribes, a language model polishes the text with your prompt, and the result is pasted where you're typing. It's also left on your clipboard.

With text selected, the same shortcut skips the microphone and rewrites the selection with your prompt instead.

<p align="center"><img src="docs/capsule.png" width="560" alt="Murmur's capsule while listening, polishing and done"></p>

## Install

1. Download `Murmur-<version>.dmg` from [Releases](https://github.com/MockingFinch/murmur/releases/latest) and drag **Murmur** to **Applications**. Requires macOS 26 on Apple silicon.
2. Open it. Murmur isn't notarized by Apple, so the first launch is blocked. Click **Done**, then go to **System Settings → Privacy & Security** and click **Open Anyway**. Or, in Terminal:
   ```bash
   xattr -dr com.apple.quarantine /Applications/Murmur.app
   ```
3. Murmur lives in the menu bar. Its window opens until setup is done.

## Setup

- **Speech:** paste your Doubao key from the [Volcengine console](https://console.volcengine.com/speech/app). Use *API Key* for the new console or *App ID + Token* for the classic one. Pick the model you opened (Doubao ASR 2.0 by default), then click **Test Connection**.
- **Polish** (optional): enter a model API's endpoint, its key and the model's name. Any OpenAI-compatible API works: OpenRouter (the default), OpenAI, DeepSeek, or a model running on this Mac (no key needed). Click **Test**, then adjust the prompt if you like. **Try it** runs a real request on a sample.
- **Shortcut:** allow the Microphone and Accessibility. Accessibility lets Murmur read a selection and paste the result. You can change ⌃X to another shortcut here.

<p align="center"><img src="docs/settings.png" width="720" alt="Murmur's settings window"></p>

## Using it

- **⌃X** starts listening. The words appear live in a capsule at the bottom of the screen.
- **⌃X** again stops. Murmur waits for Doubao's final text, polishes it, and pastes it:
  - into the field with the text cursor, if there is one;
  - otherwise into the text field under the mouse pointer, which it clicks into first;
  - otherwise nowhere: the text stays on the clipboard, and the capsule says so.
- Esc is never captured: it keeps working in the app you're using, and only ⌃X ends a dictation. To cancel, use the menu bar icon.
- **Select text, then ⌃X:** the selection is rewritten with your prompt and replaced. If the selection changed in the meantime, the result goes to the clipboard instead.

## Reliability

- **Nothing you say is lost to the network.** The recording is kept while it streams. If the stream to Doubao breaks, Murmur replays the recording, up to twice. If Doubao never confirms the final text, the latest text it sent goes in, and the capsule says the end may be missing.
- **Polishing has a deadline, not a hair trigger.**
  - One request carries the whole text. It gets up to 180 seconds, retries included (Polish → Timeout).
  - Keep-alives count as progress; only 20 seconds of total silence counts as a stall.
  - Failed requests are retried up to 3 times, honoring `Retry-After`.
  - If the model never answers, the transcript goes in as Doubao heard it.
- **Thinking is kept to a minimum.** On OpenRouter, Murmur asks each model for the least thinking it allows. Polishing gains nothing from it, and thinking by default can take a minute.
- **The connection opens while you speak**, so the answer doesn't wait on DNS and TLS after you stop.

## Privacy and storage

| What | Where |
|---|---|
| API keys | `~/Library/Application Support/Murmur/credentials.json`, readable only by your account |
| Settings | `UserDefaults` (`local.murmur.dictation`) |
| Statistics | `~/Library/Application Support/Murmur/usage.json`: counts and timings only, never text |

Audio goes only to Doubao. Text goes only to the model API you set up. Updates and rebuilds keep all of the above.

## Build from source

```bash
scripts/build.sh --open     # Swift 6 toolchain, macOS 26 SDK
```

macOS remembers Accessibility and Microphone permissions by an app's signature. Builds are ad-hoc signed by default, so each one looks like a new app and needs Accessibility allowed again. To avoid that, create a local signing certificate once:

```bash
scripts/setup-signing.sh
```

It lives in its own keychain file in `~/Library/Application Support/Murmur/Signing`, separate from your login keychain and outside the repo. Every later build is signed with it, so permissions survive rebuilds. To use your own certificate instead, set `MURMUR_SIGN_IDENTITY`.

`scripts/release.sh` builds the `.dmg` and `.zip` for a release.

## Development

```bash
swift test                                     # protocol, streaming, retry and timeout tests against local fake servers
.build/debug/Murmur --snapshot /tmp/murmur     # render every capsule state and settings page to PNG
.build/debug/Murmur --check-navigation         # check that switching pages redraws the window
```

`Sources/MurmurCore` holds the Doubao binary protocol, the client for OpenAI-compatible model APIs and the statistics math, with no UI. `Sources/Murmur` is the app: `Engine/` runs a session, `System/` handles hotkeys, audio, saved keys and text insertion, and `Overlay/` and `UI/` are the interface.
