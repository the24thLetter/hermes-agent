#!/usr/bin/env bash
set -euo pipefail

# Operator continuity wrapper for Xavier's local Hermes Agent fork.
#
# This intentionally wraps scripts/update_local_fork.sh instead of broadening it:
# the helper remains the narrow Git rebase/push primitive, while this script
# handles Hermes state backup, editable reinstall, continuity config, supervised
# gateway restart, dashboard restart, and post-upgrade verification.

DEFAULT_HERMES_HOME="/Users/openclaw/ai-os-migration/configs/hermes"
TARGET_BRANCH="openclaw/local-main"
SYSTEM_LAUNCHDAEMON_PLIST="/Library/LaunchDaemons/ai.hermes.gateway.openclaw.plist"
SYSTEM_LAUNCHDAEMON_LABEL="system/ai.hermes.gateway.openclaw"
GUI_LAUNCHAGENT_LABEL="gui/502/ai.hermes.gateway"
GUI_LAUNCHAGENT_PLIST="/Users/openclaw/Library/LaunchAgents/ai.hermes.gateway.plist"
DASHBOARD_URL="http://127.0.0.1:9119"
DRY_RUN=0
ALLOW_HERMES_HOME_OVERRIDE=0
HERMES_HOME_EXPLICIT=0
MANUAL_GATEWAY_FALLBACK=0
GATEWAY_LOG_OFFSET=0
GATEWAY_MANUAL_FALLBACK_LOG_OFFSET=0
GATEWAY_ERROR_OFFSET=0

usage() {
  cat <<'USAGE'
Usage: scripts/update_local_fork_and_restart.sh [options]

Rebase/push Xavier's local Hermes Agent fork branch, reinstall editable deps,
reassert continuity config, restart the supervised gateway/dashboard, and verify
post-upgrade health.

Options:
  --branch BRANCH                 Fork branch to update (default: openclaw/local-main)
  --hermes-home PATH              Explicit HERMES_HOME override
  --allow-hermes-home-override    Permit a non-canonical HERMES_HOME from env
  --dry-run                       Print the workflow without mutating Git, config, launchd, or processes
  --help, -h                      Show this help

Safety rules encoded here:
  - scripts/update_local_fork.sh remains the only rebase/push helper invoked.
  - Default HERMES_HOME must be /Users/openclaw/ai-os-migration/configs/hermes.
  - The system LaunchDaemon is canonical: system/ai.hermes.gateway.openclaw.
  - The GUI LaunchAgent gui/502/ai.hermes.gateway is not started or repaired.
  - Standalone Kanban daemon is never started; dispatch stays gateway-embedded.
  - Manual gateway run --replace fallback is live but unsupervised only:
    no launchd KeepAlive, no boot/login restart, and no automatic crash recovery.
USAGE
}

log() {
  printf '[update-local-fork-wrapper] %s\n' "$*"
}

warn() {
  printf '[update-local-fork-wrapper] WARNING: %s\n' "$*" >&2
}

die() {
  printf '[update-local-fork-wrapper] ERROR: %s\n' "$*" >&2
  exit 1
}

quote_cmd() {
  local out=""
  local arg
  for arg in "$@"; do
    printf -v arg '%q' "$arg"
    out+=" $arg"
  done
  printf '%s\n' "${out# }"
}

run() {
  if [ "$DRY_RUN" -eq 1 ]; then
    printf '+ %s\n' "$(quote_cmd "$@")"
  else
    "$@"
  fi
}

run_shell() {
  if [ "$DRY_RUN" -eq 1 ]; then
    printf '+ %s\n' "$*"
  else
    bash -lc "$*"
  fi
}

parse_args() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --branch)
        [ "$#" -ge 2 ] || die "--branch requires a value"
        TARGET_BRANCH="$2"
        shift 2
        ;;
      --hermes-home)
        [ "$#" -ge 2 ] || die "--hermes-home requires a value"
        export HERMES_HOME="$2"
        HERMES_HOME_EXPLICIT=1
        shift 2
        ;;
      --allow-hermes-home-override)
        ALLOW_HERMES_HOME_OVERRIDE=1
        shift
        ;;
      --dry-run)
        DRY_RUN=1
        shift
        ;;
      --help|-h)
        usage
        exit 0
        ;;
      *)
        die "unknown option: $1"
        ;;
    esac
  done
}

repo_root() {
  cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd
}

