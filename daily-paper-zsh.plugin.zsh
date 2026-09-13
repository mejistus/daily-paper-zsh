# daily-paper-zsh.plugin.zsh
#
# Manual arXiv paper digest for oh-my-zsh.
#
# This plugin is fully manual — nothing runs on shell startup. Run
# `daily-paper` whenever you want to see today's digest. The plugin
# does no I/O at load time, so shell startup stays instant.
#
# Configuration (set in ~/.zshrc BEFORE the plugins=(...) line):
#
#   DAILY_PAPER_KEYWORDS        comma-separated keywords
#                               default: "diffusion,aigc detection,deepfake"
#   DAILY_PAPER_MAX_RESULTS     papers per keyword       default: 5
#   DAILY_PAPER_TIMEOUT         curl timeout in seconds  default: 30
#   DAILY_PAPER_CACHE_DIR       override cache dir       default: ~/.cache/daily-paper-zsh
#   DAILY_PAPER_DOWNLOAD_DIR    where 'download' saves PDFs
#                               default: $HOME/Downloads
#   DAILY_PAPER_DOWNLOAD_TIMEOUT curl timeout per PDF    default: 60
#   DAILY_PAPER_PLUGIN_DIR      override plugin dir (auto-detected otherwise)
#
#   DAILY_PAPER_FORCE           set to 1 to refetch even if already shown today
#   DAILY_PAPER_DEBUG           set to 1 for verbose diagnostic output to stderr
#   DAILY_PAPER_OPEN            set to 1 to open the first paper in your browser
#   DAILY_PAPER_NO_COLOR        set to 1 to disable ANSI colors
#
# Commands:
#
#   daily-paper [search|download|cache|clear|update|help] [...]
#     (no args)        fetch and print today's digest
#     search <kw>      one-off keyword search (prints inline)
#     download <id>    download arXiv PDFs to $DAILY_PAPER_DOWNLOAD_DIR
#     cache            show the cache directory and its contents
#     clear            delete today's cache + state (next call refetches)
#     update           pull the latest version from the git origin
#     help             list subcommands

