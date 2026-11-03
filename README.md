# Asystent

Open-source voice assistant for iPhone powered by Claude — a practical Siri alternative.
Speak (Polish or English) → Claude with tool use → real actions on your phone (Calendar, Reminders, HomeKit, Shortcuts) → spoken reply.

**Status:** early prototype. Builds for iOS 18+ with Swift 6 (strict concurrency); not yet on the App Store.

## How it works

```
Back Tap / "Hey Siri, ask Asystent" / Control Center
        │
        ▼
 Speech (SFSpeechRecognizer, on-device when available)
        │
        ▼
 AgentLoop ──► LLMClient ──► Claude (Messages API, tool use)
    │              ├─ AnthropicDirectClient  — your own API key, straight to api.anthropic.com
    │              └─ ProxyClient            — your self-hosted proxy (proxy/)
    ▼
 Tools on the phone (EventKit, HomeKit, Shortcuts) ──► spoken reply (AVSpeechSynthesizer)
```

- **Model:** `claude-opus-5-5` with `output_config.effort: "low"` (short spoken answers, lowest latency)
  and server-side refusal fallback (`fallbacks: "default"`).
- **Destructive or irreversible actions** (currently: running a Shortcut, which can send messages or delete data)
  are executed only after a spoken "yes" (or the Yes button). Silence or "no" cancels.
- The conversation history is append-only and the system prompt is frozen per conversation,
  as required for Claude's preserved thinking blocks.

## Two ways to connect

### 1. Bring your own key (default)
Open **Settings** (gear icon) in the app, choose **Own API key** and paste a key from
[console.anthropic.com](https://console.anthropic.com). The key is stored only in the device Keychain
(`ThisDeviceOnly`, no iCloud sync). Requests go directly from the phone to `api.anthropic.com`
and are billed to your key.

### 2. Self-hosted proxy
Keeps the API key on a server you control. The app authenticates with a shared `APP_TOKEN`.

```bash
cd proxy
cp .env.example .env          # set ANTHROPIC_API_KEY and APP_TOKEN (openssl rand -hex 32)
npm ci && npm start           # Node 22.9+
# or: docker build -t asystent-proxy . && docker run --env-file .env -p 8787:8787 asystent-proxy
```

Then set `PROXY_URL` and `APP_TOKEN` in `Config/Config.local.xcconfig` and choose
**Self-hosted proxy** in Settings. The proxy decides the model, effort and limits; the app can only send
the conversation and its own tool definitions. Put it behind HTTPS (e.g. a reverse proxy) for anything
beyond your home network — the token is embedded in the app build.

## Build

```bash
brew install xcodegen
cp Config/Config.local.xcconfig.example Config/Config.local.xcconfig   # your bundle ID and Team ID
xcodegen generate
open Asystent.xcodeproj
```

`Config.local.xcconfig` is git-ignored; nothing personal (bundle ID, Team ID, IPs, tokens) belongs in the repo.
HomeKit requires a paid Apple Developer account for the entitlement.

## Triggers
- **Back Tap:** Settings → Accessibility → Touch → Back Tap → run a Shortcut that opens `asystent://listen`.
- **Siri:** "Hey Siri, ask Asystent" (App Shortcut, no setup).
- **Control Center / Lock Screen:** add the Asystent control.

iOS limits apply: no background wake word, no remapping of the side button, SMS only via the compose sheet.

## Tests

```bash
swift test                       # agent core (loop, tool registry, API parsing) on macOS, no simulator
cd proxy && npm test             # proxy against a local fake Anthropic API — no key, no cost
xcodebuild test -project Asystent.xcodeproj -scheme Asystent \
  -destination 'platform=iOS Simulator,name=iPhone 17'    # same unit tests inside the app target
```

The app accepts a `-mute` launch argument (set in the shared scheme) that silences text-to-speech.

## Adding a tool
One file per tool implementing `AssistantTool` (JSON Schema + `run`), registered in
`Sources/Tools/DefaultTools.swift`. A tool that deletes or changes data irreversibly must return a question
from `confirmationQuestion(for:)` — the agent loop will not run it without the user's confirmation.

## License
Apache-2.0 — see [LICENSE](LICENSE) and [NOTICE](NOTICE).
