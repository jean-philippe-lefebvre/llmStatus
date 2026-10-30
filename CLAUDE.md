# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

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

**Menu bar:** `StatusBarController` manages `NSStatusItem` with left-click (popover) and right-click (context menu). Icon updates via 1s Timer polling. Next to the cloud, Settings > Menu bar (`MenuBarSettingsSection`: the selected template with its options, then every template drawn live through `MenuBarPreview`) picks a `MenuBarIndicator` (status only, busiest subscription, usage past a threshold, 5h window and countdown, weekly and 5h, a mini gauge per subscription, every subscription as text); `MenuBarContent` turns the usage sections into pieces, `StatusBarController.draw` puts them on the button. Options: hide the cloud with usage (it comes back on any provider issue), and a percent next to each mini gauge. The cloud logo (`Resources/MenuBarIcon.pdf`) is tinted with the provider's status color using `sourceAtop` blend.

**Fetchers** — Six strategies, selected per provider via `FetcherType` enum:
- `StatusFetcher` — Atlassian Statuspage JSON API (Anthropic, OpenAI, Cursor, DeepSeek, Moonshot)
- `GroqFetcher` — incident.io API
- `GoogleFetcher` — Google Cloud incidents JSON (filters to Gemini products only)
- `HTMLStatusFetcher` — keyword-based HTML parsing (Mistral, Perplexity)
- `OpenRouterFetcher` — Datadog public `config.json` (current components and active notices; ignores resolved history)
- `XAIFetcher` — WKWebView to bypass Cloudflare, then HTML parsing. 10min cache.

All fetchers use `HTTPClient` (shared URLSession, 10s/15s timeouts) except XAIFetcher.

**Subscription usage:** `UsageFetcher` / `UsageMonitor` (owned by `StatusMonitor.usage`, 5 min polling) read the weekly + 5h limits of the Claude plan (`api.anthropic.com/api/oauth/usage`, token from the `Claude Code-credentials` keychain item via `/usr/bin/security`, so no prompt) and the ChatGPT plan used by Codex (`chatgpt.com/backend-api/wham/usage`, token from `~/.codex/auth.json`). Tokens are never refreshed here (that would sign the CLIs out); an expired token shows a hint instead. Free Codex resets (`CodexResets`): the local Codex row reads `GET /wham/rate-limit-reset-credits` with its usage and offers "N resets available"; choosing one asks for confirmation (NSAlert, with the usage it would give back), then `POST .../consume` with `credit_id` and a `redeem_request_id`, and reads the limits again (`UsageMonitor.useReset`). Claude desktop app sessions keep their own login and never renew the CLI's keychain item, so an expired local Claude row offers "Renew with Claude Code" (`ClaudeRenewal`: one `claude -p --model haiku --no-session-persistence` call; the CLI refreshes its own token). Shown above the provider list, as named groups of accounts (`UsageGroup` / `UsageAccount`, JSON in `usageGroups`, migrated from the old per-kind `hiddenUsage` toggles; `UsageAccountsSection` in Settings). An account is this Mac's login or a login on an SSH host: `RemoteAccountUsage` pipes a Python script over ssh that reads the login file (`~/.claude/.credentials.json`, `~/.codex/auth.json` or a custom folder), calls the usage API on the host and prints only the limits. Only this Mac's accounts get the log breakdown. Each row folds open an estimated split by app then project (`UsageBreakdown` actor): token-weighted from local logs since the window start (`~/.claude/projects/**/*.jsonl`, deduplicated by response id; `~/.codex/sessions/**/*.jsonl`, cumulative totals diffed), scaled to the server percent. Codex threads listed in `~/.cache/codex-delegate/*/meta.json` (and their subagents) are grouped as "Skill delegate". Codex sources keep a fixed order: Skill delegate, Codex CLI (this Mac, by project), each SSH host (`Record.host`, "<host> · server", with its Hermes and Codex CLI apps, then projects), the ChatGPT app. Parsed records are cached per file (mtime + size). Settings "Codex on SSH hosts" (`RemoteHostsSection`; hosts stored as JSON `[RemoteUsage.Host]` in `usageSSHHosts`, each with enabled flag and extra folders; per-host status in `UsageMonitor.hostStatus`) adds remote Codex usage: `RemoteUsage` pipes a read-only Python collector over `ssh -o BatchMode=yes` (with `sudo -n` when allowed). Settings travel as a base64 JSON line prepended to the script, never in the remote command. The collector finds data by content under /home, /root, /srv, /opt, Docker volumes and extra folders: Codex homes (`auth.json` with `tokens`, sessions read), Hermes (`auth.json` with `credential_pool` next to `state.db`, provider `openai-codex`), and `codex-usage.jsonl` files (format in the README) for `codex exec --ephemeral` services. It deduplicates copies, keeps only the local ChatGPT account, and returns token totals plus a `found` summary.

**Websites and servers:** `InfraMonitor` (owned by `StatusMonitor.infra`) polls the monitors of Settings > Monitors (`MonitorsSettingsSection`; JSON `[WebsiteMonitor]` in `monitorWebsites`, `[ServerMonitor]` in `monitorServers`, intervals `websiteInterval` / `serverInterval`). `WebsiteChecker`: ephemeral no-cache GET, HTTP status, response time (`slowMs`), optional keyword, leaf TLS certificate expiry (read in a task delegate, chain still validated by the system). `ServerChecker`: a read-only POSIX sh probe piped over `ssh -o BatchMode=yes` (`sudo -n` when allowed; the listed services, containers and ports are validated by `ServerMonitor.isSafeName` and prepended as shell variables, never put in the remote command). It prints `kind|name|value` lines (disk, inode, mem, load, uptime, unit, failed, container, port) ending with `ok|end`; `ServerChecker.evaluate` turns them into `CheckItem`s against the disk thresholds. Failed `systemd-run` leftovers (`run-u*.service`) are ignored. A down result is checked again 3 s later; checks are skipped while this Mac is offline. Results (`CheckResult`) show as "Websites" / "Servers" cards above the provider gallery (`MonitorCardView`, `MonitorDetailView`), raise the menu bar cloud's color for any selected provider (`menuBarStatus`), and notify on down, worse or recovered (`InfraMonitor.alert`; unknown never alerts).

**Data flow:** `StatusMonitor.fetchAllStatuses()` → TaskGroup dispatches all fetchers concurrently → results update `providers` array → if watched component is set, overrides provider status → notifications sent for active incidents/recovery.

**UI:** Single `StatusPopoverView` toggles between the main page (subscription usage, then a two-column "Status" gallery of `ProviderCardView`: short name, status icon, and the impacted components or incidents when not operational), a `ProviderDetailView` (components, active incidents, status page link; opened by tapping a card) and `SettingsView` (segmented tabs: General with the Appearance picker (`AppAppearance`: same as macOS, light or dark; applied to the popover and alerts only, the menu bar icon keeps following macOS) and Background picker (`AppBackground`: same as macOS, translucent or solid; system follows Reduce transparency live), Providers with focus components, Usage with SSH hosts, Menu bar). No separate window/view controllers.

## Key patterns

- **@Observable + @ObservationIgnored @AppStorage**: AppStorage properties are ignored by Observation; manual tick counters (`disabledProvidersTick`, `watchedComponentsTick`) force SwiftUI re-renders on change. Monitor settings use typed setter callbacks (`MonitorSettingChange`) wired by `AppDelegate`; the same `applyMonitorSettings()` path initializes polling, notifications (providers and infrastructure), the notification provider and disabled providers at launch. Unchanged assignments do not dispatch or restart polling.
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