ensure_canonical_hermes_home() {
  export HERMES_HOME="${HERMES_HOME:-$DEFAULT_HERMES_HOME}"
  if [ "$HERMES_HOME" != "$DEFAULT_HERMES_HOME" ] && \
     [ "$HERMES_HOME_EXPLICIT" -ne 1 ] && \
     [ "$ALLOW_HERMES_HOME_OVERRIDE" -ne 1 ]; then
    die "HERMES_HOME is $HERMES_HOME; expected $DEFAULT_HERMES_HOME. Use --hermes-home or --allow-hermes-home-override to override intentionally."
  fi
  if [ "$HERMES_HOME" != "$DEFAULT_HERMES_HOME" ]; then
    warn "using explicit non-canonical HERMES_HOME=$HERMES_HOME"
  else
    log "HERMES_HOME verified: $HERMES_HOME"
  fi
}

ensure_clean_checkout() {
  local status current
  current="$(git branch --show-current)"
  status="$(git status --porcelain)"
  if [ -n "$status" ]; then
    if [ "$DRY_RUN" -eq 1 ]; then
      warn "live run would refuse dirty checkout; dry-run continuing to show planned workflow"
      git status --short >&2 || true
    else
      git status --short >&2
      die "refusing to proceed with dirty worker changes"
    fi
  fi

  if [ "$current" = "$TARGET_BRANCH" ]; then
    log "checkout is already on $TARGET_BRANCH"
    return 0
  fi

  if git show-ref --verify --quiet "refs/heads/$TARGET_BRANCH"; then
    log "checkout can switch from ${current:-detached} to local branch $TARGET_BRANCH"
    run git switch "$TARGET_BRANCH"
  elif git show-ref --verify --quiet "refs/remotes/fork/$TARGET_BRANCH"; then
    log "checkout can create/switch to $TARGET_BRANCH from fork/$TARGET_BRANCH"
    run git switch -c "$TARGET_BRANCH" --track "fork/$TARGET_BRANCH"
  else
    die "branch $TARGET_BRANCH not found locally or at fork/$TARGET_BRANCH"
  fi
}

record_gateway_error_offset() {
  local gateway_log="$HERMES_HOME/logs/gateway.log"
  local manual_log="$HERMES_HOME/logs/gateway.manual-fallback.log"
  local err_log="$HERMES_HOME/logs/gateway.error.log"
  if [ -f "$gateway_log" ]; then
    GATEWAY_LOG_OFFSET="$(wc -c < "$gateway_log" | tr -d '[:space:]')"
  else
    GATEWAY_LOG_OFFSET=0
  fi
  if [ -f "$manual_log" ]; then
    GATEWAY_MANUAL_FALLBACK_LOG_OFFSET="$(wc -c < "$manual_log" | tr -d '[:space:]')"
  else
    GATEWAY_MANUAL_FALLBACK_LOG_OFFSET=0
  fi
  if [ -f "$err_log" ]; then
    GATEWAY_ERROR_OFFSET="$(wc -c < "$err_log" | tr -d '[:space:]')"
  else
    GATEWAY_ERROR_OFFSET=0
  fi
  log "gateway log offsets captured for post-restart dispatcher checks"
  log "gateway.error.log offset captured for post-restart SQLite/WAL check"
}

backup_hermes_state() {
  local label="pre-local-fork-update-$(date +%Y%m%d-%H%M%S)"
  log "taking quick Hermes state backup before rebase (label: $label)"
  run env HERMES_HOME="$HERMES_HOME" ./venv/bin/hermes backup --quick --label "$label"
}

run_git_helper() {
  log "running narrow Git helper for $TARGET_BRANCH"
  run scripts/update_local_fork.sh "$TARGET_BRANCH"
}

reinstall_editable_deps() {
  [ -x ./venv/bin/python ] || die "missing ./venv/bin/python"
  log "reinstalling editable deps"
  if command -v uv >/dev/null 2>&1; then
    run uv pip install --python ./venv/bin/python -e '.[all]'
  elif ./venv/bin/python -m pip --version >/dev/null 2>&1; then
    warn "uv not found; falling back to ./venv/bin/python -m pip"
    run ./venv/bin/python -m pip install -e '.[all]'
  else
    die "neither uv nor venv pip is available; cannot reinstall editable deps"
  fi
}

