#!/usr/bin/env bash
set -Eeuo pipefail

# Bootstrap a reusable static-site deployment host on Ubuntu 22.04.
# Installs/configures:
#   - nginx
#   - GitLab Runner (shell executor)
#   - /srv/www/<site> release layout
#   - /usr/local/bin/deploy-static-site atomic deploy helper
#
# Configuration can be supplied as environment variables or CLI flags.
# Environment variables:
#   SITE_NAME, SITE_HOST, LISTEN_PORT, SPA_MODE, KEEP_RELEASES
#   GITLAB_URL, RUNNER_TOKEN, RUNNER_TAG
#   APT_MIRROR, APT_SECURITY_MIRROR
#   RUNNER_VERSION, RUNNER_BINARY_URL
#   OFFLINE_DIR

SITE_NAME="${SITE_NAME:-static-site}"
SITE_HOST="${SITE_HOST:-}"
LISTEN_PORT="${LISTEN_PORT:-80}"
SPA_MODE="${SPA_MODE:-0}"
KEEP_RELEASES="${KEEP_RELEASES:-5}"
GITLAB_URL="${GITLAB_URL:-}"
RUNNER_TOKEN="${RUNNER_TOKEN:-}"
RUNNER_TAG="${RUNNER_TAG:-}"
APT_MIRROR="${APT_MIRROR:-}"
APT_SECURITY_MIRROR="${APT_SECURITY_MIRROR:-}"
RUNNER_VERSION="${RUNNER_VERSION:-latest}"
RUNNER_BINARY_URL="${RUNNER_BINARY_URL:-}"
OFFLINE_DIR="${OFFLINE_DIR:-}"

log()  { printf '\033[1;34m[static-deploy]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[static-deploy] WARN:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[static-deploy] ERROR:\033[0m %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'EOF'
Usage:
  sudo ./install.sh [options]

Options:
  --site NAME              Site name (default: static-site)
  --host HOST              Nginx server_name; defaults to primary host IP
  --port PORT              Listen port (default: 80)
  --spa                     SPA fallback to /index.html
  --keep-releases N         Number of successful releases to keep (default: 5)
  --gitlab-url URL          GitLab instance URL
  --runner-token TOKEN      Runner auth token (glrt-...). Prefer prompt/env over CLI.
  --runner-tag TAG          Tag to use in your .gitlab-ci.yml (set same tag in GitLab UI)
  --apt-mirror URL          Ubuntu archive mirror, e.g. http://mirror.example/ubuntu
  --apt-security-mirror URL Ubuntu security mirror (defaults to --apt-mirror)
  --runner-version VERSION  GitLab Runner version, e.g. v18.2.1, or latest
  --runner-binary-url URL   Override GitLab Runner binary URL
  --offline-dir DIR         Install packages and runner binary from an offline bundle
  -h, --help                Show this help

Examples:
  sudo SITE_NAME=docs SITE_HOST=192.168.22.215 \
    GITLAB_URL=http://gitlab.example.internal RUNNER_TAG=deploy-215 \
    ./install.sh

  sudo APT_MIRROR=http://mirror.example/ubuntu \
    GITLAB_URL=http://gitlab.example.internal \
    ./install.sh --site docs --host 192.168.22.215

  sudo GITLAB_URL=http://gitlab.example.internal \
    ./install.sh --offline-dir ./static-site-deploy-offline
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --site) SITE_NAME="${2:?missing value for --site}"; shift 2 ;;
    --host) SITE_HOST="${2:?missing value for --host}"; shift 2 ;;
    --port) LISTEN_PORT="${2:?missing value for --port}"; shift 2 ;;
    --spa) SPA_MODE=1; shift ;;
    --keep-releases) KEEP_RELEASES="${2:?missing value for --keep-releases}"; shift 2 ;;
    --gitlab-url) GITLAB_URL="${2:?missing value for --gitlab-url}"; shift 2 ;;
    --runner-token) RUNNER_TOKEN="${2:?missing value for --runner-token}"; shift 2 ;;
    --runner-tag) RUNNER_TAG="${2:?missing value for --runner-tag}"; shift 2 ;;
    --apt-mirror) APT_MIRROR="${2:?missing value for --apt-mirror}"; shift 2 ;;
    --apt-security-mirror) APT_SECURITY_MIRROR="${2:?missing value for --apt-security-mirror}"; shift 2 ;;
    --runner-version) RUNNER_VERSION="${2:?missing value for --runner-version}"; shift 2 ;;
    --runner-binary-url) RUNNER_BINARY_URL="${2:?missing value for --runner-binary-url}"; shift 2 ;;
    --offline-dir) OFFLINE_DIR="${2:?missing value for --offline-dir}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
