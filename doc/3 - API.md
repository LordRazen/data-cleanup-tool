# 3 API (v0.5)

External services that functions can call, e.g. Claude for image or text analysis. Kept separate from the base (`1 - Base.md`) and from the functions (`2 - FunctionOverview.md`) (confirmed).

Language rule as in `2 - FunctionOverview.md`: document and code in English, only GUI-visible values in German.

## 1. Principles
- **Never pay per use** (confirmed). No service is used in a way that is billed by consumption. For Claude this means: no Anthropic API key, only the existing Claude subscription via the locally installed Claude Code (see `3.1 - ClaudeEndpoint.md`).
- **Free services first** (confirmed): a function uses free endpoints first (e.g. Nominatim for places) and only falls back to Claude when the free ones cannot answer.
- An endpoint is a wrapper with one clear interface. Functions never call a service directly, only through its endpoint.
- An endpoint never touches files in `Input`, `Result` or `Doublets`. It only returns data. Moving stays with the function and its preview (base rule).
- Every endpoint can be unavailable (not installed, not logged in, limit reached, offline). Functions must handle that without breaking: they skip the affected files and report it.
- Data sent to an external service leaves the computer. Each function that uses an endpoint says in its specification what it sends.

## 2. Structure
- One specification per endpoint: `3.<n> - <Name>Endpoint.md`.
- One script per endpoint: `System/Code/Api/<Name>Endpoint.ps1`, loaded by `Common.ps1`.
- Settings per endpoint in `settings.json` under `api.<name>`, e.g. `api.claude`.

## 3. Common interface
Every endpoint offers:
- `Test-<Name>Endpoint`: returns whether the service is usable right now, with a reason if not.
- `Invoke-<Name>Endpoint`: does one call and always returns an object with:
  - `Success` (true/false)
  - `Data` (the answer, e.g. text or parsed JSON)
  - `Error` (short English error text for the log)
  - `ErrorKind`: `NotInstalled`, `NotLoggedIn`, `Offline`, `LimitReached`, `Timeout`, `InvalidResponse`, `Other`
  - `DurationMs`

## 4. Logging
- Every call is written into the log of the calling function as step type `API_CALL` with endpoint, file, duration and result (`OK` or the `ErrorKind`).
- Content sent or received is not written to the log, only a short summary, so logs stay small and private.

## 5. Endpoints

| No. | Name | Service | Billing | Status |
|---|---|---|---|---|
| 3.1 | `ClaudeEndpoint` | Claude via local Claude Code, headless | Claude subscription (Pro), never pay per use | v0.3, no open questions |
| 3.2 | `NominatimEndpoint` | OpenStreetMap Nominatim, reverse geocoding (GPS → place) | free, no key | v0.2, no open questions |

## 6. Notes on the base (not entered there)
- New code folder `System/Code/Api/`.
- New step type `API_CALL`.
- New settings section `api` in `settings.json`.

## 7. Open questions
- None.
