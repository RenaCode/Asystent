# Asystent — prototyp asystenta głosowego (iPhone) na Claude

Brief dla sesji Claude Code na Macu. Odpowiadaj po polsku, zwięźle.

## Cel
Natywna apka iOS (Swift/SwiftUI, iOS 18+), która przejmuje główne funkcje Siri:
wywołanie → mowa (pl-PL) → Claude (tool use) → akcja na telefonie → odpowiedź głosem.

## Stan repo (kompiluje się: Swift 6, iOS 18; testy zielone na symulatorze iPhone 16 z iOS 18.0; CI w `.github/workflows/ci.yml`)
- `project.yml` — definicja projektu dla XcodeGen (app + widget extension + testy)
- `Package.swift` — rdzeń agenta jako pakiet: `swift test` na macOS bez symulatora
- `Sources/App` — SwiftUI, stan rozmowy, potwierdzanie akcji
- `Sources/Settings` — Ustawienia: tryb BYO key / proxy, klucz w Keychain
- `Sources/Voice` — STT (`SFSpeechRecognizer`) i TTS (`AVSpeechSynthesizer`), pl-PL lub en-US; `-mute` wycisza TTS
- `Sources/Agent` — `LLMClient` (`AnthropicDirectClient`, `ProxyClient`) + pętla tool use
- `Resources` — String Catalogs (en + pl): UI, Info.plist, frazy Siri
- `Tests/AsystentTests` — Swift Testing (pętla z atrapą LLMClient, rejestr, parsowanie, stop_reason)
- `Sources/Tools` — narzędzia: kalendarz, przypomnienia, HomeKit, uruchamianie Skrótów
- `Sources/Intents` — App Intent + App Shortcuts (fraza „Hej Siri, …”, Back Tap)
- `Controls` — `ControlWidget` (Control Center / ekran blokady)
- `proxy/` — Node.js proxy do Claude API (klucz API tylko tutaj)

## Zadania (w kolejności)
1. ✅ `brew install xcodegen && xcodegen generate`; Team i bundle ID w `Config/Config.local.xcconfig`.
2. ✅ Kompilacja (Swift 6, strict concurrency).
3. Proxy lokalnie (`cd proxy && cp .env.example .env && npm ci && npm start`),
   `PROXY_URL`/`APP_TOKEN` w `Config/Config.local.xcconfig` (IP Maca w LAN do testów na telefonie) —
   albo tryb BYO key bez proxy.
4. Test end-to-end na fizycznym iPhonie: „Dodaj spotkanie jutro o 10 z zespołem” → event w Kalendarzu.
5. Faza 2: streaming SSE z proxy + TTS zdanie po zdaniu (największy zysk na odczuwalnym lagu).
6. Faza 3: routing modeli (`claude-haiku-5-5` dla prostych komend, `claude-opus-5-5` dla złożonych), pamięć rozmowy.

## Open source (MIT)
- Projekt jest publiczny: zero sekretów, IP, bundle ID i Team ID w repo (`Config.xcconfig` → `Config.local.xcconfig` w `.gitignore`).
- Dodaj tryb **BYO key**: użytkownik wkleja własny klucz Anthropic w Ustawieniach, klucz trafia do Keychain,
  a apka woła `api.anthropic.com` bezpośrednio. Proxy zostaje opcją dla self-hostingu.
  Inspiracja: kiloforgeai/codenamejo (MIT), gdzie wszystko wykonuje się po stronie klienta.
- Abstrakcja `LLMClient` (protokół), implementacje `AnthropicDirectClient` i `ProxyClient`.
- README po angielsku (zasięg), lokalizacja UI: pl + en (String Catalog).

## Zasady
- Model: `claude-opus-5-5`, `output_config.effort` ustawiane jawnie, bez `temperature`/`thinking`/wymuszonego
  `tool_choice` (400), `fallbacks: "default"` + beta `server-side-fallback-2026-07-01`, nagłówek
  `anthropic-version: 2026-10-21`. `stop_reason` sprawdzany przed treścią (refusal, max_tokens, pause_turn).
- Historia rozmowy tylko dopisywana, prompt systemowy zamrożony na rozmowę (bloki thinking są związane z prefiksem);
  bloki z odpowiedzi API wracają bez zmian (`ContentBlock.raw`).
- Zero sekretów, imion i danych osobowych w repo i w commitach; autor commitów: `RenaCode <2884538+mbeczynski@users.noreply.github.com>` (adres noreply GitHuba, bez prywatnego e-maila).
- Klucz `ANTHROPIC_API_KEY` nigdy w repo. W trybie proxy apka ↔ proxy autoryzowana `APP_TOKEN`.
- Każde narzędzie = osobny plik implementujący `AssistantTool`; rejestracja w `ToolRegistry`.
- Akcje destrukcyjne (usuwanie eventów itp.) wymagają potwierdzenia głosowego — narzędzie zwraca pytanie
  z `confirmationQuestion(for:)`, pętla bez „tak” go nie wykona (dziś: `run_shortcut`).
- Testy: `swift test`, `cd proxy && npm test`; aplikację w symulatorze zawsze z `-mute`.
- Wywołanie: Action Button jest zajęty (wyciszanie) — używamy Back Tap, frazy Siri i ControlWidget.

## Ograniczenia iOS (nie próbuj obchodzić)
Brak wake worda w tle, brak podmiany przycisku bocznego, SMS tylko przez compose sheet,
brak zmiany ustawień systemowych poza tym, co dają Skróty.
