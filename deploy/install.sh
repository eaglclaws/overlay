#!/usr/bin/env bash
# Install overlay FastAPI app + systemd units (Rocky/RHEL/Fedora-style hosts).
# Run as root. See --help.

set -euo pipefail

DEFAULT_PREFIX=/opt/overlay-api
DEFAULT_USER=overlay-api
DEFAULT_GROUP=overlay-api

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# App root = parent of deploy/ when running from an extracted tree
DEFAULT_APP_ROOT="$(dirname "$SCRIPT_DIR")"

# Set when installing from a tarball; removed on script exit.
EXTRACT_DIR=""

cleanup() {
  if [[ -n "${EXTRACT_DIR:-}" && -d "$EXTRACT_DIR" ]]; then
    rm -rf "$EXTRACT_DIR"
  fi
}

usage() {
  cat <<'EOF'
Usage: install.sh [options] [release.tar.gz]

Installs main.py + requirements.txt into PREFIX, creates a venv, installs
systemd units from deploy/, and enables overlay-api.service.

If release.tar.gz is given, it is extracted and must contain main.py,
requirements.txt, and deploy/ (either at archive root or inside one top-level
directory). If omitted, the directory above this script is used (../).

Options:
  --prefix DIR     Install root (default: /opt/overlay-api)
  --user NAME      Unprivileged user to run the service (default: overlay-api)
  --group NAME     Group (default: overlay-api)
  --with-health-timer
                   Enable overlay-api-health.timer (needs curl)
  --open-firewall  Open TCP 8000 in firewalld if active (firewall-cmd)
  -h, --help       Show this help

Examples:
  sudo ./deploy/install.sh
  sudo ./deploy/install.sh /tmp/overlay-release.tar.gz
  sudo ./deploy/install.sh --prefix /opt/overlay --with-health-timer
EOF
}

log() { printf '%s\n' "$*"; }
die() { log "Error: $*" >&2; exit 1; }

require_root() {
  [[ "$(id -u)" -eq 0 ]] || die "run as root (sudo)"
}

have_cmd() { command -v "$1" >/dev/null 2>&1; }

install_packages() {
  if have_cmd dnf; then
    dnf install -y python3 python3-pip curl >/dev/null
  elif have_cmd yum; then
    yum install -y python3 python3-pip python3-venv curl >/dev/null
  elif have_cmd apt-get; then
    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y python3 python3-venv python3-pip curl >/dev/null
  else
    die "install python3, pip, and curl, then re-run"
  fi
}

ensure_group() {
  local g="$1"
  if ! getent group "$g" >/dev/null; then
    groupadd --system "$g"
    log "Created group: $g"
  fi
}

ensure_user() {
  local u="$1" g="$2" home="$3"
  if ! getent passwd "$u" >/dev/null; then
    useradd --system --gid "$g" --home-dir "$home" --create-home --shell /sbin/nologin "$u"
    log "Created user: $u"
  fi
}

find_app_root_from_extract() {
  local base="$1"
  if [[ -f "$base/main.py" && -f "$base/requirements.txt" && -d "$base/deploy" ]]; then
    printf '%s' "$base"
    return 0
  fi
  local d
  for d in "$base"/*; do
    [[ -d "$d" ]] || continue
    if [[ -f "$d/main.py" && -f "$d/requirements.txt" && -d "$d/deploy" ]]; then
      printf '%s' "$d"
      return 0
    fi
  done
  return 1
}

resolve_app_root() {
  local tarball="${1:-}"
  if [[ -z "$tarball" ]]; then
    [[ -f "$DEFAULT_APP_ROOT/main.py" ]] || die "missing $DEFAULT_APP_ROOT/main.py (wrong cwd or use a tarball)"
    [[ -f "$DEFAULT_APP_ROOT/requirements.txt" ]] || die "missing requirements.txt"
    [[ -d "$DEFAULT_APP_ROOT/deploy" ]] || die "missing deploy/"
    EXTRACT_DIR=""
    printf '%s' "$DEFAULT_APP_ROOT"
    return 0
  fi
  [[ -f "$tarball" ]] || die "not a file: $tarball"
  EXTRACT_DIR="$(mktemp -d)"
  case "$tarball" in
    *.tar.gz|*.tgz) tar -xzf "$tarball" -C "$EXTRACT_DIR" ;;
    *.tar.bz2|*.tbz2) tar -xjf "$tarball" -C "$EXTRACT_DIR" ;;
    *.tar.xz|*.txz) tar -xJf "$tarball" -C "$EXTRACT_DIR" ;;
    *) die "unsupported archive (use .tar.gz, .tar.bz2, or .tar.xz)" ;;
  esac
  local root
  root="$(find_app_root_from_extract "$EXTRACT_DIR")" || die "could not find main.py, requirements.txt, and deploy/ in $tarball"
  printf '%s' "$root"
}

render_unit() {
  local src="$1"
  # Must match paths in deploy/*.service (placeholder before install)
  sed \
    -e "s#/opt/overlay-api#$INSTALL_PREFIX#g" \
    -e "s/^User=.*/User=$RUN_USER/" \
    -e "s/^Group=.*/Group=$RUN_GROUP/" \
    "$src"
}

