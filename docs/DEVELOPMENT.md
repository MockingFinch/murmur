# Developing Murmur

How to build Murmur from source, test it, make a release and regenerate the README's pictures. For what Murmur is and why, see the [README](../README.md) and [Why Murmur exists](BACKGROUND.md).

## Requirements

- An Apple silicon Mac with macOS 26 or later
- The Swift 6 toolchain and the macOS 26 SDK (Xcode 26 or later)
- For the README's demos: `ffmpeg` with `libwebp` (`brew install ffmpeg`), and `cwebp` for the stills (`brew install webp`)

## Build and run

```bash
scripts/build.sh --open
```

This builds `build/Murmur.app` and launches it. Without `--open`, it only builds.

### Signing, so permissions survive rebuilds

macOS remembers Accessibility and Microphone permissions by an app's signature. Builds are ad-hoc signed by default, so each one looks like a new app: its Accessibility entry has to be removed and allowed again after every rebuild. To avoid that, create a local signing certificate once:

```bash
scripts/setup-signing.sh
```

It lives in its own keychain file in `~/Library/Application Support/Murmur/Signing`, separate from your login keychain and outside the repo. Every later build is signed with it. To sign with your own certificate instead, set `MURMUR_SIGN_IDENTITY`, for example `"Apple Development: you@example.com (TEAMID)"`.

## Tests

```bash
swift test
```

The tests run against local fake servers, so they need no keys and no network:

- `CoreTests`: the Doubao binary protocol, prompts, model listings, answer parsing, statistics and shortcuts
- `NetworkTests`: streaming, retries, timeouts and stalls against a fake Doubao server and a fake model API
- `ResilienceTests`: recognition that survives dropped connections, refusals and a server that never returns
- `RecordingStoreTests`: recordings written to disk as they grow, listed and cleaned up

## Release

1. Raise `CFBundleShortVersionString` and `CFBundleVersion` in `Resources/Info.plist`.
2. Run:
   ```bash
   scripts/release.sh
   ```
   It runs the tests, builds, and writes `build/Murmur-<version>.dmg`, `build/Murmur-<version>.zip` and `build/Murmur-<version>.sha256`.
3. Publish all three on a GitHub release tagged `v<version>`.

Sign releases with the same certificate every time, so users keep their permissions across updates.

## Development aids

The app has a few command-line modes for development. None of them reads the real API keys.

```bash
.build/debug/Murmur --snapshot /tmp/murmur               # every capsule state and settings page, as PNGs
.build/debug/Murmur --snapshot /tmp/murmur --configured  # …as a user who has finished setup sees them
.build/debug/Murmur --check-navigation                   # checks that switching pages redraws the window
```

`--configured` shows placeholder keys and both permissions as granted, without touching either.

### The README's pictures

The stills and demos in `docs/media` are drawn by the app itself, offscreen, so they always show the current interface. Use a release build: the demos are recorded in real time and need the speed.

```bash
swift build -c release --product Murmur
```

**Stills:** the Overview, Speech, Translate and Polish pages, light and dark, and the capsule's states:

```bash
.build/release/Murmur --product-shots /tmp/shots
for f in overview translate speech; do for m in light dark; do
  cwebp -quiet -q 90 -m 6 /tmp/shots/window-$f-$m.png -o docs/media/window-$f-$m.webp
done; done
cwebp -quiet -q 90 -m 6 /tmp/shots/capsule.png -o docs/media/capsule.webp
```

**Demos:** four scripted films (`dictate`, `translate`, `rewrite`, `offline`), each written as numbered frames plus a `frames.txt` that holds every frame's duration. `--only <name>` records just one.

```bash
.build/release/Murmur --film /tmp/film
for n in dictate translate rewrite offline; do
  (cd /tmp/film/$n && ffmpeg -loglevel error -y -f concat -safe 0 -i frames.txt \
    -vf "fps=24,scale=1600:-1:flags=lanczos" \
    -c:v libwebp_anim -lossless 0 -quality 82 -compression_level 6 -loop 0 -preset picture \
    "$OLDPWD/docs/media/$n.webp")
done
```

The scripts, mock windows and wallpaper are in `Sources/Murmur/App/Films.swift`, the stills in `ProductShots.swift`. Keep each demo under about 1.5 MB, so the README loads quickly.

## Code layout

- `Sources/MurmurCore`: everything without UI. The Doubao binary protocol and streaming session, recognition that survives dropped connections (`ResilientTranscriber`), recordings on disk (`RecordingStore`), the client for OpenAI-compatible model APIs, the polish and translate prompts, shortcuts and the statistics math.
- `Sources/Murmur`: the app.
  - `Engine/` runs a session from shortcut to insertion, and holds the capsule's state.
  - `System/` handles hotkeys, audio capture, sounds, permissions, saved keys and settings, and reading and inserting text.
  - `Overlay/` is the capsule. `UI/` is the settings window.
  - `App/` is the menu bar, launch, and the development aids above.

## How failures are handled

What Murmur does when something goes wrong, in detail. The rule behind all of it: what the user said is never thrown away.

**Recognition**

- If the stream to Doubao drops while the user speaks, the capsule shows **Reconnecting**. Murmur keeps every sentence Doubao has confirmed, opens a new connection and sends only the audio after the last confirmed one, faster than real time until it catches up. Nothing is transcribed or billed twice.
- While the user is speaking, it never gives up. After they stop, it gives up after 5 tries in a row that get nothing back. What Doubao confirmed then goes in, along with the words still in progress, and the capsule says how much at the end is missing.
- If Doubao refuses partway (a key or quota problem), the capsule shows **Recording only**: recording goes on, and what was confirmed until then goes in.
- If the microphone disappears and no other takes over, the dictation ends and what was said until then goes in.

**Recordings**

- Each dictation is written to `~/Library/Application Support/Murmur/Recordings` a moment behind the microphone (folder `0700`, files `0600`), and deleted once its text is in.
- If the text came back incomplete, or not at all, the recording stays, for **Transcribe Again** in the menu bar: it runs the recording through Doubao, polishing and translation again and inserts the result.
- A recording cut off by a crash or a quit is offered at the next launch.
- Cancelling while speaking discards the recording. Cancelling after stopping keeps it.
- Recordings are kept for 7 days at most. Ones shorter than 0.3 seconds are discarded.

**The model**

- One request carries the whole text. It gets up to 180 seconds, retries included (Polish → Timeout).
- Keep-alives count as progress. Only 20 seconds of total silence counts as a stall.
- A failed request is sent again, up to 5 attempts in all, honoring `Retry-After`. Errors a new request can't fix (a wrong key, no credits, an unknown model) skip the wait.
- Translating works the same way, with its own 5 attempts.
- If polishing still fails, the transcript goes in as Doubao heard it. If translating fails, the polished text goes in. Whatever goes in is also on the clipboard.
- An answer cut off at the model's length limit is never inserted, since it would drop the end of what was said. The full transcript goes in instead. When OpenRouter lists how much a model can write in one answer, Murmur never asks for more.
- On OpenRouter, Murmur asks each model for the least thinking it allows. Polishing gains nothing from it, and thinking by default can take a minute.
- The connection to the model opens while the user is still speaking, so the answer doesn't wait on DNS and TLS after they stop.

**Limits**

- A dictation stops at 15 minutes. The timer turns amber in the last minute. What was said goes in as usual.