# ---- default values (only assigned when unset/empty) -----------------------
: ${DAILY_PAPER_KEYWORDS:="diffusion,aigc detection,deepfake"}
: ${DAILY_PAPER_MAX_RESULTS:=5}
: ${DAILY_PAPER_TIMEOUT:=30}
: ${DAILY_PAPER_CACHE_DIR:="${XDG_CACHE_HOME:-$HOME/.cache}/daily-paper-zsh"}
: ${DAILY_PAPER_FORCE:=}
: ${DAILY_PAPER_DEBUG:=}
: ${DAILY_PAPER_OPEN:=}
: ${DAILY_PAPER_NO_COLOR:=}
: ${DAILY_PAPER_DOWNLOAD_DIR:="$HOME/Downloads"}
: ${DAILY_PAPER_DOWNLOAD_TIMEOUT:=60}
# Auto-detect the plugin's install directory from the path this file was
# sourced from (symlink-resolved). Override in .zshrc if you've installed it
# somewhere exotic.
: ${DAILY_PAPER_PLUGIN_DIR:=${${(%):-%x}:A:h}}

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
#   line 3: arxiv URL (https://arxiv.org/abs/...)
#
# Hits the human-facing arxiv search page (arxiv.org/search/) rather than
# export.arxiv.org/api/query. The API aggressively rate-limits per IP
# (~1 req/3s) and serves HTTP 429 even for light personal use; the search
# page is the same data, same freshness, no rate limiting, and the HTML
# is straightforward to parse for the fields we need (id + title).
_daily_paper_zsh_fetch_keyword() {
  emulate -L zsh
  local keyword="$1"
  local max_results="$2"

  _daily_paper_zsh_log "search arxiv.org for '$keyword' (max $max_results)"

  # Write body to one tmp file, capture status code via curl's --write-out
  # to another. This lets us distinguish a transport-level failure (curl
  # exits non-zero) from an HTTP-level one (curl exits 0 but got a 5xx
  # response with an error page in the body).
  local body_file code_file http_code
  body_file="$(command mktemp 2>/dev/null || command touch /dev/null)"
  code_file="$(command mktemp 2>/dev/null || command touch /dev/null)"
  command curl -sSL -m "$DAILY_PAPER_TIMEOUT" \
                --get "https://arxiv.org/search/" \
                --data-urlencode "searchtype=all" \
                --data-urlencode "query=${keyword}" \
                --data-urlencode "order=-announced_date_first" \
                --data-urlencode "start=0" \
                -o "$body_file" -w '%{http_code}' \
                > "$code_file" 2>/dev/null
  local curl_status=$?
  http_code="$(command cat "$code_file" 2>/dev/null)"
  command rm -f "$code_file"

  if (( curl_status != 0 )); then
    command rm -f "$body_file"
    print -ru2 -- "daily-paper-zsh: curl failed for keyword '$keyword' (network issue or arxiv down?)"
    return 1
  fi

  case "$http_code" in
    2*) ;;   # success; fall through to parse body below
    5*)
      command rm -f "$body_file"
      print -ru2 -- "daily-paper-zsh: arxiv returned HTTP $http_code for keyword '$keyword' (server error — try again later)"
      return 1
      ;;
    *)
      command rm -f "$body_file"
      print -ru2 -- "daily-paper-zsh: arxiv returned HTTP $http_code for keyword '$keyword'"
      return 1
      ;;
  esac

  # The search page is one big HTML document. Walk it line-by-line with a
  # state machine: toggle in_result on <li class="arxiv-result"> /
  # </li>, and inside each block capture the /abs/ link (id) and the
  # <p class="title ...">...</p> body (title). After awk runs, a sed
  # pass strips remaining HTML tags (e.g. arxiv's <span class="search-hit">
  # keyword-highlight markup inside titles).
  command awk -v kw="$keyword" -v max="$max_results" '
    BEGIN { n = 0 }
    /<li class="arxiv-result">/ { in_result = 1; id = ""; title = ""; in_title = 0; next }
    in_result && /<\/li>/ {
      if (id != "" && title != "" && !(id in seen)) {
        seen[id] = 1
        print kw
        print title
        print id
        n++
        if (n >= max) exit
      }
      in_result = 0
      next
    }
    in_result {
      # arxiv id: any <a href=".../abs/XXXX.XXXXX[vN]"> tag
      if (id == "" && match($0, /href="[^"]*\/abs\/[0-9]{4}\.[0-9]{4,5}(v[0-9]+)?/)) {
        s = $0; sub(/.*href="[^"]*\/abs\//, "", s); sub(/["? ].*/, "", s)
        id = "https://arxiv.org/abs/" s
      }
      # Title opener: <p class="title ..."> — start accumulating
      if (in_title == 0 && title == "" && match($0, /<p class="title[^>]*>/)) {
        s = $0; sub(/.*<p class="title[^>]*>/, "", s)
        title = s
        in_title = 1
        next
      }
      # Title body / closer
      if (in_title == 1) {
        if (match($0, /<\/p>/)) {
          s = $0; sub(/<\/p>.*/, "", s)
          title = title " " s
          in_title = 0
        } else if ($0 ~ /[^[:space:]]/) {
          title = title " " $0
        }
      }
    }
  ' "$body_file" \
    | command sed -e 's/<[^>]*>//g' \
                  -e 's/&/\&/g' \
                  -e 's/</</g' \
                  -e 's/>/>/g' \
                  -e 's/"/"/g' \
                  -e "s/'/'/g" \
                  -e 's/&ndash;/-/g' \
                  -e 's/&hellip;/.../g' \
    | command awk '
        { lines[NR] = $0 }
        END {
          for (i = 1; i <= NR; i++) {
            line = lines[i]
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", line)
            gsub(/[[:space:]]+/, " ", line)
            print line
          }
        }
      '

  command rm -f "$body_file"
}




