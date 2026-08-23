# daily-paper-zsh.plugin.zsh
#
# Daily arXiv paper digest for oh-my-zsh.
#
# On the first interactive shell of each day, fetches the latest arXiv
# papers matching the configured keywords (default: "diffusion",
# "aigc detection", "deepfake") and prints the title + URL of each one.
# Subsequent shells that day print the cached result silently.
#
# Configuration (set in ~/.zshrc BEFORE the plugins=(...) line):
#
#   DAILY_PAPER_KEYWORDS     comma-separated keywords
#                            default: "diffusion,aigc detection,deepfake"
#   DAILY_PAPER_MAX_RESULTS  papers per keyword       default: 5
#   DAILY_PAPER_TIMEOUT      curl timeout in seconds  default: 20
#   DAILY_PAPER_CACHE_DIR    override cache dir       default: ~/.cache/daily-paper-zsh
#
#   DAILY_PAPER_DISABLE      set to 1 to disable the plugin
#   DAILY_PAPER_FORCE        set to 1 to refetch even if already shown today
#   DAILY_PAPER_DEBUG        set to 1 for verbose diagnostic output to stderr
#   DAILY_PAPER_OPEN         set to 1 to open the first paper in your browser
#   DAILY_PAPER_NO_COLOR     set to 1 to disable ANSI colors
#
# Manual commands:
#
#   daily-paper              refetch today's digest
#   daily-paper-keyword <kw> [more...]   one-off keyword search (prints inline)
#   daily-paper-cache        show the cache directory and its contents
#   daily-paper-clear        delete today's cache + state (next shell re-fetches)

# ---- default values (only assigned when unset/empty) -----------------------
: ${DAILY_PAPER_KEYWORDS:="diffusion,aigc detection,deepfake"}
: ${DAILY_PAPER_MAX_RESULTS:=5}
: ${DAILY_PAPER_TIMEOUT:=20}
: ${DAILY_PAPER_CACHE_DIR:="${XDG_CACHE_HOME:-$HOME/.cache}/daily-paper-zsh"}
: ${DAILY_PAPER_DISABLE:=}
: ${DAILY_PAPER_FORCE:=}
: ${DAILY_PAPER_DEBUG:=}
: ${DAILY_PAPER_OPEN:=}
: ${DAILY_PAPER_NO_COLOR:=}

# ============================================================================
# Helpers
# ============================================================================

_daily_paper_zsh_log() {
  [[ -n "$DAILY_PAPER_DEBUG" ]] && print -ru2 -- "daily-paper-zsh: $*"
}

_daily_paper_zsh_today() {
  emulate -L zsh
  print -r -- "$(date +%Y-%m-%d)"
}

# Has today's papers already been displayed on this machine?
_daily_paper_zsh_should_show() {
  emulate -L zsh
  local state_file="$DAILY_PAPER_CACHE_DIR/last_shown"
  [[ -n "$DAILY_PAPER_FORCE" ]] && return 0
  [[ ! -f "$state_file" ]] && return 0
  local last_shown
  last_shown="$(< "$state_file" 2>/dev/null)" || return 0
  [[ -z "$last_shown" ]] && return 0
  [[ "$last_shown" != "$(date +%Y-%m-%d)" ]]
}

_daily_paper_zsh_mark_shown() {
  emulate -L zsh
  command mkdir -p "$DAILY_PAPER_CACHE_DIR" 2>/dev/null || return 1
  date +%Y-%m-%d >! "$DAILY_PAPER_CACHE_DIR/last_shown" 2>/dev/null
}

