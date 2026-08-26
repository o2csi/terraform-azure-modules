#!/usr/bin/env bash
set -euo pipefail

# /etc/nftables.conf flushes only this module's table. Ensure that the first
# load and every subsequent boot can safely recreate that table independently
# of the distro nftables.service.
nft list table inet ts_router >/dev/null 2>&1 || nft add table inet ts_router
exec nft -f /etc/nftables.conf
