# LLM Status

A lightweight macOS menu bar app that monitors the operational status of major LLM providers in real time, and how much of your Claude and ChatGPT (Codex) subscriptions you have used. One glance at the menu bar tells you whether the model you depend on is healthy, or whether the bug you're chasing is on their side.

<p align="center"><img src="docs/popover.png" width="320" alt="LLM Status popover: subscription usage by group, then the provider status gallery"></p>

<sub>Screenshots use demo data.</sub>

## Supported providers

Anthropic (Claude), OpenAI, Cursor, Google (Gemini), Mistral AI, DeepSeek, Moonshot AI, OpenRouter, Perplexity, xAI (Grok), Groq.

## Features

### Provider status

- **Menu bar indicator**: cloud icon tinted by aggregated severity (green / yellow / orange / red).
- **Status gallery**: providers in two columns, each card naming the impacted components or incidents when something is wrong.
- **Component drill-down**: tap any provider to see per-component status (e.g. Claude API vs Claude Code, OpenAI Chat Completions vs Codex) and its active incidents.
- **Active incident surfacing**: incidents in `investigating` / `identified` / `monitoring` phases are shown inline, even when the provider's global indicator is still green.
- **Watched component**: pin a single component per provider so the menu bar reflects only what you care about.
- **Notifications**: opt-in alerts for incident start and recovery, scoped to one provider or all.
- **Disable / reorder** providers via Settings.

### Subscription usage

- **Weekly and 5-hour limits** of your Claude and ChatGPT (Codex) plans, read from the local Claude Code and Codex logins, with the time left before the 5-hour window resets. Tokens are never refreshed by the app; an expired one keeps the last limits. Sessions in the Claude desktop app do not renew the Claude Code login, so an expired Claude row offers **Renew with Claude Code**: one short Haiku request through the `claude` CLI, which renews its own token. A rate-limited account pauses for a few minutes; **Refresh** retries it right away.
- **Split by app and project**: unfold a subscription for an estimate of what consumed it, from local logs. Codex sources keep a fixed order: the `delegate` skill, Codex CLI on this Mac (by project), each SSH host (Hermes and Codex CLI, then projects), the ChatGPT app.
- **Several subscriptions**: add other Claude or Codex accounts under **Settings → Usage**, each with its own name, in named groups (e.g. "Personal", "Client A"). An account is this Mac's login or a login on an SSH host: there, a read-only Python script calls the usage API on the host itself, so the login token never leaves it, and returns the limits only. The editor lists the Claude and Codex logins found on the host.
- **Menu bar templates**: next to the cloud, show the busiest subscription, an alert past a threshold, the 5-hour window with its countdown, weekly and 5-hour, a mini gauge per subscription or every subscription as text. **Settings → Menu bar** draws each template live with your usage; the cloud can be hidden (it comes back on any provider issue) and each gauge can carry its percent.

<table>
  <tr>
    <td><img src="docs/usage-breakdown.png" width="320" alt="Codex usage split by app, host and project"></td>
    <td><img src="docs/provider-detail.png" width="320" alt="OpenAI components and active incident"></td>
  </tr>
  <tr>
    <td><img src="docs/settings-usage.png" width="320" alt="Settings, Usage tab: account groups and SSH hosts"></td>
    <td><img src="docs/settings-menu-bar.png" width="320" alt="Settings, Menu bar tab: selected template and all templates"></td>
  </tr>
</table>

## Subscription usage on servers (optional)

Codex usage spent on other machines (a VPS running agents or services that call `codex exec`) can join the Codex split. Add each machine under **Settings → Usage → Codex breakdown from SSH hosts** by its SSH alias; each host can be switched off, renamed, and given extra folders to search, and shows what was found there. Nothing is configured by default and no connection is made without a host.

For each host, LLM Status runs a read-only Python 3 script over `ssh -o BatchMode=yes` (key-based login required; `sudo -n` is used when passwordless sudo is allowed, to read service folders). Only token totals with app and project names come back: no prompt, output or credential leaves the host. Usage is counted only for the ChatGPT account logged into your local Codex. The script looks under `/home`, `/root`, `/srv`, `/opt`, Docker volumes and your extra folders, and recognizes data by content:

- **Codex homes** (`~/.codex` or any `CODEX_HOME`): a folder with an `auth.json` holding ChatGPT tokens; its `sessions/` are read.
- **Hermes agents**: `state.db` next to an `auth.json` with a `credential_pool`; only `openai-codex` usage is counted.
- **`codex-usage.jsonl`**: services running `codex exec --ephemeral` leave no session file. To be counted, they append one JSON line per call to a file with this name (anywhere searched, e.g. in a Docker volume), typically from the `usage` of the `turn.completed` event printed by `codex exec --json`:

  ```json
  {"ts": "2026-10-27T09:00:05Z", "input_tokens": 48176, "cached_input_tokens": 0, "output_tokens": 1549, "project": "daily-edition"}
  ```

  `ts` (ISO 8601 or epoch seconds) and the token counts are required. Recommended: `account_id` (the ChatGPT account id, `tokens.account_id` in the service's `CODEX_HOME/auth.json`) and `id` (unique per call, so copies of the file are counted once). Optional: `app` (defaults to the folder or Docker Compose project name) and `project`. Lines without `account_id` count only when every login found on the host (Codex homes and Hermes credentials) is your account and no folder was unreadable.

Copies of the same data (backups, restore checks) are counted once: the most complete copy of a Codex session or Hermes row, and usage lines by `id` (or identical content across files).

## Servers (optional)

Under **Settings → Servers**, add servers to watch next to the providers. They show as "Servers" cards in the popover (tap one for every check), turn the menu bar cloud to the worst status, and send a notification when one goes down, gets worse or recovers. A failure is checked again 3 seconds later before it counts, and nothing is checked while this Mac is offline.

- **Servers** (every 1 to 15 min), by SSH alias: SSH answer time, disk space and inodes of every real filesystem (80 % / 90 % by default, per server), memory available, load per CPU, failed systemd units, plus the systemd services, Docker containers and listening TCP ports you list. A read-only POSIX `sh` script runs over `ssh -o BatchMode=yes` (key-based login required, no Python needed; `sudo -n` is used when allowed, which Docker needs unless the login user is in the `docker` group).

## Requirements

- macOS 14 (Sonoma) or later
- Swift 5.9+ (only for building from source)

## Install

Grab the latest `LLMStatus.app` from the [Releases](https://github.com/jean-philippe-lefebvre/llmStatus/releases) page, or build it yourself:

```bash
make run        # build + sign + install to /Applications + launch
make install    # build + sign + install to /Applications
make all        # build the .app bundle into .build/app/
```

## How status is fetched

| Source | Providers |
|---|---|
| Atlassian Statuspage API | Anthropic, OpenAI, Cursor, DeepSeek, Moonshot |
| incident.io API | Groq |
| Google Cloud incidents JSON | Gemini |
| Datadog JSON | OpenRouter |
| HTML scraping | Mistral, Perplexity |
| Headless WebKit (Cloudflare bypass) | xAI |

All HTTP calls go through a shared `URLSession` with short timeouts; xAI uses a hidden `WKWebView` and caches the result for 10 minutes.

## Development

See [`CLAUDE.md`](CLAUDE.md) for architecture notes, key patterns, and the build/packaging pipeline.

```bash
swift build      # debug build
swift test       # tests
make clean       # wipe build/ and SPM cache
```

## License

MIT