# Fetch papers for a single keyword. Writes 3 lines per paper to stdout:
#   line 1: keyword
#   line 2: title
#   line 3: arxiv URL (http://arxiv.org/abs/...)
_daily_paper_zsh_fetch_keyword() {
  emulate -L zsh
  local keyword="$1"
  local max_results="$2"
  # arxiv search_query supports AND/OR/ANDNOT; quote multi-word keywords.
  local query="${keyword// /+}"
  local url="https://export.arxiv.org/api/query?search_query=all:${query}&max_results=${max_results}&sortBy=submittedDate&sortOrder=descending"

  _daily_paper_zsh_log "GET $url"

  local response
  if ! response="$(command curl -sSL -m "$DAILY_PAPER_TIMEOUT" "$url" 2>/dev/null)"; then
    print -ru2 -- "daily-paper-zsh: curl failed for keyword '$keyword'"
    return 1
  fi

  [[ -z "$response" ]] && return 1

  # Decode the five standard XML entities, then parse entries with awk.
  # awk handles <title> blocks that span multiple lines (arxiv wraps long
  # titles), and skips the feed-level <title> by only matching inside <entry>.
  print -r -- "$response" \
    | command sed -e 's/&amp;/\&/g' \
                  -e 's/&lt;/</g' \
                  -e 's/&gt;/>/g' \
                  -e 's/&quot;/"/g' \
                  -e "s/&apos;/'/g" \
    | command awk -v kw="$keyword" '
        /<entry>/      { in_entry=1; title=""; id=""; in_title=0; next }
        /<\/entry>/    {
          if (in_entry && title != "" && id != "") {
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", title)
            gsub(/[[:space:]]+/, " ", title)
            print kw
            print title
            print id
          }
          in_entry=0; next
        }
        in_entry {
          if (in_title) {
            if (match($0, /<\/title>/)) {
              t = $0; sub(/<\/title>.*/, "", t)
              title = title " " t
              gsub(/[[:space:]]+/, " ", title)
              in_title = 0
            } else {
              title = title " " $0
            }
            next
          }
          if (match($0, /<title>/)) {
            t = $0; sub(/.*<title>/, "", t)
            if (match(t, /<\/title>/)) {
              sub(/<\/title>.*/, "", t)
              title = t
              gsub(/[[:space:]]+/, " ", title)
            } else {
              title = t
              in_title = 1
            }
            next
          }
          if (match($0, /<id>/) && id == "") {
            t = $0; sub(/.*<id>/, "", t); sub(/<\/id>.*/, "", t)
            id = t
            next
          }
        }
      '
}