migrate_and_check_config() {
  log "running Hermes config migrate/check"
  run env HERMES_HOME="$HERMES_HOME" ./venv/bin/hermes config migrate
  run env HERMES_HOME="$HERMES_HOME" ./venv/bin/hermes config check
}

set_scalar_config() {
  log "reasserting scalar continuity settings"
  run env HERMES_HOME="$HERMES_HOME" ./venv/bin/hermes config set agent.max_turns 300
  run env HERMES_HOME="$HERMES_HOME" ./venv/bin/hermes config set delegation.max_iterations 200
  run env HERMES_HOME="$HERMES_HOME" ./venv/bin/hermes config set kanban.dispatch_in_gateway true
  run env HERMES_HOME="$HERMES_HOME" ./venv/bin/hermes config set kanban.max_spawn 4
  run env HERMES_HOME="$HERMES_HOME" ./venv/bin/hermes config set kanban.max_in_progress 4
  run env HERMES_HOME="$HERMES_HOME" ./venv/bin/hermes config set kanban.require_review_before_done true
  run env HERMES_HOME="$HERMES_HOME" ./venv/bin/hermes config set kanban.merge_captain_profile mergecaptain
}

verify_review_agent_skills_yaml() {
  log "verifying kanban.review_agent_skills in YAML without hermes config set"
  env HERMES_HOME="$HERMES_HOME" ./venv/bin/python - <<'PY'
import os
import sys
from pathlib import Path

import yaml

required = {"github/cursor-bugbot-sweep", "github/github-pr-workflow"}
config_path = Path(os.environ["HERMES_HOME"]) / "config.yaml"
try:
    data = yaml.safe_load(config_path.read_text()) or {}
except FileNotFoundError:
    print(f"missing config file: {config_path}", file=sys.stderr)
    sys.exit(1)

skills = (((data.get("kanban") or {}).get("review_agent_skills")) or [])
if not isinstance(skills, list):
    print("kanban.review_agent_skills must be a YAML list", file=sys.stderr)
    sys.exit(1)
missing = sorted(required - set(skills))
if missing:
    print("kanban.review_agent_skills missing required entries: " + ", ".join(missing), file=sys.stderr)
    sys.exit(1)
print("kanban.review_agent_skills contains required review skills")
PY
}

verify_config_values() {
  log "verifying continuity config values"
  env HERMES_HOME="$HERMES_HOME" ./venv/bin/python - <<'PY'
import os
import sys
from pathlib import Path

import yaml

config_path = Path(os.environ["HERMES_HOME"]) / "config.yaml"
data = yaml.safe_load(config_path.read_text()) or {}
checks = {
    ("agent", "max_turns"): 300,
    ("delegation", "max_iterations"): 200,
    ("kanban", "dispatch_in_gateway"): True,
    ("kanban", "max_spawn"): 4,
    ("kanban", "max_in_progress"): 4,
    ("kanban", "require_review_before_done"): True,
    ("kanban", "merge_captain_profile"): "mergecaptain",
}
errors = []
for path, expected in checks.items():
    node = data
    for key in path:
        node = (node or {}).get(key)
    if node != expected:
        errors.append(f"{'.'.join(path)} expected {expected!r}, got {node!r}")
skills = ((data.get("kanban") or {}).get("review_agent_skills")) or []
for required in ("github/cursor-bugbot-sweep", "github/github-pr-workflow"):
    if required not in skills:
        errors.append(f"kanban.review_agent_skills missing {required}")
if errors:
    for error in errors:
        print(error, file=sys.stderr)
    sys.exit(1)
print("continuity config verified")
PY
}