main() {
  require_root
  trap cleanup EXIT

  local INSTALL_PREFIX="$DEFAULT_PREFIX"
  local RUN_USER="$DEFAULT_USER"
  local RUN_GROUP="$DEFAULT_GROUP"
  local WITH_HEALTH=0
  local OPEN_FW=0
  local tarball=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --prefix) INSTALL_PREFIX="${2:-}"; shift 2 || die "--prefix needs a value";;
      --user) RUN_USER="${2:-}"; shift 2 || die "--user needs a value";;
      --group) RUN_GROUP="${2:-}"; shift 2 || die "--group needs a value";;
      --with-health-timer) WITH_HEALTH=1; shift;;
      --open-firewall) OPEN_FW=1; shift;;
      -h|--help) usage; exit 0;;
      -*)
        die "unknown option: $1 (try --help)"
        ;;
      *)
        [[ -z "$tarball" ]] || die "unexpected extra argument: $1"
        tarball="$1"
        shift
        ;;
    esac
  done

  [[ -n "$INSTALL_PREFIX" ]] || die "empty --prefix"

  local APP_ROOT
  APP_ROOT="$(resolve_app_root "$tarball")"

  [[ -f "$APP_ROOT/deploy/overlay-api.service" ]] || die "missing deploy/overlay-api.service in app tree"

  log "Installing from: $APP_ROOT"
  log "Install prefix:  $INSTALL_PREFIX"
  log "Service user:    $RUN_USER"

  install_packages

  ensure_group "$RUN_GROUP"
  ensure_user "$RUN_USER" "$RUN_GROUP" "$INSTALL_PREFIX"

  install -d -m 0755 -o "$RUN_USER" -g "$RUN_GROUP" "$INSTALL_PREFIX"

  install -m 0644 -o "$RUN_USER" -g "$RUN_GROUP" "$APP_ROOT/main.py" "$INSTALL_PREFIX/main.py"
  install -m 0644 -o "$RUN_USER" -g "$RUN_GROUP" "$APP_ROOT/requirements.txt" "$INSTALL_PREFIX/requirements.txt"

  log "Creating venv and installing Python dependencies..."
  if [[ -d "$INSTALL_PREFIX/.venv" ]]; then
    rm -rf "$INSTALL_PREFIX/.venv"
  fi
  sudo -u "$RUN_USER" python3 -m venv "$INSTALL_PREFIX/.venv"
  sudo -u "$RUN_USER" "$INSTALL_PREFIX/.venv/bin/pip" install --upgrade pip wheel -q
  sudo -u "$RUN_USER" "$INSTALL_PREFIX/.venv/bin/pip" install -r "$INSTALL_PREFIX/requirements.txt" -q

  log "Installing systemd units..."
  render_unit "$APP_ROOT/deploy/overlay-api.service" >/etc/systemd/system/overlay-api.service
  if [[ "$WITH_HEALTH" -eq 1 ]]; then
    render_unit "$APP_ROOT/deploy/overlay-api-health.service" >/etc/systemd/system/overlay-api-health.service
    install -m 0644 "$APP_ROOT/deploy/overlay-api-health.timer" /etc/systemd/system/overlay-api-health.timer
  fi

  systemctl daemon-reload
  systemctl enable overlay-api.service
  systemctl restart overlay-api.service

  if [[ "$WITH_HEALTH" -eq 1 ]]; then
    systemctl enable overlay-api-health.timer
    systemctl start overlay-api-health.timer
    log "Health timer enabled (overlay-api-health.timer)."
  fi

  if [[ "$OPEN_FW" -eq 1 ]] && have_cmd firewall-cmd; then
    if firewall-cmd --state >/dev/null 2>&1; then
      firewall-cmd --permanent --add-port=8000/tcp
      firewall-cmd --reload
      log "Opened TCP 8000 in firewalld."
    else
      log "firewalld not running; skipped --open-firewall."
    fi
  fi

  log "Done. Check status: systemctl status overlay-api.service"
  log "Logs: journalctl -u overlay-api.service -f"
}

main "$@"
