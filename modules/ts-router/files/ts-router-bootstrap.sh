#!/usr/bin/env bash
set -euo pipefail

status_file=/var/lib/ts-router/status
runtime_dir=/run/ts-router
step=initializing
success=false
curl_config=
auth_key_file=
key_tmp=
list_tmp=
last_failure=initializing
cleanup_failed=0
install_only=false

if [ "${1:-}" = --install-packages ]; then
  install_only=true
fi

# shellcheck disable=SC2317 # Invoked by the EXIT trap below.
finish() {
  local rc=$?
  unset token secret || cleanup_failed=1
  [ -z "$curl_config" ] || rm -f "$curl_config" || cleanup_failed=1
  [ -z "$auth_key_file" ] || rm -f "$auth_key_file" || cleanup_failed=1
  [ -z "$key_tmp" ] || rm -f "$key_tmp" || cleanup_failed=1
  [ -z "$list_tmp" ] || rm -f "$list_tmp" || cleanup_failed=1
  if [ "$cleanup_failed" -ne 0 ]; then
    rc=1
  fi
  if [ "$install_only" = true ]; then
    exit "$rc"
  fi
  if [ "$step" != retry-exhausted ]; then
    last_failure=$step
  fi
  if [ "$cleanup_failed" -ne 0 ]; then
    last_failure="${last_failure}; cleanup"
  fi
  if [ "$rc" -eq 0 ] && [ "$success" = true ]; then
    if ! publish_status ok; then
      step=status-publish
      last_failure=$step
      publish_status "failed: ${step} (${last_failure})" || true
      rc=1
    fi
  else
    publish_status "failed: ${step} (${last_failure})" || true
  fi
  exit "$rc"
}

# Install traps before creating directories or sourcing caller-derived settings.
trap 'finish' EXIT
trap 'exit 1' HUP INT TERM

publish_status() {
  local message=$1
  local status_tmp

  install -d -m 0700 "${status_file%/*}"
  status_tmp=$(mktemp "${status_file%/*}/.status.XXXXXX") || return 1
  if ! printf '%s\n' "$message" >"$status_tmp"; then
    rm -f "$status_tmp" || true
    return 1
  fi
  if ! mv -f "$status_tmp" "$status_file"; then
    rm -f "$status_tmp" || true
    return 1
  fi
}

if [ "$install_only" = false ]; then
  install -d -m 0700 /var/lib/ts-router "$runtime_dir"
  publish_status initializing
fi

# Values are generated from validated Terraform inputs; do not accept caller data here.
# shellcheck disable=SC1091
source /etc/ts-router/bootstrap.env

curl_bounded() {
  curl --connect-timeout 10 --max-time 30 --fail --silent --show-error "$@"
}

apt_bounded() {
  timeout 600 apt-get -o Acquire::http::Timeout=30 -o Acquire::https::Timeout=30 "$@"
}

package_is_installed() {
  local package_name=$1
  local expected_version=${2:-}

  dpkg-query -W -f='${Status}' "$package_name" 2>/dev/null | grep -qx 'install ok installed' || return 1
  [ -z "$expected_version" ] || [ "$(dpkg-query -W -f='${Version}' "$package_name")" = "$expected_version" ]
}

packages_are_installed() {
  package_is_installed nftables &&
    package_is_installed unbound &&
    package_is_installed dnsutils &&
    package_is_installed tailscale "$TAILSCALE_VERSION"
}

