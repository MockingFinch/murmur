# Developing Murmur

Build, test, sign, release, and regenerate media for Murmur. For product background and design decisions, see [README.md](../README.md) and [docs/BACKGROUND.md](BACKGROUND.md).

## Requirements

- Apple silicon Mac running macOS 26 or later
- Swift 6 toolchain and macOS 26 SDK (Xcode 26 or later)
- Optional, for regenerating README media: `ffmpeg` with `libwebp` (`brew install ffmpeg`) and `cwebp` (`brew install webp`)

## Build and run

```bash
scripts/build.sh --open
```

Builds `build/Murmur.app` and launches it. Omit `--open` to build without launching.

### Local code signing

macOS ties Microphone and Accessibility permissions to an app's signature. Ad-hoc builds look like a brand-new binary every time, forcing you to remove and re-add Murmur in Accessibility settings after each rebuild.

To avoid that, generate a persistent local signing certificate once:

```bash
scripts/setup-signing.sh
```

This creates a standalone keychain in `~/Library/Application Support/Murmur/Signing` (separate from your login keychain and outside the repo) that subsequent builds use automatically. To sign with a different identity instead, set `MURMUR_SIGN_IDENTITY` (for example, `"Apple Development: you@example.com (TEAMID)"`).

## Tests

```bash
swift test
```

All tests run against local fake servers (`FakeServers.swift`), requiring no API keys or network access:

- `CoreTests`: Doubao binary framing, prompt assembly/cleaning, OpenRouter model parsing, usage math, and shortcut validation
- `NetworkTests`: WebSocket streaming, retries, timeouts, and stream stalls against fake Doubao and LLM endpoints
- `ResilienceTests`: Mid-session disconnects, non-retryable rejections, and permanent offline fallbacks
- `RecordingStoreTests`: Incremental PCM disk writes, listing, and retention cleanup
- `SilenceWatchTests`: Quiet-timeout expiration and excluding reconnect intervals from quiet time

## Release process

1. Bump `CFBundleShortVersionString` and `CFBundleVersion` in `Resources/Info.plist`.
2. Run:
   ```bash
   scripts/release.sh
   ```
   This runs `swift test`, builds the app, and writes `build/Murmur-<version>.dmg`, `build/Murmur-<version>.zip`, and `build/Murmur-<version>.sha256`.
3. Upload all three artifacts to a GitHub release tagged `v<version>`.

Always sign releases with the same certificate so existing users retain their macOS Accessibility permissions across updates.

## Development utilities

Murmur includes built-in headless CLI modes for inspecting UI states and generating docs media. None of them touch your real API keys.

```bash
.build/debug/Murmur --snapshot /tmp/murmur               # Render all capsule states and settings pages as PNGs
.build/debug/Murmur --snapshot /tmp/murmur --configured  # Same, using placeholder keys and granted permissions
.build/debug/Murmur --check-navigation                   # Verify sidebar page switching redraws the window
```

`--configured` injects fake placeholder keys and simulates granted Microphone/Accessibility permissions without modifying system state.

### Regenerating README screenshots and demos

All stills and animated WebPs under `docs/media/` are rendered offscreen directly by the app. Use a release build so real-time demo capture runs at full speed:

```bash
swift build -c release --product Murmur
```

**Stills** (Overview, Speech, and Translate windows in light/dark mode, plus capsule states):

```bash
.build/release/Murmur --product-shots /tmp/shots
for f in overview translate speech; do for m in light dark; do
  cwebp -quiet -q 90 -m 6 /tmp/shots/window-$f-$m.png -o docs/media/window-$f-$m.webp
done; done
cwebp -quiet -q 90 -m 6 /tmp/shots/capsule.png -o docs/media/capsule.webp
```

**Animated demos** (`dictate`, `translate`, `rewrite`, `offline`): each outputs numbered PNG frames and a `frames.txt` timing manifest. Pass `--only <name>` to capture a single demo.

```bash
.build/release/Murmur --film /tmp/film
for n in dictate translate rewrite offline; do
  (cd /tmp/film/$n && ffmpeg -loglevel error -y -f concat -safe 0 -i frames.txt \
    -vf "fps=24,scale=1600:-1:flags=lanczos" \
    -c:v libwebp_anim -lossless 0 -quality 82 -compression_level 6 -loop 0 -preset picture \
    "$OLDPWD/docs/media/$n.webp")
done
```

Demo scripts, mock app windows, and wallpapers live in `Sources/Murmur/App/Films.swift`; stills live in `Sources/Murmur/App/ProductShots.swift`. Aim to keep each animated `.webp` under ~1.5 MB so the README loads cleanly.

## Code layout