launchdaemon_plist_ok() {
  [ -f "$SYSTEM_LAUNCHDAEMON_PLIST" ] || return 1
  PLIST_PATH="$SYSTEM_LAUNCHDAEMON_PLIST" EXPECTED_HOME="$DEFAULT_HERMES_HOME" ./venv/bin/python - <<'PY'
import os
import plistlib
import sys
from pathlib import Path

plist_path = Path(os.environ["PLIST_PATH"])
expected_home = os.environ["EXPECTED_HOME"]
try:
    data = plistlib.loads(plist_path.read_bytes())
except Exception as exc:
    print(f"invalid LaunchDaemon plist: {exc}", file=sys.stderr)
    sys.exit(1)
errors = []
if data.get("Label") != "ai.hermes.gateway.openclaw":
    errors.append("Label must be ai.hermes.gateway.openclaw")
if data.get("UserName") != "openclaw":
    errors.append("UserName must be openclaw")
env = data.get("EnvironmentVariables") or {}
args = data.get("ProgramArguments") or []
script_text = ""
for arg in args:
    candidate = Path(str(arg))
    if candidate.is_file() and candidate.stat().st_size < 100_000:
        try:
            script_text += "\n" + candidate.read_text(errors="ignore")
        except OSError:
            pass

plist_home = env.get("HERMES_HOME")
wrapper_exports_home = f"HERMES_HOME={expected_home}" in script_text or f"HERMES_HOME=\"{expected_home}\"" in script_text
if plist_home != expected_home and not wrapper_exports_home:
    errors.append("LaunchDaemon must set canonical HERMES_HOME directly or through its ProgramArguments wrapper")
args_joined = " ".join(str(arg) for arg in args)
direct_gateway = "gateway run --replace" in args_joined
wrapper_gateway = "gateway run --replace" in script_text and ("hermes_cli.main" in script_text or "bin/hermes" in script_text or "./venv/bin/hermes" in script_text)
if not direct_gateway and not wrapper_gateway:
    errors.append("ProgramArguments must invoke hermes gateway run --replace directly or through a verified wrapper")
if errors:
    for error in errors:
        print(error, file=sys.stderr)
    sys.exit(1)
print("system LaunchDaemon plist verified")
PY
}

system_launchdaemon_available() {
  launchdaemon_plist_ok || return 1
  launchctl print "$SYSTEM_LAUNCHDAEMON_LABEL" >/dev/null 2>&1
}

verify_gui_launchagent_unloaded() {
  log "verifying GUI LaunchAgent remains unloaded: $GUI_LAUNCHAGENT_LABEL"
  if launchctl print "$GUI_LAUNCHAGENT_LABEL" >/dev/null 2>&1; then
    die "GUI LaunchAgent is loaded; leaving it untouched but failing because canonical supervision is the system LaunchDaemon"
  fi
  log "GUI LaunchAgent is unloaded as required"
}

restart_gateway() {
  log "verifying canonical system LaunchDaemon before gateway restart"
  if system_launchdaemon_available; then
    log "system LaunchDaemon is available; restarting it without touching GUI LaunchAgent"
    run launchctl kickstart -k "$SYSTEM_LAUNCHDAEMON_LABEL"
    MANUAL_GATEWAY_FALLBACK=0
  else
    warn "system LaunchDaemon unavailable; using manual gateway fallback"
    warn "manual fallback is live but unsupervised: no launchd KeepAlive, no boot/login restart, and no automatic crash recovery"
    MANUAL_GATEWAY_FALLBACK=1
    run mkdir -p "$HERMES_HOME/logs"
    run_shell "cd $(printf '%q' "$(pwd)") && env -u HERMES_KANBAN_BOARD HERMES_HOME=$(printf '%q' "$HERMES_HOME") ./venv/bin/hermes gateway run --replace > $(printf '%q' "$HERMES_HOME/logs/gateway.manual-fallback.log") 2>&1 &"
    GATEWAY_MANUAL_FALLBACK_LOG_OFFSET=0
  fi
  verify_gui_launchagent_unloaded
}

verify_no_standalone_kanban_daemon() {
  log "verifying no standalone Kanban daemon process is running"
  local pids
  pids="$(ps -axo pid=,command= | awk '$0 ~ /hermes/ && $0 ~ /kanban[ ]daemon/ {print $1}' || true)"
  if [ -n "$pids" ]; then
    die "standalone Kanban daemon process detected: $pids"
  fi
  log "no standalone Kanban daemon detected; dispatch remains gateway-embedded"
}

restart_dashboard() {
  log "restarting dashboard with canonical HERMES_HOME and no HERMES_KANBAN_BOARD"
  run mkdir -p "$HERMES_HOME/logs"
  if pgrep -f '[h]ermes.*dashboard.*--no-open' >/dev/null 2>&1; then
    run pkill -f '[h]ermes.*dashboard.*--no-open'
  fi
  run_shell "cd $(printf '%q' "$(pwd)") && env -u HERMES_KANBAN_BOARD HERMES_HOME=$(printf '%q' "$HERMES_HOME") ./venv/bin/hermes dashboard --no-open > $(printf '%q' "$HERMES_HOME/logs/dashboard.log") 2>&1 &"
}