install_packages() {
  local ubuntu_packages=()
  local tailscale_package=

  # A healthy router must reboot offline without refreshing APT metadata.
  package_is_installed nftables || ubuntu_packages+=(nftables)
  package_is_installed unbound || ubuntu_packages+=(unbound)
  package_is_installed dnsutils || ubuntu_packages+=(dnsutils)
  if ! package_is_installed tailscale "$TAILSCALE_VERSION"; then
    if [ -n "$TAILSCALE_VERSION" ]; then
      tailscale_package="tailscale=$TAILSCALE_VERSION"
    else
      tailscale_package=tailscale
    fi
  fi
  [ "${#ubuntu_packages[@]}" -eq 0 ] && [ -z "$tailscale_package" ] && return 0

  step=tailscale-repository-key
  install -d -m 0755 /usr/share/keyrings
  key_tmp=$(mktemp /usr/share/keyrings/.tailscale-archive-keyring.XXXXXX)
  curl_bounded --location \
    --output "$key_tmp" \
    https://pkgs.tailscale.com/stable/ubuntu/noble.noarmor.gpg
  chmod 0644 "$key_tmp"
  mv -f "$key_tmp" /usr/share/keyrings/tailscale-archive-keyring.gpg

  step=tailscale-repository-list
  install -d -m 0755 /etc/apt/sources.list.d
  list_tmp=$(mktemp /etc/apt/sources.list.d/.tailscale.XXXXXX)
  curl_bounded --location \
    --output "$list_tmp" \
    https://pkgs.tailscale.com/stable/ubuntu/noble.tailscale-keyring.list
  chmod 0644 "$list_tmp"
  mv -f "$list_tmp" /etc/apt/sources.list.d/tailscale.list

  step=apt-update
  apt_bounded update --error-on=any

  if [ "${#ubuntu_packages[@]}" -gt 0 ]; then
    step=ubuntu-package-install
    apt_bounded install --yes "${ubuntu_packages[@]}"
  fi

  if [ -n "$tailscale_package" ]; then
    step=tailscale-package-install
    if [ -n "$TAILSCALE_VERSION" ]; then
      apt_bounded install --yes --allow-downgrades "$tailscale_package"
    else
      apt_bounded install --yes "$tailscale_package"
    fi
  fi

  packages_are_installed
}

apply_preferences() {
  step=tailscale-preferences
  tailscale set \
    --advertise-routes="$ADVERTISE_ROUTES" \
    --accept-routes="$ACCEPT_ROUTES" \
    --accept-dns=false \
    --hostname="$HOSTNAME"
}

dns_answer_is_noerror() {
  local fqdn=$1
  local output

  if ! output=$(dig +time=3 +tries=1 "@$ROUTER_PRIVATE_IP" "$fqdn"); then
    return 1
  fi
  python3 /dev/fd/3 3<<'PY' <<<"$output"
import re
import sys

output = sys.stdin.read()
answer = re.search(r"^;; ANSWER SECTION:\n(.*?)(?=^;; |\Z)", output, re.MULTILINE | re.DOTALL)
raise SystemExit(0 if re.search(r"\bstatus: NOERROR\b", output) and answer and any(line.strip() and not line.startswith(";") for line in answer.group(1).splitlines()) else 1)
PY
}

health_check() {
  local chain_dump

  step=ip-forwarding-health
  [ "$(sysctl -n net.ipv4.ip_forward)" = 1 ]
  step=nftables-forward-health
  chain_dump=$(nft list chain inet ts_router forward)
  grep -Fq 'iifname "tailscale0" oifname != "tailscale0" accept' <<<"$chain_dump"
  grep -Fq 'iifname != "tailscale0" oifname "tailscale0" accept' <<<"$chain_dump"
  step=nftables-input-health
  chain_dump=$(nft list chain inet ts_router input)
  grep -Fq 'udp dport 53 accept' <<<"$chain_dump"
  grep -Fq 'tcp dport 53 accept' <<<"$chain_dump"
  step=tailscale-backend-health
  tailscale status --json | python3 -c 'import json, sys; raise SystemExit(0 if json.load(sys.stdin).get("BackendState") == "Running" else 1)'
  step=unbound-dns-health
  dns_answer_is_noerror "$HEALTH_CHECK_FQDN"
  if [ -n "$HEALTH_CHECK_PRIVATE_FQDN" ]; then
    step=unbound-private-dns-health
    dns_answer_is_noerror "$HEALTH_CHECK_PRIVATE_FQDN"
  fi
  step=tailscale-netfilter-health
  if nft list chain ip nat ts-postrouting >/dev/null 2>&1; then
    return 0
  elif nft list chain inet nat ts-postrouting >/dev/null 2>&1; then
    return 0
  else
    nft list chain ip6 nat ts-postrouting >/dev/null 2>&1
  fi
}

if [ "$install_only" = true ]; then
  install_packages
  exit 0
fi

step=package-install
timeout "$INSTALL_DEADLINE_SECONDS" "$0" --install-packages

