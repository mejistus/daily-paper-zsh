# daily-paper-zsh

A small [oh-my-zsh](https://ohmyz.sh/) plugin for fetching the latest
**arXiv** papers matching your keywords on demand.

Default keywords:

- `diffusion`
- `aigc detection`
- `deepfake`

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  📚  Daily arXiv — Sun Aug 23 2026
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

[ diffusion ]
  4DAnyone: Create Anyone in 4D from a Casual Monocular Video
  http://arxiv.org/abs/2608.20335v1

  Correspondence between hydrodynamic frames, transport coefficients…
  http://arxiv.org/abs/2608.20324v1

[ aigc detection ]
  …

[ deepfake ]
  …

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  Tip: 'daily-paper' to refresh · 'daily-paper search <kw>' for a one-off search · 'daily-paper download <id>' for a PDF
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

## Install

```sh
git clone https://github.com/mejistus/daily-paper-zsh \
  ${ZSH_CUSTOM:-~/.oh-my-zsh/custom}/plugins/daily-paper-zsh
```

Then add it to your `~/.zshrc` plugins list:

```sh
plugins=(... daily-paper-zsh)
```

Reload: `exec zsh`.

The plugin does **no I/O at load time** — it's fully manual. Run
`daily-paper` whenever you want to see today's digest.

## Configuration

All options are environment variables. Set them in `~/.zshrc` **before**
the `plugins=(...)` line so the plugin sees them at load time.

| Variable | Default | Description |
|---|---|---|
| `DAILY_PAPER_KEYWORDS` | `"diffusion,aigc detection,deepfake"` | Comma-separated keywords. Multi-word keywords are quoted by the plugin automatically. |
| `DAILY_PAPER_MAX_RESULTS` | `5` | How many papers per keyword to fetch. |
| `DAILY_PAPER_TIMEOUT` | `30` | Per-request `curl` timeout in seconds. |
| `DAILY_PAPER_CACHE_DIR` | `~/.cache/daily-paper-zsh` | Where today's digest + last-shown date are stored. |
| `DAILY_PAPER_DOWNLOAD_DIR` | `$HOME/Downloads` | Where `daily-paper download` saves PDFs. Created with `mkdir -p` if missing. |
| `DAILY_PAPER_DOWNLOAD_TIMEOUT` | `60` | `curl` timeout per PDF download, in seconds. |
| `DAILY_PAPER_PLUGIN_DIR` | auto-detected | Where the plugin lives on disk. Auto-detected from the path the plugin file was sourced from; override only if you've installed it somewhere exotic. |
| `DAILY_PAPER_FORCE` | unset | Set to `1` to refetch even if already shown today (used by `daily-paper`). |
| `DAILY_PAPER_DEBUG` | unset | Set to `1` to print verbose diagnostic info to stderr. |
| `DAILY_PAPER_OPEN` | unset | Set to `1` to open the first paper in your default browser. |
| `DAILY_PAPER_NO_COLOR` | unset | Set to `1` to disable ANSI colors. |

Example — track four keywords and open papers automatically:

```sh
export DAILY_PAPER_KEYWORDS="diffusion,aigc detection,deepfake,gan"
export DAILY_PAPER_MAX_RESULTS=8
export DAILY_PAPER_OPEN=1
```

## Commands

Everything goes through a single `daily-paper` command with subcommands.
Run `daily-paper help` (or `daily-paper --help`) at any time to see this
list.

| Subcommand | What it does |
|---|---|
| `daily-paper` (no args) | Fetch and print today's digest. Subsequent calls the same day short-circuit from cache; set `DAILY_PAPER_FORCE=1` to refetch anyway. |
| `daily-paper search <kw> [...]` | One-off keyword search; prints results inline without touching state or cache. |
| `daily-paper download <id> [...]` | Download one or more arXiv PDFs to `$DAILY_PAPER_DOWNLOAD_DIR` (default `$HOME/Downloads`). See below. |
| `daily-paper cache` | Print the cache directory path and list its contents. |
| `daily-paper clear` | Delete today's cached digest + last-shown marker (next call refetches). |
| `daily-paper update` | Pull the latest version of the plugin from its git origin (see below). |
| `daily-paper help` | Print the subcommand list. |

### Downloading papers

```sh
daily-paper download 2401.12345
daily-paper download 2401.12345 2401.67890v2
daily-paper download arXiv:2401.12345
daily-paper download https://arxiv.org/abs/2401.12345
```

Each argument may be any of:

- a bare id — `2401.12345`
- a versioned id — `2401.12345v2`
- an `arXiv:` prefixed id — `arXiv:2401.12345`
- a full abs or pdf URL — `https://arxiv.org/abs/2401.12345`

Files are written as `<id>.pdf` directly under `$DAILY_PAPER_DOWNLOAD_DIR`.
If `<id>.pdf` already exists, it is skipped (delete the file to force a
re-download). Partial downloads land in `<id>.pdf.partial` first and are
renamed atomically on success — interrupted downloads never leave a
half-written `.pdf` lying around.

### Updating the plugin

```sh
daily-paper update
```

Runs `git fetch` followed by `git pull --ff-only origin <branch>` inside
the plugin's install directory. The path is auto-detected from where the
plugin file was sourced; override with `$DAILY_PAPER_PLUGIN_DIR` if
you've installed it outside the standard
`${ZSH_CUSTOM:-~/.oh-my-zsh/custom}/plugins/` location.

`--ff-only` is used so a stale local branch won't silently produce merge
commits. The subcommand also surfaces local ahead/dirty state before
pulling so you know when manual intervention is needed. Reload your
shell (`exec zsh`) afterwards to pick up any code changes.

### Optional: bring back auto-run

If you miss the old auto-run-on-startup behavior, add this to your
`~/.zshrc` **after** the `plugins=(...)` line:

```sh
precmd() { (( _DAILY_PAPER_DID_AUTORUN )) || { _DAILY_PAPER_DID_AUTORUN=1; daily-paper; } }
```

## How it works

1. The plugin defines `daily-paper` and its subcommands at load time and
   does nothing else — no network, no file I/O, nothing.
2. When you run `daily-paper`, it reads `$DAILY_PAPER_CACHE_DIR/last_shown`.
   If the date there matches today, the call short-circuits silently.
3. Otherwise it fires one `curl` request per keyword — concurrently —
   to arxiv's search page
   (`https://arxiv.org/search/?query=...&order=-announced_date_first&size=25`).
   Each response is parsed for arXiv IDs and titles, results are
   concatenated in keyword order, deduplicated, cached to
   `$DAILY_PAPER_CACHE_DIR/YYYY-MM-DD.txt`, and printed.
4. If arXiv is unreachable, no state is written — the next call retries
   fresh.

The search page is used (instead of `export.arxiv.org/api/query`) because
the API aggressively rate-limits per IP and serves `HTTP 429 Rate
exceeded` even for light personal use. The HTML search page returns the
same data with no rate limiting. `size=25` is the smallest page arxiv
allows (default 50 doubles transfer size with no benefit since we only
read the top `DAILY_PAPER_MAX_RESULTS` entries); concurrent fetches keep
wall-clock time close to a single request rather than N×per-request.

## Requirements

- `curl` (preinstalled on macOS and most Linux)
- `oh-my-zsh` for the plugin loader — the file is a single
  `<name>.plugin.zsh` so it works with any zsh plugin loader that
  sources `$ZSH_CUSTOM/plugins/<name>/<name>.plugin.zsh`

## License

MIT — see [LICENSE](LICENSE).
