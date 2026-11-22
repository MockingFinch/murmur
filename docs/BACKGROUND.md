# Why Murmur exists

This document explains the problem Murmur was built to solve, the product and technical trade-offs behind it, what it deliberately leaves out, and how it has evolved.

## The problem

Most of a typical workday goes into writing: Slack messages, client emails, document comments, call notes, and increasingly, long, context-heavy prompts for AI coding and writing tools.

Speaking is much faster than typing, especially in Chinese where every phrase normally goes through a Pinyin IME and candidate selection. On top of that, a lot of daily work involves writing in English to colleagues abroad, which adds the friction of composing in a second language.

In practice, standard dictation tools still fell short in two ways:

1. **Raw transcripts take too long to clean up.** Normal speech is full of *ums*, restarts, and mid-sentence course corrections ("Tuesday, no, Wednesday"). You can't paste a raw transcript straight into an email, and editing it by hand often takes as long as typing would have.
2. **Everyday friction kills the habit.** If you have to switch windows, copy and paste manually, guess whether the mic is actually picking you up, or worry about a dropped connection eating a two-minute thought, you stop reaching for dictation.

## Requirements

Murmur was designed around a concrete checklist:

1. **Strong Mandarin, English, and mixed-language recognition:** especially Chinese sentences peppered with English product names, code terms, and phrases.
2. **Clean written output with an editable prompt:** remove fillers and false starts, resolve self-corrections, and fix punctuation and formatting without rewriting away your voice.
3. **One-shortcut insertion anywhere:** paste straight into whatever app you're in without changing focus.
4. **Speak in one language, paste in another:** clean up the spoken transcript first, then translate it into natural target-language prose.
5. **In-place rewriting and translation:** highlight existing text and use the same shortcuts to polish or translate it without touching the mic.
6. **Zero lost speech:** survive dropped Wi-Fi, app crashes, and flaky LLM APIs with graceful fallbacks.
7. **Bring your own keys and model:** no Murmur account, no subscription, and no middleman server.
8. **Small, native Mac utility:** lives quietly in the menu bar and only appears while active.

Existing dictation apps missed one or more of these (especially mixed Chinese/English accuracy, BYOK flexibility, or editable prompts), so I built Murmur.

## How it works

Press a global shortcut and start talking. Murmur streams audio to Doubao and displays live text in a small floating bar at the bottom of your screen. Press the shortcut again to finish: Murmur waits for Doubao's more accurate second pass, sends the transcript to your chosen LLM with your polish prompt, pastes the result at your cursor, and leaves a copy on the clipboard.

A second shortcut runs the same flow plus a translation step into your chosen target language. If you already have text selected when you press either shortcut, Murmur skips the microphone and rewrites or translates the selection in place.

## Key design choices

**Doubao ASR 2.0 for speech recognition.** Accurate Mandarin and mixed Chinese/English recognition was the hardest constraint. Doubao's streaming WebSocket API handles code-switching well, gives immediate live feedback while you talk, and runs a higher-accuracy second pass over each completed sentence before final delivery.

**Any OpenAI-compatible model for polishing and translation.** Models improve and drop in price quickly, so hardcoding one provider would lock the app in time. Speaking standard Chat Completions lets you use OpenRouter (the default, giving one-key access to most models), OpenAI, DeepSeek, or a local server like Ollama or LM Studio when you want text to stay on your Mac.

**Exposed, editable prompts.** Writing style is personal. Murmur ships with careful defaults for polishing and translation, puts both prompts directly in Settings, and includes a built-in **Try it** panel so you can test tweaks on sample text before relying on them.

**Bring your own keys.** Skipping user accounts and a hosted backend keeps the app simple, free to run, and private: audio goes straight to Doubao, text goes straight to your chosen LLM endpoint, and you only pay those providers for actual usage.

**A non-activating floating bar.** Dictation happens inside another task, so a regular window would steal focus and break your flow. The floating capsule never takes keyboard focus, shows live status and words while active, and only claims `Esc` globally while recording so you can discard a take without interfering with `Esc` in other apps the rest of the time.

**Context-sensitive shortcuts instead of modes.** With nothing selected, the shortcut dictates; with text selected, it rewrites. Translation has its own dedicated shortcut rather than a toggle hidden in settings, so you always know what you're going to get before you start speaking.

**Paste, and keep a clipboard copy.** Some fields reject synthetic paste events, and sometimes you start dictating without a text field focused. Keeping every result on the clipboard, and telling you in the bar whether it was pasted or only copied, means you never have to repeat yourself.

## Guardrails

- **Never discard what the user said.** Every failure mode degrades instead of failing empty: if translation fails, the polished text goes in; if polishing fails, the raw transcript goes in; if Doubao drops mid-sentence, Murmur keeps recording locally, reconnects, and catches up; if it can't reconnect, the audio stays on disk for **Transcribe Again**.
- **Be explicit about state.** The floating bar tells you plainly when it's reconnecting, recording locally, pasting, copying only, or missing tail audio, along with what to do next.
- **Stay single-purpose.** Every feature serves the same loop: turning what you mean into clean text right where you're working.
- **Keep data local.** API keys and temporary recordings live in user-only files on your Mac. Usage statistics store counts and timings only, never dictated text.
- **Stay native and lightweight.** Pure Swift/AppKit/SwiftUI with no Dock icon during normal use and minimal idle overhead.

## Out of scope

- **Meeting recording or long-form transcription:** Sessions cap at 15 minutes; Murmur is for interactive writing, not transcribing calls or audio files.
- **Fully offline speech recognition:** Doubao requires an internet connection. Murmur protects your recording when the network drops, but still needs connectivity to transcribe it.
- **Voice commands or desktop automation:** Spoken input always becomes text. Murmur doesn't run commands or control your Mac.
- **AI chat:** The LLM strictly cleans up or translates your words according to your prompt.
- **Cloud accounts, sync, or team billing:** Everything stays local to one Mac.
- **Cross-platform support:** Built specifically for modern macOS on Apple silicon.

## Release history

- **1.0 (Core dictation and selection rewrite):** Press-to-talk streaming via Doubao, LLM polishing with an editable prompt, cursor/pointer insertion with clipboard fallback, in-place selection rewriting, and basic usage stats.
- **1.1 (Translation and smoother setup):** Added the translate shortcut (`⌃⌘X`) for both speech and selections, multi-line capsule sizing, clearer Accessibility onboarding (including macOS 27's *Device Control and Data Access* naming), and a shared signing certificate so updates keep permissions.
- **1.2 (Resilience):** Live WebSocket reconnection with confirmed-utterance tracking so nothing is lost or billed twice, local disk recording during capture with **Transcribe Again** and crash/quit recovery, LLM retry and truncation guards, and menu bar Copy actions for the last result and raw transcript.
- **1.3 (Quiet auto-stop):** Automatic stop after 2 minutes without new words from Doubao (configurable, ignoring reconnect time) so an accidental shortcut never runs up a bill, plus stripping stray `~~` strikethrough wrappers from final output.
- **1.4 (Escape to cancel and anchored capsule motion):** Pressing `Esc` while recording cancels and discards the session immediately, and capsule resize transitions stay anchored around a fixed bottom-center point across all states.
- **1.5 (Daily ergonomics and safer interactions):** Double-`Esc` protection for long recordings, focused-display and top/bottom capsule placement, hybrid tap-to-toggle / hold-to-talk shortcuts, microphone selection with live testing, personal vocabulary hints for Doubao and polishing, menu bar language switching, truthful working/badge icon states and last-issue details, optional clipboard restoration, OpenRouter model browser and provider presets, and General settings reorganization.