launchdaemon_pid() {
  launchctl print "$SYSTEM_LAUNCHDAEMON_LABEL" 2>/dev/null | awk -F'= ' '/^[[:space:]]*pid = / {print $2; exit}' | tr -d '[:space:]'
}

verify_gateway_process() {
  if [ "$MANUAL_GATEWAY_FALLBACK" -eq 1 ]; then
    warn "manual gateway fallback is active; skipping LaunchDaemon PID equivalence check"
    return 0
  fi

  local pids count daemon_pid pid_file_pid user
  daemon_pid="$(launchdaemon_pid)"
  [ -n "$daemon_pid" ] || die "could not determine LaunchDaemon gateway pid"
  pids="$(ps -axo pid=,command= | awk '$0 ~ /hermes_cli[.]main/ && $0 ~ /gateway run --replace/ {print $1}' || true)"
  count="$(printf '%s\n' "$pids" | sed '/^$/d' | wc -l | tr -d '[:space:]')"
  [ "$count" = "1" ] || die "expected exactly one hermes_cli.main gateway process, found $count"
  [ "$pids" = "$daemon_pid" ] || die "gateway process pid $pids does not match LaunchDaemon pid $daemon_pid"

  user="$(ps -o user= -p "$daemon_pid" | tr -d '[:space:]')"
  [ "$user" = "openclaw" ] || die "gateway process user is $user, expected openclaw"

  if [ -f "$HERMES_HOME/gateway.pid" ]; then
    pid_file_pid="$(PID_FILE="$HERMES_HOME/gateway.pid" ./venv/bin/python - <<'PY'
import json
import os
from pathlib import Path
raw = Path(os.environ['PID_FILE']).read_text().strip()
try:
    print(json.loads(raw).get('pid', ''))
except json.JSONDecodeError:
    print(raw)
PY
)"
    [ "$pid_file_pid" = "$daemon_pid" ] || die "gateway.pid points to $pid_file_pid, expected live LaunchDaemon pid $daemon_pid"
  else
    die "missing gateway.pid at $HERMES_HOME/gateway.pid"
  fi

  log "gateway supervisor verified: pid=$daemon_pid user=openclaw HERMES_HOME=$HERMES_HOME"
}

verify_gateway_status() {
  log "verifying gateway status and Telegram connection"
  run env HERMES_HOME="$HERMES_HOME" ./venv/bin/hermes gateway status
  verify_telegram_connection
}

verify_telegram_connection() {
  log "asserting Telegram platform is connected from gateway runtime status"
  if [ "$DRY_RUN" -eq 1 ]; then
    printf '+ HERMES_HOME=%q ./venv/bin/python - <<%s\n' "$HERMES_HOME" "'PY'"
    printf '  # assert gateway_state.json platforms.telegram.state == connected (non-secret)\n'
    return 0
  fi
  env HERMES_HOME="$HERMES_HOME" ./venv/bin/python - <<'PY'
import json
import os
import sys
from pathlib import Path

status_path = Path(os.environ["HERMES_HOME"]) / "gateway_state.json"
try:
    payload = json.loads(status_path.read_text())
except FileNotFoundError:
    print(f"missing gateway runtime status: {status_path}", file=sys.stderr)
    sys.exit(1)
except json.JSONDecodeError as exc:
    print(f"invalid gateway runtime status JSON: {exc}", file=sys.stderr)
    sys.exit(1)

platforms = payload.get("platforms") or {}
telegram = platforms.get("telegram") or {}
state = telegram.get("state")
if state != "connected":
    code = telegram.get("error_code") or "none"
    print(
        "Telegram platform is not connected "
        f"(state={state!r}, error_code={code!r}; message redacted)",
        file=sys.stderr,
    )
    sys.exit(1)
print("Telegram platform connected")
PY
}

