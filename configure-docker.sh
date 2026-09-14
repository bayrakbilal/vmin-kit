#!/usr/bin/env bash
# configure-docker.sh - reopens the Portainer setup screen.
#   sudo ./configure-docker.sh
#
# If no admin account is created within a few minutes of the container coming
# up, Portainer locks the setup for security ("the Portainer instance timed out
# for security purposes"). The way to unlock it is to restart the container;
# every start produces a NEW setup_token.
#
# The sub-domain and the proxy are created by the install, not here.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$ROOT_DIR/lib/common.sh"
# shellcheck source=/dev/null
source "$ROOT_DIR/lib/steps.sh"
require_root

command -v docker >/dev/null 2>&1 || { err "Docker is not installed."; exit 1; }
docker ps -a --format '{{.Names}}' | grep -x portainer >/dev/null || {
  err "There is no 'portainer' container. Run: sudo ./install.sh"
  exit 1
}

# The main domain comes from the system hostname, which the install sets to
# HOST_PREFIX.MAIN_DOMAIN. config.env is read only for the prefix and the
# Portainer settings.
if [ -f "$ROOT_DIR/config.env" ]; then
  # shellcheck source=/dev/null
  source "$ROOT_DIR/config.env"
fi
if [ -z "${MAIN_DOMAIN:-}" ]; then
  H="$(hostname -f 2>/dev/null || hostname)"
  MAIN_DOMAIN="${H#*.}"
fi
SITE="${DOCKER_PREFIX:-docker}.${MAIN_DOMAIN}"

if portainer_configured; then
  ok "Portainer already has an admin account - no token needed."
  log "Address: https://${SITE}/"
  exit 0
fi

log "Restarting Portainer (this produces a new setup_token)..."
TOKEN="$(portainer_restart_for_token || true)"

echo
if [ -n "$TOKEN" ]; then
  ok "Portainer is ready. Finish the setup NOW - the token is short-lived."
  echo
  echo "    Address     : https://${SITE}/"
  echo "    setup_token : $TOKEN"
  echo
  log "If you miss the window, run this script again."
else
  warn "No setup_token was found in the logs."
  warn "Check the address: https://${SITE}/"
  warn "To inspect the logs: docker logs portainer"
fi
