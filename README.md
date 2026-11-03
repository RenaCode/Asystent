# Asystent (Hejo)

Open-source voice assistant for iPhone powered by Claude. Launch it with Back Tap, Siri or Control Center,
speak (Polish or English) → Claude with tool use → real actions on your phone (Calendar, Reminders, Shortcuts,
and HomeKit in the local build) → spoken reply.

The app is called **Hejo** on the home screen and in the App Store; *Asystent* is the name of this repository
and of the Xcode project.

**Status:** early prototype. Builds for iOS 18+ with Swift 6 (strict concurrency); not yet on the App Store.

## How it works

```
Back Tap / "Hey Siri, ask Hejo" / Control Center
        │
        ▼
 Speech (SFSpeechRecognizer, on-device when available)
        │
        ▼
 AgentLoop ──► LLMClient ──► Claude (Messages API, tool use)
    │              ├─ AnthropicDirectClient  — your own API key, straight to api.anthropic.com
    │              └─ ProxyClient            — your self-hosted proxy (proxy/)
    ▼
 Tools on the phone (EventKit, Shortcuts, HomeKit*) ──► spoken reply (AVSpeechSynthesizer)
```
\* local build only, see [Build variants](#build-variants).

- **Model:** `claude-opus-5-5` with `output_config.effort: "low"` (short spoken answers, lowest latency)
  and server-side refusal fallback (`fallbacks: "default"`).
- **Destructive or irreversible actions** (currently: running a Shortcut, which can send messages or delete data)
  are executed only after a spoken "yes" (or the Yes button). Silence or "no" cancels.
- **Nothing is sent before consent.** On first use the app explains what goes to Anthropic (the transcribed
  text of your request, event dates and titles, reminder text, Shortcut names) and asks for permission.
  Consent is stored on the device per connection mode and can be withdrawn in Settings → Privacy; without it
  every request is blocked before it leaves the phone (`ConsentGatedClient`). The UI states that answers come
  from AI.
- The conversation history is append-only and the system prompt is frozen per conversation,
  as required for Claude's preserved thinking blocks.

## Two ways to connect

### 1. Bring your own key (default)
Open **Settings** (gear icon) in the app, choose **Own API key** and paste a key from
[console.anthropic.com](https://console.anthropic.com). The key is stored only in the device Keychain
(`ThisDeviceOnly`, no iCloud sync). Requests go directly from the phone to `api.anthropic.com`
and are billed to your key.

### 2. Self-hosted proxy
Keeps the API key on a server you control. The option appears in Settings only in builds that have
`PROXY_URL` and `APP_TOKEN` set, so the App Store build (where both are empty) offers only your own key. The app authenticates with a shared `APP_TOKEN`.

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
xcodegen generate                 # App Store variant (default)
open Asystent.xcodeproj
```

`Config.local.xcconfig` is git-ignored; nothing personal (bundle ID, Team ID, IPs, tokens) belongs in the repo.

### Build variants

| | `xcodegen generate` (App Store, default) | `xcodegen generate --spec project-local.yml` (local) |
|---|---|---|
| Own API key | yes | yes |
| Self-hosted proxy | only if `PROXY_URL`/`APP_TOKEN` are set | yes, including plain `http` on your LAN |
| HomeKit (`home_control`) | no tool, no entitlement, no usage description | yes (`HOMEKIT_ENABLED`) |

HomeKit stays out of the App Store build because Apple's license agreement does not allow HomeKit data to leave
the device, and the `home_control` tool returns accessory and scene names to the model. Build the local variant
for your own phone; it needs a paid Apple Developer account for the HomeKit entitlement. CI builds both variants
and fails if the App Store one contains HomeKit.

Keep `NSHomeKitUsageDescription` (and `NSLocalNetworkUsageDescription`) out of `Resources/InfoPlist.xcstrings`:
the catalog is shared, so a translation there ends up in the App Store build's `InfoPlist.strings`. Xcode may add
the keys back after a local-variant build in the IDE; do not commit them (CI and `StoreBuildTests` catch it).

Archive for the App Store only from the App Store variant: run plain `xcodegen generate` (no `--spec`) right
before archiving, also after working on the local variant. The Xcode project is generated and git-ignored, never
committed; CI checks that plain `xcodegen generate` gives a project without HomeKit (no `HOMEKIT_ENABLED`, no
HomeKit entitlement, no `NSHomeKitUsageDescription`). Before archiving, also keep `PROXY_URL` and `APP_TOKEN` empty and replace the privacy policy
placeholder in `Sources/Settings/AppLinks.swift`.

## Triggers
- **Back Tap:** Settings → Accessibility → Touch → Back Tap → run a Shortcut that opens `asystent://listen`.
- **Siri:** "Hey Siri, ask Hejo" (App Shortcut, no setup).
- **Control Center / Lock Screen:** add the Hejo control.

iOS limits apply: no background wake word, no remapping of the side button, SMS only via the compose sheet.

## Tests

```bash
swift test                       # agent core (loop, tool registry, API parsing) on macOS, no simulator
cd proxy && npm test             # proxy against a local fake Anthropic API — no key, no cost
xcodebuild test -project Asystent.xcodeproj -scheme Asystent \
  -destination 'platform=iOS Simulator,name=iPhone 17'    # unit tests + build checks inside the app target
```

Run the app tests for both variants (`xcodegen generate` and `xcodegen generate --spec project-local.yml`):
`StoreBuildTests` checks that HomeKit is present only in the local build.

The app accepts a `-mute` launch argument (set in the shared scheme) that silences text-to-speech.

## Adding a tool
One file per tool implementing `AssistantTool` (JSON Schema + `run`), registered in
`Sources/Tools/DefaultTools.swift`. A tool that deletes or changes data irreversibly must return a question
from `confirmationQuestion(for:)` — the agent loop will not run it without the user's confirmation.

## License
MIT — see [LICENSE](LICENSE).

## Trademarks
Hejo and Asystent are independent open-source projects by RenaCode. They are not affiliated with, endorsed by
or sponsored by Apple Inc. or Anthropic PBC. Siri, Apple, iPhone and HomeKit are trademarks of Apple Inc.,
registered in the U.S. and other countries. Claude and Anthropic are trademarks of Anthropic PBC. These names
are used only to describe compatibility and the services the app connects to.