# nftables is now installed. The dedicated unit owns this table on every boot
# and must be active before Unbound or tailscaled are started.
step=firewall-service
if systemctl cat nftables.service >/dev/null 2>&1; then
  systemctl disable --now nftables.service
fi
systemctl enable --now ts-router-firewall.service
systemctl is-active --quiet ts-router-firewall.service

step=forwarder-services
sysctl -p /etc/sysctl.d/99-tailscale.conf
systemctl enable --now unbound

step=tailscaled
systemctl enable --now tailscaled

step=tailscale-status
if tailscale status --json | python3 -c 'import json, sys; raise SystemExit(0 if json.load(sys.stdin).get("BackendState") == "Running" else 1)'; then
  apply_preferences
  health_check
  success=true
  exit 0
fi

for ((attempt = 1; attempt <= MAX_ATTEMPTS; attempt++)); do
  step=imds-token
  if ! token="$(curl_bounded --noproxy '*' -H Metadata:true \
    "http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=https%3A%2F%2Fvault.azure.net&client_id=$IDENTITY_CLIENT_ID" \
    | python3 -c 'import json, sys; print(json.load(sys.stdin)["access_token"])')" || [ -z "${token:-}" ]; then
    last_failure=$step
    [ "$attempt" -eq "$MAX_ATTEMPTS" ] || sleep "$RETRY_SECONDS"
    continue
  fi

  step=key-vault-secret
  umask 077
  curl_config=$(mktemp "$runtime_dir/curl.XXXXXX")
  printf '%s\n' 'header = "Authorization: Bearer '"$token"'"' >"$curl_config"
  if ! secret="$(curl_bounded --config "$curl_config" "$KEY_VAULT_SECRET_ENDPOINT?api-version=7.4" \
    | python3 -c 'import json, sys; print(json.load(sys.stdin)["value"])')" || [ -z "${secret:-}" ]; then
    last_failure=$step
  fi
  rm -f "$curl_config"
  curl_config=
  unset token
  if [ -z "${secret:-}" ]; then
    [ "$attempt" -eq "$MAX_ATTEMPTS" ] || sleep "$RETRY_SECONDS"
    continue
  fi

  step=tailscale-auth-key
  auth_key_file=$(mktemp "$runtime_dir/auth-key.XXXXXX")
  chmod 0600 "$auth_key_file"
  if ! printf '%s' "$secret" | TAILSCALE_EPHEMERAL="$TAILSCALE_EPHEMERAL" TAILSCALE_PREAUTHORIZED="$TAILSCALE_PREAUTHORIZED" python3 -c '
import os
import sys
from urllib.parse import parse_qsl, urlencode

base, _, query = sys.stdin.read().partition("?")
parameters = [
    (key, value)
    for key, value in parse_qsl(query, keep_blank_values=True)
    if key not in {"ephemeral", "preauthorized"}
]
parameters.extend((
    ("ephemeral", os.environ["TAILSCALE_EPHEMERAL"]),
    ("preauthorized", os.environ["TAILSCALE_PREAUTHORIZED"]),
))
print(f"{base}?{urlencode(parameters)}")
' >"$auth_key_file"; then
    unset secret
    last_failure=$step
    rm -f "$auth_key_file"
    auth_key_file=
    [ "$attempt" -eq "$MAX_ATTEMPTS" ] || sleep "$RETRY_SECONDS"
    continue
  fi
  unset secret

  step=tailscale-up
  if tailscale up \
    --timeout="${TAILSCALE_TIMEOUT_SECONDS}s" \
    --auth-key="file:$auth_key_file" \
    --advertise-routes="$ADVERTISE_ROUTES" \
    --accept-routes="$ACCEPT_ROUTES" \
    --accept-dns=false \
    --advertise-tags="$ADVERTISE_TAGS" \
    --hostname="$HOSTNAME"; then
    rm -f "$auth_key_file"
    auth_key_file=
    apply_preferences
    health_check
    success=true
    exit 0
  fi

  last_failure=$step
  rm -f "$auth_key_file"
  auth_key_file=
  [ "$attempt" -eq "$MAX_ATTEMPTS" ] || sleep "$RETRY_SECONDS"
done

step=retry-exhausted
exit 1
