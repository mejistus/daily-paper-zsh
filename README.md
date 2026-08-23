# daily-paper-zsh

A small [oh-my-zsh](https://ohmyz.sh/) plugin that fetches the latest
**arXiv** papers matching your keywords the first time you open a
terminal each day, and prints their titles + URLs.

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
  Tip: 'daily-paper' to refresh · 'daily-paper-keyword <kw>' for a one-off search
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

That's it — the next time you open a terminal the plugin will print
today's digest.

## Configuration

All options are environment variables. Set them in `~/.zshrc` **before**
the `plugins=(...)` line so the plugin sees them at load time.

| Variable | Default | Description |
|---|---|---|
| `DAILY_PAPER_KEYWORDS` | `"diffusion,aigc detection,deepfake"` | Comma-separated keywords. Multi-word keywords are quoted by the plugin automatically. |
| `DAILY_PAPER_MAX_RESULTS` | `5` | How many papers per keyword to fetch. |
| `DAILY_PAPER_TIMEOUT` | `20` | Per-request `curl` timeout in seconds. |
| `DAILY_PAPER_CACHE_DIR` | `~/.cache/daily-paper-zsh` | Where today's digest + last-shown date are stored. |
| `DAILY_PAPER_DISABLE` | unset | Set to `1` to disable the plugin entirely. |
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

The plugin exposes four user-facing commands:

| Command | What it does |
|---|---|
| `daily-paper` | Refetch today's digest right now (ignores "already shown today"). |
| `daily-paper-keyword <kw> [more...]` | One-off keyword search; prints results inline without touching state or cache. |
| `daily-paper-cache` | Print the cache directory path and list its contents. |
| `daily-paper-clear` | Delete today's cached digest + last-shown marker (next shell refetches). |

## How it works

1. On shell startup, the plugin reads `$DAILY_PAPER_CACHE_DIR/last_shown`.
2. If the date there differs from today (or the file is missing), it
   fires off one `curl` request per keyword to
   `https://export.arxiv.org/api/query` and parses the Atom XML response
   with `awk`.
3. Papers are deduplicated by arXiv ID, cached to
   `$DAILY_PAPER_CACHE_DIR/YYYY-MM-DD.txt`, printed to your terminal,
   and the date is recorded.
4. On every subsequent shell that day, the date check fails and the
   plugin returns silently. No network traffic, no extra prompt.

If arXiv is unreachable, no state is written — the next shell retries
fresh.

## Requirements

- `curl` (preinstalled on macOS and most Linux)
- An interactive shell with a tty stdout (so the plugin won't fire in
  scripts, pipes, or CI)
- `oh-my-zsh` for the plugin loader — the file is a single
  `<name>.plugin.zsh` so it works with any zsh plugin loader that
  sources `$ZSH_CUSTOM/plugins/<name>/<name>.plugin.zsh`

## License

MIT — see [LICENSE](LICENSE).