# Pretty-print a 3-lines-per-paper blob.
# $1: data blob, one paper per 3 lines (keyword, title, url)
_daily_paper_zsh_display() {
  emulate -L zsh
  local data="$1"
  # Weekday first, then year-month-day (ISO-style, locale-independent).
  #   en_US:  Sun 2026-08-23
  #   CJK:    日 2026-08-23
  local today_human
  today_human="$(date '+%a %Y-%m-%d')"

  local -a lines
  # Trim one trailing newline if present so `(@f)` gives a consistent count
  # (otherwise a trailing \n yields one extra empty element and the loop runs
  # one iteration too many, printing a phantom entry).
  data="${data%$'\n'}"
  lines=( "${(@f)data}" )
  (( ${#lines[@]} >= 3 )) || return 0

  # ANSI colors: prefer tput, fall back to raw escapes, blank when no tty.
  local bold="" cyan="" yellow="" dim="" reset=""
  if [[ -z "$DAILY_PAPER_NO_COLOR" ]]; then
    if (( ${+commands[tput]} )); then
      bold="$(tput bold 2>/dev/null)"
      cyan="$(tput setaf 6 2>/dev/null)"
      yellow="$(tput setaf 3 2>/dev/null)"
      dim="$(tput dim 2>/dev/null)"
      reset="$(tput sgr0 2>/dev/null)"
    fi
    # fall back to raw escapes if tput produced nothing
    if [[ -z "$reset" ]]; then
      bold=$'\033[1m'; cyan=$'\033[36m'; yellow=$'\033[33m'
      dim=$'\033[2m';  reset=$'\033[0m'
    fi
  fi

  local sep="━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

  print ""
  print -r -- "${cyan}${bold}  📚  Daily arXiv — ${today_human}${reset}"
  print -r -- "${cyan}${sep}${reset}"
  print ""

  local i=1 last_kw=""
  while (( i <= ${#lines[@]} )); do
    local kw="${lines[$i]}"
    local title="${lines[$((i+1))]}"
    local url="${lines[$((i+2))]}"

    if [[ "$kw" != "$last_kw" ]]; then
      print -r -- "${yellow}${bold}[ ${kw} ]${reset}"
      last_kw="$kw"
    fi
    print -r -- "  ${title}"
    print -r -- "  ${dim}${url}${reset}"
    print ""

    i=$((i+3))
  done

  print -r -- "${cyan}${sep}${reset}"
  print -r -- "${dim}  Tip: 'daily-paper' to refresh · 'daily-paper-keyword <kw>' for a one-off search${reset}"
  print -r -- "${cyan}${sep}${reset}"
  print ""
}

# Open the first URL in the OS default browser (best-effort, fire-and-forget).
_daily_paper_zsh_maybe_open() {
  emulate -L zsh
  [[ -n "$DAILY_PAPER_OPEN" ]] || return 0
  local first_url="${1:-}"
  [[ -z "$first_url" ]] && return 0

  local opener=""
  if   [[ -n "${commands[open]:-}"     ]]; then opener="open"
  elif [[ -n "${commands[xdg-open]:-}" ]]; then opener="xdg-open"
  fi
  if [[ -n "$opener" ]]; then
    "$opener" "$first_url" >/dev/null 2>&1 &
  fi
}

# Main: fetch + cache + display (once per day, controlled by should_show).
_daily_paper_zsh_run() {
  emulate -L zsh
  setopt extended_glob

  if ! _daily_paper_zsh_should_show; then
    _daily_paper_zsh_log "already shown today, skipping"
    return 0
  fi

  if ! (( ${+commands[curl]} )); then
    print -ru2 -- "daily-paper-zsh: curl not found — install curl or set DAILY_PAPER_DISABLE=1"
    return 1
  fi

  command mkdir -p "$DAILY_PAPER_CACHE_DIR" 2>/dev/null

  local -a keywords
  keywords=( "${(@s:,:)DAILY_PAPER_KEYWORDS}" )

  local all_data="" first_url="" any_paper=0 out
  for kw in "${keywords[@]}"; do
    out="$(_daily_paper_zsh_fetch_keyword "$kw" "$DAILY_PAPER_MAX_RESULTS")"
    if [[ -n "$out" ]]; then
      # remember the first URL we see across all keywords
      if (( any_paper == 0 )); then
        first_url="$(print -r -- "$out" | sed -n '3p')"
        any_paper=1
      fi
      all_data+="${out}"$'\n'
    fi
  done

  if [[ -z "$all_data" ]]; then
    print -ru2 -- "daily-paper-zsh: no papers fetched (network issue or arxiv down?)"
    # do NOT mark shown — retry on next shell if arxiv comes back
    return 1
  fi

  # Persist today's cache, then display, then mark shown
  local today
  today="$(_daily_paper_zsh_today)"
  print -r -- "$all_data" >! "$DAILY_PAPER_CACHE_DIR/${today}.txt"

  _daily_paper_zsh_display "$all_data"
  _daily_paper_zsh_mark_shown
  _daily_paper_zsh_maybe_open "$first_url"

  return 0
}

# ============================================================================
# User-facing commands
# ============================================================================

# Re-run the digest right now (refetch even if shown today).
daily-paper() {
  emulate -L zsh
  DAILY_PAPER_FORCE=1 _daily_paper_zsh_run
}

# Search one-off keyword(s) and print results inline (no caching, no state).
daily-paper-keyword() {
  emulate -L zsh
  if (( $# < 1 )); then
    print -ru2 -- "usage: daily-paper-keyword <keyword> [...]"
    return 1
  fi
  if ! (( ${+commands[curl]} )); then
    print -ru2 -- "daily-paper-zsh: curl not found"
    return 1
  fi
  local all_data=""
  for kw in "$@"; do
    local out
    out="$(_daily_paper_zsh_fetch_keyword "$kw" "$DAILY_PAPER_MAX_RESULTS")"
    [[ -n "$out" ]] && all_data+="${out}"$'\n'
  done
  [[ -z "$all_data" ]] && {
    print -ru2 -- "daily-paper-zsh: no results"
    return 1
  }
  _daily_paper_zsh_display "$all_data"
}

# Show the cache directory and its contents.
daily-paper-cache() {
  emulate -L zsh
  print -r -- "$DAILY_PAPER_CACHE_DIR"
  if [[ -d "$DAILY_PAPER_CACHE_DIR" ]]; then
    command ls -la "$DAILY_PAPER_CACHE_DIR"
  else
    print -r -- "(empty or not yet created)"
  fi
}

# Delete today's cache + state so the next shell refetches.
daily-paper-clear() {
  emulate -L zsh
  local today
  today="$(_daily_paper_zsh_today)"
  command rm -f "$DAILY_PAPER_CACHE_DIR/${today}.txt" \
                 "$DAILY_PAPER_CACHE_DIR/last_shown"
  print -r -- "daily-paper-zsh: cleared today's cache for $today"
}

# ============================================================================
# Auto-run on plugin load
#
# Only the first interactive shell of the day shows output:
#   - [[ -o interactive ]] guards against non-interactive shells (scripts,
#     CI, `zsh -c '...'`).
#   - [[ -t 1 ]] guards against redirected/piped output.
#   - DAILY_PAPER_DISABLE short-circuits.
# Subsequent shells that day see state already updated and return silently.
# ============================================================================

if [[ -o interactive ]] && [[ -t 1 ]] && [[ -z "$DAILY_PAPER_DISABLE" ]]; then
  _daily_paper_zsh_run
fi