# Pretty-print a 3-lines-per-paper blob.
# $1: data blob, one paper per 3 lines (keyword, title, url)
_daily_paper_zsh_display() {
  emulate -L zsh
  local data="$1"
  # Weekday first (Simplified Chinese, locale-independent), then ISO date.
  #   星期一 2026-08-23 ... 星期日 2026-08-23
  local -a cn_wdays=(星期一 星期二 星期三 星期四 星期五 星期六 星期日)
  local today_human="${cn_wdays[$(date +%u)]} $(date '+%Y-%m-%d')"

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
  print -r -- "${dim}  Tip: 'daily-paper' to refresh · 'daily-paper search <kw>' for a one-off search · 'daily-paper download <id>' for a PDF${reset}"
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

# Normalize an arxiv id from any of these input forms:
#   2401.12345                       -> 2401.12345
#   2401.12345v2                     -> 2401.12345v2
#   arXiv:2401.12345                 -> 2401.12345
#   https://arxiv.org/abs/2401.12345 -> 2401.12345
#   https://arxiv.org/pdf/2401.12345.pdf -> 2401.12345
#   https://arxiv.org/abs/cs.LG/0612001  -> cs.LG/0612001
# Prints the normalized id on stdout; returns non-zero if input is unusable.
_daily_paper_zsh_extract_arxiv_id() {
  emulate -L zsh
  local raw="$1"

  raw="${raw#"${raw%%[![:space:]]*}"}"   # trim leading whitespace
  raw="${raw%"${raw##*[![:space:]]}"}"   # trim trailing whitespace

  case "$raw" in                         # strip "arXiv:" prefix (case-insensitive)
    [aA][rR][xX][iI][vV]:*) raw="${raw#*:}" ;;
  esac
  raw="${raw#:}"

  case "$raw" in                         # URL? grab the bit after /abs/ or /pdf/
    https://*|http://*)
      case "$raw" in
        */abs/*) raw="${raw##*/abs/}" ;;
        */pdf/*) raw="${raw##*/pdf/}" ;;
        *)       raw="${raw##*/}"    ;;
      esac
      raw="${raw%%\?*}"                  # drop query string
      raw="${raw%%#*}"                   # drop fragment
      case "$raw" in
        *.pdf) raw="${raw%.pdf}" ;;
        *.PDF) raw="${raw%.PDF}" ;;
      esac
      ;;
  esac

  raw="${raw%/}"                         # trim trailing slashes

  if [[ "$raw" =~ '^[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)?$' ]] \
     && [[ "$raw" == *.* || "$raw" == */* ]]; then
    print -r -- "$raw"
    return 0
  fi
  return 1
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
    print -ru2 -- "daily-paper-zsh: curl not found — install curl to use this command"
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
#
# Everything goes through `daily-paper` as a dispatcher. The bare form
# (no args) refetches today's digest; anything else routes to a
# _daily_paper_zsh_<subcommand> implementation.
# ============================================================================

_daily_paper_zsh_help() {
  emulate -L zsh
  cat <<'EOF'
Usage: daily-paper [subcommand] [args...]

Subcommands:
  (none)              Refetch today's digest (ignores "already shown today").
  search <kw> [...]   One-off keyword search; prints results inline.
  download <id> [...] Download arXiv PDFs to $DAILY_PAPER_DOWNLOAD_DIR
                      (default: $HOME/Downloads).
  cache               Show the cache directory and its contents.
  clear               Delete today's cache + state (next shell refetches).
  update              Pull the latest version of this plugin from its git origin.
  help                Show this message.
EOF
}

daily-paper() {
  emulate -L zsh
  if (( $# == 0 )); then
    DAILY_PAPER_FORCE=1 _daily_paper_zsh_run
    return $?
  fi
  case "$1" in
    -h|--help|help)
      _daily_paper_zsh_help
      return 0
      ;;
    search)
      shift; _daily_paper_zsh_search "$@"
      ;;
    download)
      shift; _daily_paper_zsh_download "$@"
      ;;
    cache)
      shift; _daily_paper_zsh_cache "$@"
      ;;
    clear)
      shift; _daily_paper_zsh_clear "$@"
      ;;
    update)
      shift; _daily_paper_zsh_update "$@"
      ;;
    *)
      print -ru2 -- "daily-paper-zsh: unknown subcommand '$1'"
      _daily_paper_zsh_help >&2
      return 1
      ;;
  esac
}

# Search one-off keyword(s) and print results inline (no caching, no state).
_daily_paper_zsh_search() {
  emulate -L zsh
  if (( $# < 1 )); then
    print -ru2 -- "usage: daily-paper search <keyword> [...]"
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
_daily_paper_zsh_cache() {
  emulate -L zsh
  print -r -- "$DAILY_PAPER_CACHE_DIR"
  if [[ -d "$DAILY_PAPER_CACHE_DIR" ]]; then
    command ls -la "$DAILY_PAPER_CACHE_DIR"
  else
    print -r -- "(empty or not yet created)"
  fi
}

# Delete today's cache + state so the next shell refetches.
_daily_paper_zsh_clear() {
  emulate -L zsh
  local today
  today="$(_daily_paper_zsh_today)"
  command rm -f "$DAILY_PAPER_CACHE_DIR/${today}.txt" \
                 "$DAILY_PAPER_CACHE_DIR/last_shown"
  print -r -- "daily-paper-zsh: cleared today's cache for $today"
}

# Pull the latest version of this plugin from its git origin.
# Uses --ff-only so a stale local branch won't silently produce merge
# commits; conflicts are surfaced for the user to resolve manually.
_daily_paper_zsh_update() {
  emulate -L zsh

  if ! (( ${+commands[git]} )); then
    print -ru2 -- "daily-paper-zsh: git not found"
    return 1
  fi

  local plugin_dir="${DAILY_PAPER_PLUGIN_DIR:-${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}/plugins/daily-paper-zsh}"

  if [[ ! -d "$plugin_dir/.git" ]]; then
    print -ru2 -- "daily-paper-zsh: '$plugin_dir' is not a git checkout"
    print -ru2 -- "  set DAILY_PAPER_PLUGIN_DIR in your .zshrc, or install via 'git clone'"
    return 1
  fi

  # Bail if there are no remotes at all (git fetch would no-op and report
  # success, hiding the problem downstream).
  local remote_count
  remote_count="$(command git -C "$plugin_dir" remote 2>/dev/null | command wc -l | command tr -d ' ')"
  if (( remote_count == 0 )); then
    print -ru2 -- "daily-paper-zsh: no git remotes in '$plugin_dir' — nothing to update from"
    print -ru2 -- "     add one with:  git -C \"$plugin_dir\" remote add origin <url>"
    return 1
  fi

  print -r -- "  ↓  fetching in $plugin_dir ..."
  command git -C "$plugin_dir" fetch 2>&1 | command sed 's/^/    /'
  if (( ${pipestatus[1]} != 0 )); then
    print -ru2 -- "  ✗  fetch failed"
    return 1
  fi

  local branch
  branch="$(command git -C "$plugin_dir" symbolic-ref --short HEAD 2>/dev/null)"
  if [[ -z "$branch" ]]; then
    print -r -- "  ⚠  detached HEAD — fetched only, not pulling"
    return 0
  fi

  # No upstream ref for the current branch? We can fetch but not compare.
  if ! command git -C "$plugin_dir" rev-parse --verify --quiet "origin/${branch}" &>/dev/null; then
    print -r -- "  ⚠  no upstream 'origin/${branch}' — fetched only"
    return 0
  fi

  # ahead/behind vs origin/<branch>; dirty = modified-file count.
  local ahead behind dirty
  ahead="$(command git -C "$plugin_dir" rev-list --count "origin/${branch}..HEAD"   2>/dev/null)"
  behind="$(command git -C "$plugin_dir" rev-list --count "HEAD..origin/${branch}" 2>/dev/null)"
  dirty="$(command git -C "$plugin_dir" status --porcelain 2>/dev/null | command wc -l | command tr -d ' ')"

  if (( dirty > 0 )); then
    print -r -- "  ⚠  working tree has $dirty modified file(s); pull may refuse or conflict"
  fi
  if (( ahead > 0 )); then
    print -r -- "  ⚠  branch '$branch' is $ahead commit(s) ahead of origin (--ff-only will refuse)"
  fi

  if (( behind == 0 )); then
    if (( ahead > 0 )); then
      # already warned; ff-only would refuse, so skip the pull
      return 0
    fi
    local cur
    cur="$(command git -C "$plugin_dir" rev-parse --short HEAD 2>/dev/null)"
    [[ -z "$cur" ]] && cur="?"
    print -r -- "  ✓  already up to date (HEAD $cur on $branch)"
    return 0
  fi

  print -r -- "  ↓  pulling --ff-only (behind: $behind) ..."
  command git -C "$plugin_dir" pull --ff-only origin "${branch}" 2>&1 | command sed 's/^/    /'
  if (( ${pipestatus[1]} != 0 )); then
    print -ru2 -- "  ✗  pull failed — inspect with 'cd $plugin_dir && git status'"
    return 1
  fi

  local new_head
  new_head="$(command git -C "$plugin_dir" rev-parse --short HEAD 2>/dev/null)"
  [[ -z "$new_head" ]] && new_head="?"
  print -r -- "  ✓  now at $new_head ($branch)"
  return 0
}

# Download one or more arXiv PDFs to $DAILY_PAPER_DOWNLOAD_DIR
# (default: $HOME/Downloads). Each argument may be a bare id (2401.12345),
# versioned (2401.12345v2), prefixed (arXiv:2401.12345), or a full abs/pdf URL.
#
# Files are written as <id>.pdf. If <id>.pdf already exists it is skipped
# (delete it to force a re-download). Downloads land in <id>.pdf.partial
# first; on success they are renamed atomically.
_daily_paper_zsh_download() {
  emulate -L zsh
  if (( $# < 1 )); then
    print -ru2 -- "usage: daily-paper download <arxiv-id> [...]"
    print -ru2 -- "  example: daily-paper download 2401.12345 2401.67890v2"
    print -ru2 -- "  target dir: \${DAILY_PAPER_DOWNLOAD_DIR:-\$HOME/Downloads}"
    return 1
  fi

  if ! (( ${+commands[curl]} )); then
    print -ru2 -- "daily-paper-zsh: curl not found"
    return 1
  fi

  local target_dir="${DAILY_PAPER_DOWNLOAD_DIR:-$HOME/Downloads}"
  if ! command mkdir -p "$target_dir" 2>/dev/null; then
    print -ru2 -- "daily-paper-zsh: cannot create download directory '$target_dir'"
    return 1
  fi

  local ok=0 skip=0 fail=0
  local arg id pdf_url outfile tmpfile magic size

  for arg in "$@"; do
    if ! id="$(_daily_paper_zsh_extract_arxiv_id "$arg")"; then
      print -ru2 -- "  ✗  cannot parse arxiv id from '$arg'"
      (( fail++ ))
      continue
    fi

    pdf_url="https://arxiv.org/pdf/${id}"
    outfile="${target_dir}/${id}.pdf"
    tmpfile="${outfile}.partial"

    if [[ -e "$outfile" ]]; then
      print -r -- "  ↩  $id already exists at $outfile (skipping; delete to re-download)"
      (( skip++ ))
      continue
    fi

    # Clean up any stale .partial from a previous failed attempt.
    command rm -f "$tmpfile"

    print -r -- "  ↓  $id ..."
    if ! command curl -fsSL -m "$DAILY_PAPER_DOWNLOAD_TIMEOUT" \
                       -o "$tmpfile" "$pdf_url" 2>/dev/null; then
      command rm -f "$tmpfile"
      print -ru2 -- "  ✗  $id download failed"
      (( fail++ ))
      continue
    fi

    # Sanity check: real PDFs start with the %PDF- magic bytes.
    # arxiv returns an HTML "not found" page (with HTTP 200) for bad ids,
    # so a content check is required.
    magic="$(command head -c 5 "$tmpfile" 2>/dev/null)"
    if [[ "$magic" != "%PDF-" ]]; then
      command rm -f "$tmpfile"
      print -ru2 -- "  ✗  $id: downloaded content is not a PDF (arxiv returned an error page?)"
      (( fail++ ))
      continue
    fi

    command mv "$tmpfile" "$outfile"
    size="$(command wc -c < "$outfile" | command awk '{print $1}')"
    print -r -- "  ✓  $id → $outfile ($(( size / 1024 )) KB)"
    (( ok++ ))
  done

  print ""
  print -r -- "  done: ${ok} downloaded, ${skip} skipped, ${fail} failed"
  (( fail == 0 ))
}

# ============================================================================
# No auto-run on plugin load.
#
# Earlier versions fetched + printed today's digest every time the first
# interactive shell of the day opened, which made startup depend on
# network latency and arxiv's API. To keep shell startup instant and
# deterministic, this plugin is now fully manual — run `daily-paper`
# when you want to see the digest. Subsequent invocations on the same
# day short-circuit from the cached `last_shown` state, so re-running
# the command is cheap.
#
# If you really want the old auto-run behavior, you can put this in
# your .zshrc after the plugins=(...) line:
#
#   precmd() { (( _DAILY_PAPER_DID_AUTORUN )) || { _DAILY_PAPER_DID_AUTORUN=1; daily-paper; } }
# ============================================================================
