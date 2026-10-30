# AGENTS.md

This file provides guidance to Codex (Codex.ai/code) when working with code in this repository.

## What is this?

LLM Status is a macOS menu bar app that monitors operational status of LLM providers (Anthropic, OpenAI, Cursor, Google Gemini, Mistral, DeepSeek, Groq, xAI, OpenRouter, Perplexity). Built with Swift 5.9+ targeting macOS 14 (Sonoma).

## Commands

```bash
# Build + bundle + sign + install to /Applications + run
make run

# Build + install to /Applications (Spotlight / Launchpad copy)
make install

# Build only (release bundle in .build/app)
make all

# Build debug (faster iteration)
swift build

# Run tests
swift test

# Clean everything
make clean

# Kill running app
pkill LLMStatus
```

## Architecture

**Entry point:** `LLMStatusApp.swift` → `AppDelegate` creates three core objects:
- `StatusMonitor` (@Observable) — holds providers, orchestrates concurrent fetching via TaskGroup
- `AppSettings` (@Observable + @AppStorage) — persists user preferences
- `NetworkMonitor` (NWPathMonitor) — tracks connectivity

**Menu bar:** `StatusBarController` manages `NSStatusItem` with left-click (popover) and right-click (context menu). Icon updates via 1s Timer polling. The cloud logo (`Resources/MenuBarIcon.pdf`) is tinted with the provider's status color using `sourceAtop` blend.

**Fetchers** — Six strategies, selected per provider via `FetcherType` enum:
- `StatusFetcher` — Atlassian Statuspage JSON API (Anthropic, OpenAI, Cursor, DeepSeek, Moonshot)
- `GroqFetcher` — incident.io API
- `GoogleFetcher` — Google Cloud incidents JSON (filters to Gemini products only)
- `HTMLStatusFetcher` — keyword-based HTML parsing (Mistral, Perplexity)
- `OpenRouterFetcher` — Datadog public `config.json` (current components and active notices; ignores resolved history)
- `XAIFetcher` — WKWebView to bypass Cloudflare, then HTML parsing. 10min cache.

All fetchers use `HTTPClient` (shared URLSession, 10s/15s timeouts) except XAIFetcher.

**Servers:** `InfraMonitor` (owned by `StatusMonitor.infra`) polls the monitors of Settings > Servers (`MonitorsSettingsSection`; JSON `[ServerMonitor]` in `monitorServers`, interval `serverInterval`). `ServerChecker`: a read-only POSIX sh probe piped over `ssh -o BatchMode=yes` (`sudo -n` when allowed; the listed services, containers and ports are validated by `ServerMonitor.isSafeName` and prepended as shell variables, never put in the remote command). It prints `kind|name|value` lines (disk, inode, mem, load, uptime, unit, failed, container, port) ending with `ok|end`; `ServerChecker.evaluate` turns them into `CheckItem`s against the disk thresholds. Failed `systemd-run` leftovers (`run-u*.service`) are ignored. A down result is checked again 3 s later; checks are skipped while this Mac is offline. Results (`CheckResult`) show as "Servers" cards above the provider gallery (`MonitorCardView`, `MonitorDetailView`), raise the menu bar cloud's color for any selected provider (`menuBarStatus`), and notify on down, worse or recovered (`InfraMonitor.alert`; unknown never alerts).

**Data flow:** `StatusMonitor.fetchAllStatuses()` → TaskGroup dispatches all fetchers concurrently → results update `providers` array → if watched component is set, overrides provider status → notifications sent for active incidents/recovery.

**UI:** Single `StatusPopoverView` toggles between status list and `SettingsView`. No separate window/view controllers.

## Key patterns

- **@Observable + @ObservationIgnored @AppStorage**: AppStorage properties are ignored by Observation; manual tick counters (`disabledProvidersTick`, `watchedComponentsTick`) force SwiftUI re-renders on change.
- **Severity-based ordering**: `enabledProviders` bumps issues (severity ≥ 2) to top while preserving custom drag-drop order.
- **Static component grouping**: OpenAI components are grouped into APIs/ChatGPT/Sora via a static mapping in `StatusFetcher` since the API doesn't return groups. Duplicate component names (e.g. "Login") across groups are handled by scoped IDs.
- **Watched components**: Per-provider focus component stored as `"providerid:name"` CSV. When set, the provider's displayed status reflects only that component.
- **WKWebView for Cloudflare**: XAIFetcher loads pages in a hidden WebView, waits 3s for JS challenge resolution, then extracts HTML via `evaluateJavaScript`.

## Build & packaging

SPM executable target with `Resources/` processed via `.process("Resources")`. The `Makefile` creates a proper `.app` bundle:
- Copies executable to `Contents/MacOS/`
- Copies `Info.plist` (LSUIElement=true — no Dock icon), `AppIcon.icns`, and SPM resource bundle
- Signs with entitlements (network.client)
- `make run` / `make install` copy the bundle to `/Applications/LLMStatus.app` so Spotlight launches the current build (not a stale copy next to the `.build` bundle)

Ad-hoc signing (`-`) for local dev. Use `IDENTITY="Developer ID Application: ..."` for distribution.

## Provider configuration

Providers are defined in `StatusMonitor.defaultProviders()`. Each has: id, name, shortName, statusURL, apiBaseURL, fetcherType. To add a provider: add to that array and implement/reuse a fetcher.

## Status severity (used for aggregation and ordering)

```
0: operational  1: unknown  2: degraded  3: majorOutage  4: critical
```