verify_kanban_dispatcher_ticks() {
  local gateway_log offset size start
  if [ "$MANUAL_GATEWAY_FALLBACK" -eq 1 ]; then
    gateway_log="$HERMES_HOME/logs/gateway.manual-fallback.log"
    offset="$GATEWAY_MANUAL_FALLBACK_LOG_OFFSET"
  else
    gateway_log="$HERMES_HOME/logs/gateway.log"
    offset="$GATEWAY_LOG_OFFSET"
  fi
  if [ "$DRY_RUN" -eq 1 ]; then
    printf '+ tail -c +%s %q | grep -Eiq %q\n' "$((offset + 1))" "$gateway_log" 'kanban.*dispatch|dispatch.*kanban|dispatcher tick|spawned worker'
    return 0
  fi
  start="$(date +%s)"
  while [ $(( $(date +%s) - start )) -lt 90 ]; do
    if [ -f "$gateway_log" ]; then
      size="$(wc -c < "$gateway_log" | tr -d '[:space:]')"
      if [ "$size" -lt "$offset" ]; then
        offset=0
      fi
      if tail -c +$((offset + 1)) "$gateway_log" | grep -Eiq 'kanban.*dispatch|dispatch.*kanban|dispatcher tick|spawned worker'; then
        log "post-restart embedded Kanban dispatcher activity found in $gateway_log"
        return 0
      fi
    fi
    sleep 3
  done
  die "no post-restart embedded Kanban dispatcher activity found in active gateway log: $gateway_log"
}

verify_kanban_boards_and_stats() {
  log "verifying kanban boards and project stats"
  run env HERMES_HOME="$HERMES_HOME" ./venv/bin/hermes kanban boards list
  run env HERMES_HOME="$HERMES_HOME" ./venv/bin/hermes kanban --board hermes-agent stats --json
  run env HERMES_HOME="$HERMES_HOME" ./venv/bin/hermes kanban --board superoptions stats --json
  run env HERMES_HOME="$HERMES_HOME" ./venv/bin/hermes kanban --board superbettor stats --json
}

verify_dashboard_http() {
  log "verifying dashboard HTTP 200 at $DASHBOARD_URL"
  local code
  if [ "$DRY_RUN" -eq 1 ]; then
    printf '+ curl -fsS -o /dev/null -w %%{http_code} %q\n' "$DASHBOARD_URL"
    return 0
  fi
  code="$(curl -fsS -o /dev/null -w '%{http_code}' "$DASHBOARD_URL")"
  [ "$code" = "200" ] || die "dashboard returned HTTP $code"
  log "dashboard returned HTTP 200"
}

verify_no_new_sqlite_wal_errors() {
  local err_log="$HERMES_HOME/logs/gateway.error.log"
  [ -f "$err_log" ] || { log "gateway.error.log absent; no new SQLite/WAL errors"; return 0; }
  if [ "$DRY_RUN" -eq 1 ]; then
    printf '+ tail -c +%s %q | grep -Eiq %q\n' "$((GATEWAY_ERROR_OFFSET + 1))" "$err_log" 'sqlite|database is locked|wal|disk I/O|malformed'
    return 0
  fi
  if tail -c +$((GATEWAY_ERROR_OFFSET + 1)) "$err_log" | grep -Eiq 'sqlite|database is locked|wal|disk I/O|malformed'; then
    die "new gateway.error.log SQLite/WAL-related errors detected after restart"
  fi
  log "no new gateway.error.log SQLite/WAL errors after restart"
}

post_upgrade_verification() {
  log "running post-upgrade verification"
  if [ "$DRY_RUN" -eq 1 ]; then
    printf '+ launchctl print %q\n' "$SYSTEM_LAUNCHDAEMON_LABEL"
  else
    launchctl print "$SYSTEM_LAUNCHDAEMON_LABEL" >/dev/null || [ "$MANUAL_GATEWAY_FALLBACK" -eq 1 ] || die "system LaunchDaemon not printable"
  fi
  verify_gateway_process
  verify_config_values
  verify_review_agent_skills_yaml
  verify_no_standalone_kanban_daemon
  verify_gateway_status
  verify_kanban_dispatcher_ticks
  verify_kanban_boards_and_stats
  verify_dashboard_http
  verify_no_new_sqlite_wal_errors
  if [ "$MANUAL_GATEWAY_FALLBACK" -eq 1 ]; then
    warn "final state uses manual gateway fallback: live but unsupervised; no launchd KeepAlive, no boot/login restart, no automatic crash recovery"
  fi
}

main() {
  parse_args "$@"
  cd "$(repo_root)"
  ensure_canonical_hermes_home
  record_gateway_error_offset
  ensure_clean_checkout
  backup_hermes_state
  run_git_helper
  reinstall_editable_deps
  migrate_and_check_config
  set_scalar_config
  verify_review_agent_skills_yaml
  restart_gateway
  restart_dashboard
  post_upgrade_verification
  log "local fork update/restart workflow complete"
}

main "$@"
