#!/usr/bin/env bash
#
# grant_tcc.sh - Pre-approve Apple Screen Sharing's privacy (TCC) privileges.
#
# ---------------------------------------------------------------------------
# WHY THIS EXISTS
# ---------------------------------------------------------------------------
# Since macOS 12.1, `kickstart` can start Apple's RFB/VNC daemon but it CANNOT
# grant that daemon Screen Recording access. From Apple's own docs
# (support.apple.com/guide/remote-desktop/apd8b1c65bd/mac):
#
#   "In macOS 12.1 or later, Screen Sharing can't be enabled by the kickstart
#    command-line tool. You can use a mobile device management (MDM) solution to
#    enable Remote Management."
#
# So the symptom on a headless CI runner is:
#   * port 5900 opens and the RFB handshake + password auth succeed  -> "it connects"
#   * the framebuffer grab is refused by TCC                          -> black screen
#   * the client renders macOS's own complaint:
#       "Screen recording might be disabled. Screen Sharing or Remote Management
#        must be enabled from System Settings or via MDM."
#
# `tccutil` cannot help either: it can only RESET a grant, never GRANT one.
# There is no command line switch that grants Screen Recording.
#
# The way this is solved in practice (and the way GitHub's own macOS runner
# images do it) is to seed the row directly into TCC.db. GitHub pre-seeds:
#     kTCCServiceScreenCapture | com.apple.screensharing.agent | 0 | 2 | 4 | 1
# and the runner-images maintainers confirmed the hosted images allow runtime
# writes to TCC.db. This script (re)creates that row, plus the two services
# needed for keyboard/mouse control.
#
# Schema note: the `access` table gained columns across macOS 14/15/26, so we
# never use positional VALUES - we build a named-column INSERT from whatever
# `PRAGMA table_info(access)` actually reports.
# ---------------------------------------------------------------------------

set -euo pipefail

readonly TCC_CLIENT="com.apple.screensharing.agent"   # client_type 0 = bundle id
readonly SERVICES=(
  "kTCCServiceScreenCapture"   # read the framebuffer  -> fixes the black screen
  "kTCCServiceAccessibility"   # synthesise input events
  "kTCCServiceListenEvent"     # observe input events
)
readonly AUTH_VALUE=2          # 2 = allowed
readonly AUTH_REASON=4         # matches the row GitHub ships
readonly FLAGS=1

log()  { printf '  %s\n' "$*"; }
warn() { printf '  !! %s\n' "$*" >&2; }

# The system database plus every user home we can find. ARD captures the
# *console* session's framebuffer, so the grant has to exist in the TCC.db of
# whichever account owns that session - not just the account running this script.
collect_dbs() {
  printf '%s\n' "/Library/Application Support/com.apple.TCC/TCC.db"
  printf '%s\n' "$HOME/Library/Application Support/com.apple.TCC/TCC.db"
  local home
  for home in /Users/*; do
    [[ -d "$home/Library/Application Support/com.apple.TCC" ]] &&
      printf '%s\n' "$home/Library/Application Support/com.apple.TCC/TCC.db"
  done | awk '!seen[$0]++'
  return 0
}

# grant_service <db> <service>
grant_service() {
  local db="$1" service="$2"
  local columns values col want

  [[ -f "$db" ]] || return 0

  # Build a named-column INSERT from the live schema so we never guess arity.
  columns="service,client,client_type,auth_value"
  values="'$service','$TCC_CLIENT',0,$AUTH_VALUE"
  for col in auth_reason flags last_modified; do
    case "$col" in
      auth_reason)   want="$AUTH_REASON" ;;
      flags)         want="$FLAGS"      ;;
      last_modified) want="CAST(strftime('%s','now') AS INTEGER)" ;;
    esac
    if sudo sqlite3 "$db" "PRAGMA table_info(access);" | cut -d'|' -f2 | grep -qx "$col"; then
      columns="$columns,$col"
      values="$values,$want"
    fi
  done

  # Deterministic: drop any stale row (including a `denied` one) first, since
  # INSERT OR IGNORE would silently keep a bad grant.
  if sudo sqlite3 "$db" \
      "DELETE FROM access WHERE service='$service' AND client='$TCC_CLIENT';" &&
     sudo sqlite3 "$db" \
      "INSERT INTO access ($columns) VALUES ($values);"; then
    log "granted $service -> $(basename "$(dirname "$(dirname "$db")")")/$(basename "$(dirname "$db")")/TCC.db"
  else
    warn "FAILED to write $service into $db"
    return 1
  fi
}

# macOS 15+ can pop a "bypassing the system private window picker" alert that
# steals focus and wrecks headed UI tests. replayd tracks the reminder in this
# plist; a far-future date suppresses it. Best effort - harmless if ignored.
suppress_replayd_reminder() {
  local plist="$HOME/Library/Group Containers/group.com.apple.replayd/ScreenCaptureApprovals.plist"
  mkdir -p "$(dirname "$plist")" 2>/dev/null || return 0
  for proc in "/System/Library/CoreServices/RemoteManagement/ARDAgent.app" \
              "/System/Library/CoreServices/RemoteManagement/screensharingd.bundle"; do
    defaults write "$plist" "$proc" -date "3024-01-01 00:00:00 +0000" 2>/dev/null || true
  done
  killall cfprefsd 2>/dev/null || true
}

# tccd caches the old (denied) state in memory. Force it to re-read the db.
flush_tccd() {
  sudo killall tccd 2>/dev/null || true
  killall  cfprefsd 2>/dev/null || true
}

check_sip() {
  local status
  status="$(sudo csrutil status 2>&1 || true)"
  if [[ "$status" == *"enabled"* ]]; then
    warn "SIP is ${status}."
    warn "  A SIP-protected TCC.db cannot be written and the grant will NOT take"
    warn "  effect. This is the one thing no script can work around on macOS -"
    warn "  it needs a real MDM enrolment. GitHub's hosted macOS runners have"
    warn "  historically shipped with SIP off; if this fires, switch to a"
    warn "  self-hosted/EC2 Mac or a managed Mac host instead."
  fi
}

echo "==> Pre-approving Screen Sharing privacy permissions (TCC)..."
check_sip

rc=0
while IFS= read -r db; do
  for service in "${SERVICES[@]}"; do
    grant_service "$db" "$service" || rc=1
  done
done < <(collect_dbs)

suppress_replayd_reminder
flush_tccd

if [[ "$rc" -ne 0 ]]; then
  echo "==> TCC seeding incomplete - see errors above." >&2
  exit 1
fi

# Show the resulting rows so a failed run is obvious in the Actions log.
echo "==> Verifying kTCCServiceScreenCapture grants:"
while IFS= read -r db; do
  [[ -f "$db" ]] || continue
  sudo sqlite3 "$db" \
    "SELECT '    ' || client || ' (type ' || client_type || ') auth=' || auth_value
       FROM access
      WHERE service = 'kTCCServiceScreenCapture'
        AND client = '$TCC_CLIENT';" || true
done < <(collect_dbs)
