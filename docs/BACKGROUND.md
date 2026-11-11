# Why Murmur exists

This is the story behind Murmur: the problem it set out to solve, what we needed from a dictation tool, the choices that shaped it, and what it deliberately doesn't do.

## The problem

We spend most of the working day writing. Messages to colleagues, emails to clients, comments on documents, notes after a call, and more and more, instructions for AI tools: prompts that only work when they're long, specific and full of context.

Most of that writing starts as something we could simply *say*. Speaking is several times faster than typing, and for people who work in Chinese the gap is wider still: every phrase typed goes through an input method, its candidates and its corrections. A good part of the day's writing is also in English, to people abroad, which means composing in a second language on top of everything else.

So speaking should be the obvious answer. In practice, it hadn't been, for two reasons.

**Speech isn't writing.** Speech recognition gives you a transcript, and a transcript is a record of how people talk: *ums* and *uhs*, a sentence restarted twice, "Tuesday, no, Wednesday", a thought that wanders before it lands. Pasting that into an email isn't an option, and cleaning it up by hand can take as long as typing it would have.

**Dictation tools ask for too much.** To be worth using many times a day, dictation has to be effortless: no window to switch to, no copying and pasting, no wondering whether it heard you. And it has to be trustworthy. Lose a long, carefully spoken paragraph once, and you stop speaking to it.

## What we needed

1. **Recognition that's excellent at Chinese and English,** including the mixed sentences many of us actually speak: Chinese with English product names, technical terms and phrases dropped in.
2. **Text that reads as written, not spoken.** Fillers and false starts removed, self-corrections resolved, punctuation and numbers right, but the meaning, the tone and the speaker's own words kept. And the rules for this had to be ours to change.
3. **Insertion anywhere,** with one shortcut: in the field where the cursor is, in any app, without leaving it.
4. **Speak Chinese, insert English.** Not a literal translation of a messy transcript, but what a fluent speaker would have written.
5. **Editing by the same means.** Select text that's already written, and have it rewritten or translated in place.
6. **Never losing what was said.** Not to a dropped connection, not to a crash, not to a model that's overloaded or down.
7. **Our own keys and our own choice of model.** No account, no subscription, no server in the middle, and nothing sent anywhere but the services we chose.
8. **Small, quiet and native.** Something that lives in the menu bar and only shows itself while it's working.

## What we found

We tried the dictation products available today. None of them met these needs together, so we built Murmur.

## What Murmur is

Murmur is a menu bar app for the Mac that does one thing: it turns speech into finished text where you're typing.

Press the shortcut and speak. Your words appear live in a small capsule at the bottom of the screen as Doubao recognizes them. Press the shortcut again, and Murmur waits for Doubao's final, more accurate pass, sends the transcript to a language model with your prompt to polish it, and inserts the result at your cursor, leaving a copy on the clipboard. A second shortcut does the same and then translates the polished text into the language you chose. With text selected, either shortcut works on the selection instead of the microphone.

Murmur grew out of work in Chinese and English, and its examples show that, but it isn't limited to them. What goes in can be in any language the model writes well, and selected text can be rewritten or translated whatever its language. Speech is where the limits are today: Doubao transcribes Mandarin, English and several Chinese dialects live. The app's own interface is in English.

## The choices behind it

**Doubao for recognition.** Chinese recognition quality, and the handling of mixed Chinese and English, were the first requirement and the hardest to meet. Doubao's streaming recognition, from Volcengine, met it. Streaming also means you see your words while you speak, which is what makes dictation feel responsive and lets you trust it's listening. Its second pass over each sentence improves accuracy before anything is inserted.

**Any language model for polishing.** Models get better and cheaper every few months. Tying Murmur to one would make it age with that model. So Murmur speaks the API that nearly every provider supports, and works with OpenRouter (the default, since one key reaches hundreds of models), OpenAI, DeepSeek, or a model running on the Mac itself, where text never leaves the machine.