- `Sources/MurmurCore`: Platform-agnostic core logic, including the Doubao binary codec and WebSocket session, reconnectable transcriber (`ResilientTranscriber`), local PCM storage (`RecordingStore`), quiet-timeout tracker (`SilenceWatch`), OpenAI-compatible streaming client (`OpenRouterClient`), polish/translate prompts, shortcut definitions, and usage math.
- `Sources/Murmur`: macOS app target:
  - `Engine/`: Session orchestration (`DictationEngine`) and capsule view state (`HUDModel`).
  - `System/`: Global hotkeys, `AVAudioEngine` capture, synthesized audio cues, permission checks, settings/key storage, and Accessibility/clipboard text bridging.
  - `Overlay/`: Non-activating floating capsule (`HUDPanel`, `HUDView`, `Waveform`).
  - `UI/`: Resizable SwiftUI settings window and pages.
  - `App/`: Menu bar controller, app lifecycle, and offscreen snapshot/film tools.

In `HUDView`, the glass capsule animates its measured width and height around a fixed horizontal center (anchored at the bottom or top edge depending on **General → Floating bar position**) on the screen containing the focused window. Multi-stage sessions show a live `Speech → Polish → Translate` progress strip with stage-keyed under-glass glows (coral, violet, teal, mint) and a concise completion metric pill on finished dictations. Active and result contents lay out independently so outgoing transcripts and incoming confirmations crossfade cleanly, and streaming model jobs hold a height floor equal to the preview transcript to avoid collapsing on the first token. Busy and error cues pulse the status icon inside the capsule rather than shifting the window frame, and all capsule animations respect `accessibilityReduceMotion`.

## Failure handling reference

Summary of how Murmur behaves under network, audio, and API errors:

**Speech recognition (Doubao)**

- **Mid-speech disconnect:** The capsule displays **Reconnecting**. Murmur preserves every confirmed utterance, opens a fresh WebSocket, and replays only unconfirmed audio faster than real time until caught up, avoiding duplicate transcription and double billing.
- **Persistent failure:** While you're still speaking, reconnection retries indefinitely. Once you stop, Murmur gives up after 5 consecutive attempts with no new confirmations, delivers everything confirmed plus any in-progress words, and reports how many trailing seconds are missing.
- **Non-retryable refusal (auth, quota, config):** The capsule switches to **Recording only**, continues capturing audio locally, and inserts whatever was confirmed before the error.
- **Lost microphone:** If the active input disappears and no fallback device takes over, recording ends cleanly and processes what was captured so far.

**Local recordings**

- Audio is flushed to `~/Library/Application Support/Murmur/Recordings` (directory `0700`, files `0600`) continuously during capture and deleted as soon as complete text is delivered.
- Incomplete or failed sessions keep their `.pcm` file on disk so you can run **Transcribe Again** from the menu bar (including the original polish/translate pipeline).
- Recordings interrupted by a crash or app quit are surfaced at next launch.
- Pressing `Esc` while listening (including while reconnecting) cancels immediately for short takes (< 10 seconds and < 20 visible characters) and requires a second `Esc` within 2.5 seconds once substantial speech has been captured, preventing accidental deletion of long dictations. Using **Cancel** from the menu bar after stopping speaking aborts the wait while preserving the recording on disk.
- Saved recordings expire after 7 days; clips shorter than 0.3 seconds are discarded automatically. Individual saved recordings can be transcribed or deleted from the menu bar, and the most recent warning or error stays accessible in the menu bar until dismissed or cleared by a clean completion.

**Language model (Polish / Translate)**

- Before inserting or copying, Murmur strips stray `~~` strikethrough wrappers from final speech and model output (in addition to cleaning echoed XML tags, code fences, and added surrounding quotes).
- Each job runs as a single streaming request with a default 180-second total budget including retries (configurable under **Polish → Timeout**).
- SSE keep-alive comments reset the idle timer; 20 seconds without any bytes counts as a stall.
- Transient failures retry up to 5 total attempts with backoff and `Retry-After` support. Non-retryable errors (bad API key, out of credits, unknown model) fail immediately. Translation gets its own 5-attempt budget.
- Fallback order: if polishing fails, Doubao's raw transcript is inserted; if translation fails, the polished text is inserted. Results are always copied to the clipboard as well.
- Truncated responses (`finish_reason == "length"`) are never inserted; Murmur falls back to the full prior text instead. When using OpenRouter, `max_tokens` is clamped to the model's advertised output limit.
- For OpenRouter endpoints, Murmur requests the lowest reasoning effort each model supports to avoid multi-second thinking delays during polishing, and pre-warms the connection while you're still speaking to avoid cold DNS/TLS latency on stop.

**Session limits**

- **Max duration:** 15 minutes. The capsule timer turns amber in the final minute, then stops and processes the recording normally.
- **Quiet auto-stop:** Stops automatically after 2 minutes with no new words from Doubao (configurable from 30 seconds to 10 minutes, or Never, under **Speech → Listening**), showing an amber countdown in the final seconds. Only connected time counts toward the limit; reconnect intervals are excluded. If speech was captured, it processes normally; if nothing was heard, the recording is discarded.
