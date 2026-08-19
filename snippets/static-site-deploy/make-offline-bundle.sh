#!/usr/bin/env bash
set -Eeuo pipefail

# Build a self-contained offline bundle for the install.sh script.
# Requires Docker and curl on the build machine. Docker is used to resolve
# Ubuntu 22.04 package dependencies for the target architecture.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTPUT="${OUTPUT:-}"
ARCH="${ARCH:-amd64}"
APT_MIRROR="${APT_MIRROR:-}"
APT_SECURITY_MIRROR="${APT_SECURITY_MIRROR:-}"
RUNNER_VERSION="${RUNNER_VERSION:-latest}"
RUNNER_BINARY_URL="${RUNNER_BINARY_URL:-}"

die() { echo "[offline-bundle] ERROR: $*" >&2; exit 1; }
log() { echo "[offline-bundle] $*"; }

usage() {
  cat <<'EOF'
Usage:
  ./make-offline-bundle.sh [options]

Options:
  --output FILE             Output .tar.gz file
  --arch amd64|arm64        Target architecture (default: amd64)
  --apt-mirror URL          Optional Ubuntu mirror
  --apt-security-mirror URL Optional security mirror (defaults to --apt-mirror)
  --runner-version VERSION  GitLab Runner version, e.g. v18.2.1, or latest
  --runner-binary-url URL   Override runner binary URL
  -h, --help                Show this help

Example:
  ./make-offline-bundle.sh \
    --arch amd64 \
    --output ./static-site-deploy-ubuntu22-amd64.tar.gz
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --output) OUTPUT="${2:?missing value for --output}"; shift 2 ;;
    --arch) ARCH="${2:?missing value for --arch}"; shift 2 ;;
    --apt-mirror) APT_MIRROR="${2:?missing value for --apt-mirror}"; shift 2 ;;
    --apt-security-mirror) APT_SECURITY_MIRROR="${2:?missing value for --apt-security-mirror}"; shift 2 ;;
    --runner-version) RUNNER_VERSION="${2:?missing value for --runner-version}"; shift 2 ;;
    --runner-binary-url) RUNNER_BINARY_URL="${2:?missing value for --runner-binary-url}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
done

[[ "$ARCH" == "amd64" || "$ARCH" == "arm64" ]] || die "--arch must be amd64 or arm64"
command -v docker >/dev/null || die "docker is required on the bundle build machine"
command -v curl >/dev/null || die "curl is required on the bundle build machine"
[[ -f "$SCRIPT_DIR/install.sh" ]] || die "install.sh must be next to this script"

if [[ -z "$OUTPUT" ]]; then
  OUTPUT="$PWD/static-site-deploy-ubuntu22-${ARCH}.tar.gz"
fi
mkdir -p "$(dirname "$OUTPUT")"
OUTPUT="$(cd "$(dirname "$OUTPUT")" && pwd)/$(basename "$OUTPUT")"

if [[ -z "$APT_SECURITY_MIRROR" ]]; then
  APT_SECURITY_MIRROR="$APT_MIRROR"
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
ROOT="$WORK/static-site-deploy-offline"
mkdir -p "$ROOT/debs"
cp "$SCRIPT_DIR/install.sh" "$ROOT/install.sh"
chmod 0755 "$ROOT/install.sh"

log "Resolving Ubuntu 22.04/${ARCH} packages in a clean container"
docker run --rm \
  --platform "linux/${ARCH}" \
  -e APT_MIRROR="$APT_MIRROR" \
  -e APT_SECURITY_MIRROR="$APT_SECURITY_MIRROR" \
  -v "$ROOT/debs:/out" \
  ubuntu:22.04 \
  bash -Eeuo pipefail -c '
    if [[ -n "${APT_MIRROR}" ]]; then
      archive="${APT_MIRROR%/}"
      security="${APT_SECURITY_MIRROR%/}"
      cat >/etc/apt/sources.list <<EOF
deb ${archive} jammy main restricted universe multiverse
deb ${archive} jammy-updates main restricted universe multiverse
deb ${archive} jammy-backports main restricted universe multiverse
deb ${security} jammy-security main restricted universe multiverse
EOF
    fi

    export DEBIAN_FRONTEND=noninteractive
    apt-get -o Acquire::Retries=3 update
    apt-get install -y --no-install-recommends apt-rdepends ca-certificates

    mapfile -t packages < <(
      apt-rdepends nginx unzip curl ca-certificates 2>/dev/null \
        | awk "/^[^ ]/ {print \$1}" \
        | grep -v "^<" \
        | sort -u
    )

    cd /out
    for pkg in "${packages[@]}"; do
      if apt-cache show "$pkg" >/dev/null 2>&1; then
        apt-get download "$pkg"
      fi
    done
  '

if [[ -z "$RUNNER_BINARY_URL" ]]; then
  if [[ "$RUNNER_VERSION" == "latest" ]]; then
    RUNNER_BINARY_URL="https://s3.dualstack.us-east-1.amazonaws.com/gitlab-runner-downloads/latest/binaries/gitlab-runner-linux-${ARCH}"
  else
    version="$RUNNER_VERSION"
    [[ "$version" == v* ]] || version="v${version}"
    RUNNER_BINARY_URL="https://s3.dualstack.us-east-1.amazonaws.com/gitlab-runner-downloads/${version}/binaries/gitlab-runner-linux-${ARCH}"
  fi
fi

log "Downloading GitLab Runner (${ARCH}, ${RUNNER_VERSION})"
curl -fL --retry 3 --connect-timeout 10 "$RUNNER_BINARY_URL" -o "$ROOT/gitlab-runner"
chmod 0755 "$ROOT/gitlab-runner"

cat >"$ROOT/METADATA" <<EOF
ubuntu=22.04
arch=${ARCH}
runner_version=${RUNNER_VERSION}
runner_url=${RUNNER_BINARY_URL}
built_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF

(
  cd "$ROOT"
  find debs -type f -name '*.deb' -print0 | sort -z | xargs -0 sha256sum
  sha256sum gitlab-runner install.sh METADATA
) >"$ROOT/SHA256SUMS"

mkdir -p "$(dirname "$OUTPUT")"
tar -C "$WORK" -czf "$OUTPUT" static-site-deploy-offline

log "Bundle created: $OUTPUT"
log "Install on target:"
echo "  tar xzf $(basename "$OUTPUT")"
echo "  cd static-site-deploy-offline"
echo "  sudo GITLAB_URL=http://your.gitlab ./install.sh --offline-dir . --site your-site --host 192.168.22.215"