**Your prompt, in the open.** Murmur ships with a careful default prompt, but how you want your writing to sound is personal. The prompt is right there in settings, with a way to try changes on a sample before keeping them.

**Bring your own keys.** With no Murmur server in between, there's nothing to trust beyond the providers you picked yourself, nothing to subscribe to, and the cost is simply what you use.

**A capsule, not a window.** Dictation is a moment inside other work. A window would pull you out of it. The capsule never takes the focus, so the text goes where you were typing, and it never captures Esc, which keeps working in your app.

**One shortcut, two jobs.** With nothing selected, the shortcut dictates. With text selected, it rewrites. There's no mode to remember and nothing to toggle. Translation got its own shortcut rather than a setting, so you always know, as you press it, what's going to come out.

**Insert, and copy too.** Sometimes there's nowhere to insert: no text field, or a field that refuses pasting. The result is always on the clipboard, and the capsule always says where it went.

## Principles

**Never lose what the user said.** This one outranks everything else. Every failure has a fallback that still delivers words: if translating fails, the polished text goes in; if polishing fails, the transcript goes in as it was heard; if the connection to the recognizer drops, Murmur keeps recording, reconnects and catches up; if it never comes back, the recording waits on disk to be transcribed again. A slower result is acceptable. A lost one isn't.

**Say what happened.** The capsule reports what's going on, in plain words: reconnecting, recording only, inserted, copied only, and, when something is missing, how much and what to do about it.

**Do one thing.** Murmur is dictation, and nothing else. Each feature it has is a variation on "turn what I mean into text, here".

**Stay out of the way.** No dock icon, no window during work, no stolen focus, no captured keys. The app is visible for the seconds it's working, and gone otherwise.

**The user's providers, the user's data.** Audio goes only to the speech service, text only to the model the user chose. Keys and recordings stay on the Mac, readable only by the user's account. Statistics are counts, never text.

**Native and light.** A small Mac app that starts instantly and uses next to nothing while it waits.

## What Murmur is not

- **Not a meeting recorder.** It doesn't transcribe calls or long audio files. A dictation runs for up to 15 minutes.
- **Not offline.** Recognition happens on Doubao's servers. Murmur protects what you said when the connection fails, but it needs one to turn speech into text.
- **Not a voice assistant.** It doesn't take commands or control your Mac. What you say becomes text, nothing more.
- **Not a chat with an AI.** The model works behind the scenes, on your words, with your prompt.
- **Not a service.** There are no accounts, no sync, no team features, and nothing hosted.
- **Not cross-platform.** It's a Mac app, for recent macOS on Apple silicon.

## How it grew

**1.0: the core.** Press to talk, press again to insert. Doubao streams the transcript, a language model polishes it with your prompt, and the result is inserted into the field at the cursor or under the pointer and kept on the clipboard. With text selected, the shortcut rewrites the selection. The Overview page shows the characters written and the time saved against typing.

**1.1: speak one language, write another.** A second shortcut dictates, polishes, then translates into the language you choose, with its own prompt, using the model you already set up. With text selected, it translates the selection. The capsule grew to fit its text, from one line to three, and the permission setup got clearer, including macOS 27's new name for Accessibility. Releases from here on share one signature, so updates keep their permissions.

**1.2: never lose a word.** The release about the failure that hurts most: a connection that drops in the middle of a long dictation. Murmur now reconnects while you speak, keeps everything already recognized and catches up on the rest. Every recording is written to disk as you speak and kept until its words are in, with **Transcribe Again** in the menu bar and recovery after a crash or quit. Model requests retry patiently, an answer the model cut short is never inserted, and the last result and transcript stay available from the menu bar.

**1.3: no bill for a forgotten dictation.** A shortcut pressed by accident, or a dictation left running, used to keep recognition running, and billing, until the 15-minute limit. Now, once Doubao has heard nothing new for 2 minutes, Murmur stops listening and carries on with whatever was said. The time is yours to set, and time spent reconnecting doesn't count.

Through every version, the aim has stayed the same: speaking should be the fastest way to write, and it should be safe to rely on.