done

[[ "${EUID}" -eq 0 ]] || die "run as root (use sudo)"
[[ -r /etc/os-release ]] || die "/etc/os-release not found"
# shellcheck disable=SC1091
source /etc/os-release
[[ "${ID:-}" == "ubuntu" && "${VERSION_ID:-}" == "22.04" ]] \
  || die "this installer supports Ubuntu 22.04 only; detected ${ID:-unknown} ${VERSION_ID:-unknown}"

case "$(uname -m)" in
  x86_64) RUNNER_ARCH="amd64" ;;
  aarch64|arm64) RUNNER_ARCH="arm64" ;;
  *) die "unsupported architecture: $(uname -m) (supported: amd64, arm64)" ;;
esac

[[ "$SITE_NAME" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] \
  || die "invalid SITE_NAME: use letters, numbers, dot, underscore, hyphen"
[[ "$LISTEN_PORT" =~ ^[0-9]+$ ]] && (( LISTEN_PORT >= 1 && LISTEN_PORT <= 65535 )) \
  || die "LISTEN_PORT must be 1..65535"
[[ "$KEEP_RELEASES" =~ ^[0-9]+$ ]] && (( KEEP_RELEASES >= 1 && KEEP_RELEASES <= 100 )) \
  || die "KEEP_RELEASES must be 1..100"
[[ "$SPA_MODE" == "0" || "$SPA_MODE" == "1" ]] || die "SPA_MODE must be 0 or 1"

if [[ -z "$SITE_HOST" ]]; then
  SITE_HOST="$(hostname -I 2>/dev/null | awk '{print $1}')"
  SITE_HOST="${SITE_HOST:-_}"
fi
[[ ! "$SITE_HOST" =~ [[:space:]\;\{\}] ]] || die "SITE_HOST contains unsafe characters"

if [[ -z "$RUNNER_TAG" ]]; then
  RUNNER_TAG="deploy-${SITE_NAME}"
fi
[[ "$RUNNER_TAG" =~ ^[A-Za-z0-9._:-]+$ ]] || die "invalid RUNNER_TAG"

if [[ -n "$APT_MIRROR" && "$APT_MIRROR" =~ [[:space:]] ]]; then
  die "APT_MIRROR must not contain whitespace"
fi
if [[ -z "$APT_SECURITY_MIRROR" ]]; then
  APT_SECURITY_MIRROR="$APT_MIRROR"
fi
if [[ -n "$APT_SECURITY_MIRROR" && "$APT_SECURITY_MIRROR" =~ [[:space:]] ]]; then
  die "APT_SECURITY_MIRROR must not contain whitespace"
fi

BASE="/srv/www/${SITE_NAME}"
SITES_CFG_DIR="/etc/static-deploy/sites"
SITE_CFG="${SITES_CFG_DIR}/${SITE_NAME}.env"
NGINX_AVAILABLE="/etc/nginx/sites-available/static-deploy-${SITE_NAME}"
NGINX_ENABLED="/etc/nginx/sites-enabled/static-deploy-${SITE_NAME}"

install_os_packages_online() {
  local -a apt_common=(
    -o Acquire::Retries=3
    -o Dpkg::Use-Pty=0
  )

  if [[ -n "$APT_MIRROR" ]]; then
    local tmp_sources
    tmp_sources="$(mktemp)"
    trap 'rm -f "${tmp_sources:-}"' RETURN

    local archive="${APT_MIRROR%/}"
    local security="${APT_SECURITY_MIRROR%/}"
    cat >"$tmp_sources" <<EOF
deb ${archive} jammy main restricted universe multiverse
deb ${archive} jammy-updates main restricted universe multiverse
deb ${archive} jammy-backports main restricted universe multiverse
deb ${security} jammy-security main restricted universe multiverse
EOF

    log "Installing Ubuntu packages via mirror: ${archive}"
    apt-get "${apt_common[@]}" \
      -o "Dir::Etc::sourcelist=${tmp_sources}" \
      -o "Dir::Etc::sourceparts=-" \
      update
    DEBIAN_FRONTEND=noninteractive apt-get "${apt_common[@]}" \
      -o "Dir::Etc::sourcelist=${tmp_sources}" \
      -o "Dir::Etc::sourceparts=-" \
      install -y --no-install-recommends nginx unzip curl ca-certificates
  else
    log "Installing Ubuntu packages via configured system APT sources"
    apt-get "${apt_common[@]}" update
    DEBIAN_FRONTEND=noninteractive apt-get "${apt_common[@]}" \
      install -y --no-install-recommends nginx unzip curl ca-certificates
  fi
}

install_os_packages_offline() {
  local dir="$1"
  [[ -d "$dir/debs" ]] || die "offline bundle missing: $dir/debs"
  shopt -s nullglob
  local debs=("$dir"/debs/*.deb)
  shopt -u nullglob
  (( ${#debs[@]} > 0 )) || die "no .deb files found in $dir/debs"

  log "Installing ${#debs[@]} offline Ubuntu packages"
  set +e
  DEBIAN_FRONTEND=noninteractive dpkg -i "${debs[@]}"
  local rc=$?
  set -e
  if (( rc != 0 )); then
    log "Finishing deferred package configuration"
    DEBIAN_FRONTEND=noninteractive dpkg --configure -a \
      || die "offline package dependency resolution failed; rebuild the bundle for Ubuntu 22.04/${RUNNER_ARCH}"
  fi

  command -v nginx >/dev/null || die "nginx was not installed by offline bundle"
  command -v unzip >/dev/null || die "unzip was not installed by offline bundle"
  command -v curl >/dev/null || die "curl was not installed by offline bundle"
}

if [[ -n "$OFFLINE_DIR" ]]; then
  OFFLINE_DIR="$(readlink -f "$OFFLINE_DIR")"
  [[ -d "$OFFLINE_DIR" ]] || die "OFFLINE_DIR not found: $OFFLINE_DIR"
  if [[ -f "$OFFLINE_DIR/SHA256SUMS" ]]; then
    log "Verifying offline bundle checksums"
    (cd "$OFFLINE_DIR" && sha256sum -c SHA256SUMS)
  fi
  install_os_packages_offline "$OFFLINE_DIR"
else
  install_os_packages_online
fi

install_runner() {
  if command -v gitlab-runner >/dev/null 2>&1; then
    log "Using existing GitLab Runner: $(command -v gitlab-runner)"
  else
    if [[ -n "$OFFLINE_DIR" ]]; then
      [[ -f "$OFFLINE_DIR/gitlab-runner" ]] || die "offline bundle missing gitlab-runner binary"
      log "Installing GitLab Runner binary from offline bundle"
      install -m 0755 "$OFFLINE_DIR/gitlab-runner" /usr/local/bin/gitlab-runner
    else
      if [[ -z "$RUNNER_BINARY_URL" ]]; then
        if [[ "$RUNNER_VERSION" == "latest" ]]; then
          RUNNER_BINARY_URL="https://s3.dualstack.us-east-1.amazonaws.com/gitlab-runner-downloads/latest/binaries/gitlab-runner-linux-${RUNNER_ARCH}"
        else
          local version="$RUNNER_VERSION"
          [[ "$version" == v* ]] || version="v${version}"
          RUNNER_BINARY_URL="https://s3.dualstack.us-east-1.amazonaws.com/gitlab-runner-downloads/${version}/binaries/gitlab-runner-linux-${RUNNER_ARCH}"
        fi
      fi
      log "Installing GitLab Runner binary (${RUNNER_ARCH}, ${RUNNER_VERSION})"
      curl -fL --retry 3 --connect-timeout 10 "$RUNNER_BINARY_URL" \
        -o /usr/local/bin/gitlab-runner
      chmod 0755 /usr/local/bin/gitlab-runner
    fi
  fi

  if ! id gitlab-runner >/dev/null 2>&1; then
    useradd --comment 'GitLab Runner' --create-home --shell /bin/bash gitlab-runner
  fi

  if ! systemctl cat gitlab-runner.service >/dev/null 2>&1; then
    log "Installing GitLab Runner systemd service"
    gitlab-runner install --user=gitlab-runner --working-directory=/home/gitlab-runner
  fi
  gitlab-runner start >/dev/null 2>&1 || systemctl start gitlab-runner
  systemctl enable gitlab-runner >/dev/null 2>&1 || true
}

install_runner

install -d -m 0755 /srv/www
install -d -o gitlab-runner -g www-data -m 2775 "$BASE"
install -d -o gitlab-runner -g www-data -m 2775 "$BASE/releases"
install -d -m 0755 /etc/static-deploy "$SITES_CFG_DIR"

if [[ ! -L "$BASE/current" ]]; then
  log "Creating bootstrap release"
  install -d -o gitlab-runner -g www-data -m 2775 "$BASE/releases/bootstrap"
  cat >"$BASE/releases/bootstrap/index.html" <<EOF
<!doctype html>
<html>
<head><meta charset="utf-8"><title>${SITE_NAME}</title></head>
<body><h1>${SITE_NAME}</h1><p>static deployment host is ready.</p></body>
</html>
EOF
  chown gitlab-runner:www-data "$BASE/releases/bootstrap/index.html"
  ln -s "$BASE/releases/bootstrap" "$BASE/current"
fi

cat >/usr/local/bin/deploy-static-site <<'DEPLOY_EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

die() { echo "[deploy-static-site] ERROR: $*" >&2; exit 1; }
log() { echo "[deploy-static-site] $*"; }

SITE="${1:-}"
ZIP="${2:-}"
RELEASE_ID="${3:-}"

[[ "$SITE" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die "usage: deploy-static-site <site> <site.zip> <release-id>"
[[ "$RELEASE_ID" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die "invalid release id"
[[ -f "$ZIP" ]] || die "artifact not found: $ZIP"

CFG="/etc/static-deploy/sites/${SITE}.env"
[[ -r "$CFG" ]] || die "site config not found: $CFG"
# shellcheck disable=SC1090
source "$CFG"

: "${BASE:?missing BASE in site config}"
: "${HEALTH_URL:?missing HEALTH_URL in site config}"
: "${HEALTH_HOST:?missing HEALTH_HOST in site config}"
: "${KEEP_RELEASES:?missing KEEP_RELEASES in site config}"

[[ "$BASE" == "/srv/www/${SITE}" ]] || die "unsafe BASE in site config"

if unzip -Z1 "$ZIP" | grep -Eq '(^/|(^|/)\.\.(/|$))'; then
  die "zip contains an unsafe absolute or parent path"
fi

RELEASE="$BASE/releases/$RELEASE_ID"
TMP_RELEASE="$BASE/releases/.${RELEASE_ID}.tmp.$$"
CURRENT="$BASE/current"
NEXT_LINK="$BASE/.current-next.$$"
OLD_RELEASE="$(readlink -f "$CURRENT" 2>/dev/null || true)"

cleanup() {
  rm -rf "$TMP_RELEASE"
  rm -f "$NEXT_LINK"
}
trap cleanup EXIT

if [[ -e "$RELEASE" ]]; then
  log "release already exists: $RELEASE"
else
  log "extracting $ZIP -> $RELEASE"
  mkdir -p "$TMP_RELEASE"
  unzip -q "$ZIP" -d "$TMP_RELEASE"
  [[ -f "$TMP_RELEASE/index.html" ]] || die "artifact root must contain index.html"
  chmod -R a+rX "$TMP_RELEASE"
  mv "$TMP_RELEASE" "$RELEASE"
fi

ln -s "$RELEASE" "$NEXT_LINK"
mv -Tf "$NEXT_LINK" "$CURRENT"

log "current -> $RELEASE"
if ! curl -fsS --retry 4 --retry-delay 1 -H "Host: ${HEALTH_HOST}" "$HEALTH_URL" >/dev/null; then
  log "health check failed: $HEALTH_URL"
  if [[ -n "$OLD_RELEASE" && -d "$OLD_RELEASE" ]]; then
    log "rolling back -> $OLD_RELEASE"
    ln -s "$OLD_RELEASE" "$NEXT_LINK"
    mv -Tf "$NEXT_LINK" "$CURRENT"
  fi
  die "deployment rolled back"
fi

log "health check passed"

# Keep the newest N releases. Release IDs are intentionally restricted to safe path names.
mapfile -t releases < <(find "$BASE/releases" -mindepth 1 -maxdepth 1 -type d ! -name '.*' -printf '%T@ %p\n' \
  | sort -nr | cut -d' ' -f2-)
if (( ${#releases[@]} > KEEP_RELEASES )); then
  current_real="$(readlink -f "$CURRENT")"
  for old in "${releases[@]:KEEP_RELEASES}"; do
    [[ "$old" == "$current_real" ]] || rm -rf "$old"
  done
fi

log "deploy successful"
DEPLOY_EOF
chmod 0755 /usr/local/bin/deploy-static-site

# Write shell-safe values; this file contains no secrets.
{
  printf 'BASE=%q\n' "$BASE"
  printf 'HEALTH_URL=%q\n' "http://127.0.0.1:${LISTEN_PORT}/index.html"
  printf 'HEALTH_HOST=%q\n' "$SITE_HOST"
  printf 'KEEP_RELEASES=%q\n' "$KEEP_RELEASES"
} >"$SITE_CFG"
chmod 0644 "$SITE_CFG"

if [[ "$SPA_MODE" == "1" ]]; then
  NGINX_TRY_FILES='try_files $uri $uri/ /index.html;'
else
  NGINX_TRY_FILES='try_files $uri $uri/ =404;'
fi

cat >"$NGINX_AVAILABLE" <<EOF
server {
    listen ${LISTEN_PORT};
    server_name ${SITE_HOST};

    root ${BASE}/current;
    index index.html;

    location / {
        ${NGINX_TRY_FILES}
    }
}
EOF

ln -sfn "$NGINX_AVAILABLE" "$NGINX_ENABLED"
nginx -t
systemctl enable --now nginx
systemctl reload nginx

# Ensure the runner can atomically create releases/current.
chown -R gitlab-runner:www-data "$BASE"
find "$BASE" -type d -exec chmod 2775 {} +
find "$BASE" -type f -exec chmod 0644 {} +

if [[ -n "$GITLAB_URL" && -z "$RUNNER_TOKEN" && -r /dev/tty ]]; then
  printf 'GitLab runner authentication token (glrt-..., Enter to skip registration): ' >/dev/tty
  IFS= read -r -s RUNNER_TOKEN </dev/tty || true
  printf '\n' >/dev/tty
fi

if [[ -n "$RUNNER_TOKEN" && -z "$GITLAB_URL" ]]; then
  die "GITLAB_URL is required when RUNNER_TOKEN is supplied"
fi

if [[ -n "$GITLAB_URL" && -n "$RUNNER_TOKEN" ]]; then
  mkdir -p /etc/gitlab-runner
  if [[ -f /etc/gitlab-runner/config.toml ]] && grep -Fq "$RUNNER_TOKEN" /etc/gitlab-runner/config.toml; then
    log "Runner token is already registered; skipping duplicate registration"
  else
    log "Registering GitLab Runner with shell executor"
    gitlab-runner register \
      --non-interactive \
      --url "$GITLAB_URL" \
      --token "$RUNNER_TOKEN" \
      --executor shell
    chmod 0600 /etc/gitlab-runner/config.toml
    systemctl restart gitlab-runner
    gitlab-runner verify || warn "runner registration completed but verify reported a problem"
  fi
else
  warn "GitLab Runner installed but not registered. Re-run with GITLAB_URL and RUNNER_TOKEN."
fi

HEALTH_HOST_ESCAPED="$SITE_HOST"
log "Checking local Nginx response"
curl -fsS --retry 5 --retry-delay 1 \
  -H "Host: ${HEALTH_HOST_ESCAPED}" \
  "http://127.0.0.1:${LISTEN_PORT}/index.html" >/dev/null \
  || die "nginx health check failed"

cat <<EOF

Static deployment host is ready.

Site:
  name:      ${SITE_NAME}
  root:      ${BASE}/current
  nginx:     ${NGINX_AVAILABLE}
  local URL: http://${SITE_HOST}:${LISTEN_PORT}/
  runner tag expected in CI: ${RUNNER_TAG}

Deploy command used by CI:
  deploy-static-site ${SITE_NAME} site.zip "\$CI_COMMIT_SHA"

GitLab runner settings:
  - create/configure the runner with tag: ${RUNNER_TAG}
  - disable "Run untagged jobs"
  - mark the runner "Protected" for production

Useful checks:
  systemctl status nginx gitlab-runner
  gitlab-runner list
  ls -l ${BASE}/current
  curl -H 'Host: ${SITE_HOST}' http://127.0.0.1:${LISTEN_PORT}/index.html
EOF
