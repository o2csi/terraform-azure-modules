#!/usr/bin/env python3
"""Install/restore a narrow egress addition without changing router cloud-init."""
import base64
import fcntl
import hashlib
import http.server
import ipaddress
import json
import os
from pathlib import Path
import re
import socket
import subprocess
import sys
import tempfile
import threading
import time
import urllib.request

ROOT = Path('/var/lib/o2csi-egress')
FIREWALL = Path('/etc/nftables.conf')
RUNTIME = Path('/usr/local/libexec/o2csi-egress.py')
CONFIG = ROOT / 'config.json'
SERVICE = Path('/etc/systemd/system/o2csi-egress-health.service')
# No new lateral transit, including other clouds, the LAN, IMDS/WireServer,
# multicast and non-routable ranges. Existing Tailscale forwarding stays intact.
PROTECTED = ('0.0.0.0/8', '10.0.0.0/8', '100.64.0.0/10', '127.0.0.0/8',
             '169.254.0.0/16', '172.16.0.0/12', '192.168.0.0/16',
             '168.63.129.16/32', '224.0.0.0/4', '240.0.0.0/4')


def run(*args, **kwargs):
    return subprocess.run(args, check=True, text=True, capture_output=True,
                          timeout=15, **kwargs)


def atomic(path, content, mode=0o600):
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, name = tempfile.mkstemp(prefix='.' + path.name, dir=path.parent)
    try:
        os.fchmod(fd, mode)
        with os.fdopen(fd, 'w') as out:
            out.write(content)
            out.flush()
            os.fsync(out.fileno())
        os.replace(name, path)
    finally:
        Path(name).unlink(missing_ok=True)


def validate(config):
    if type(config.get('enabled')) is not bool:
        raise ValueError('enabled must be a boolean')
    ipaddress.IPv4Address(config['private_ip'])
    if config['health_port'] != 8081:
        raise ValueError('unexpected health port')
    sources = [ipaddress.IPv4Network(cidr) for cidr in config['sources']]
    if any(c.prefixlen < 24 or not c.subnet_of(ipaddress.IPv4Network('10.16.0.0/12')) for c in sources):
        raise ValueError('sources must be explicit Azure application subnets, /24 or narrower')
    if config['enabled'] and not sources:
        raise ValueError('enabled egress requires sources')


def render(baseline, config, interface):
    validate(config)
    if not re.fullmatch(r'[a-zA-Z0-9_.:-]{1,15}', interface):
        raise ValueError('unsafe interface name')
    if 'o2csi-egress' in baseline:
        raise ValueError('baseline already contains egress configuration')
    input_anchor = 'chain input {\n'
    forward_anchor = 'chain forward {\n'
    # Refuse an unfamiliar base instead of silently opening a different policy.
    if baseline.count(input_anchor) != 1 or baseline.count(forward_anchor) != 1:
        raise ValueError('unrecognized router firewall')
    source = '{ ' + ', '.join(config['sources']) + ' }'
    protected = '{ ' + ', '.join(PROTECTED) + ' }'
    forward_policy = 'type filter hook forward priority filter; policy drop;'
    input_policy = 'type filter hook input priority filter; policy drop;'
    if baseline.count(forward_policy) != 1 or baseline.count(input_policy) != 1:
        raise ValueError('router default-drop policy missing')
    match = f'iifname "{interface}" oifname "{interface}" ip saddr {source}'
    result = baseline.replace(input_policy, input_policy + '\n' +
        '    ip saddr 168.63.129.16 tcp dport 8081 accept comment "o2csi-egress-probe"')
    result = result.replace(forward_policy, forward_policy + '\n' +
        f'    {match} ip daddr {protected} drop comment "o2csi-egress-private-deny"\n' +
        f'    {match} meta l4proto {{ tcp, udp, icmp }} accept comment "o2csi-egress-forward"')
    end = result.rfind('}')
    if end < 0 or result[end + 1:].strip():
        raise ValueError('unexpected firewall trailer')
    result = result[:end] + (
        '  chain egress_snat {\n'
        '    type nat hook postrouting priority srcnat; policy accept;\n'
        f'    {match} ip daddr != {protected} snat ip to {config["private_ip"]} '
        'comment "o2csi-egress-snat"\n'
        '  }\n') + result[end:]
    return result


def rules_digest():
    payload = json.loads(run('nft', '-j', 'list', 'table', 'inet', 'ts_router').stdout)
    def strip(value):
        if isinstance(value, dict):
            return {k: strip(v) for k, v in value.items() if k != 'handle'}
        if isinstance(value, list):
            return [strip(v) for v in value if not isinstance(v, dict) or 'metainfo' not in v]
        return value
    return hashlib.sha256(json.dumps(strip(payload), sort_keys=True).encode()).hexdigest()


def healthy(config):
    if Path('/proc/sys/net/ipv4/ip_forward').read_text().strip() != '1':
        return False
    if rules_digest() != (ROOT / 'rules.sha256').read_text().strip():
        return False
    # Bypass ambient proxies; each router must have working direct TLS egress.
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    for url in ('https://www.microsoft.com/', 'https://www.cloudflare.com/'):
        try:
            with opener.open(url, timeout=3) as response:
                if response.status < 400:
                    return True
        except (OSError, ValueError):
            pass
    return False


def serve():
    config = json.loads(CONFIG.read_text())
    state = {'ok': False, 'observed': 0.0}
    def refresh():
        while True:
            try:
                state['ok'] = healthy(config)
            except Exception:
                state['ok'] = False
            state['observed'] = time.monotonic()
            time.sleep(5)
    class Handler(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            ok = (self.client_address[0] == '168.63.129.16' and self.path == '/healthz'
                  and state['ok'] and time.monotonic() - state['observed'] < 30)
            self.send_response(200 if ok else 503)
            self.end_headers()
            self.wfile.write(b'ok\n' if ok else b'unavailable\n')
        def log_message(self, *args):
            pass
    # Type=notify must not declare readiness until this process owns the port.
    server = http.server.ThreadingHTTPServer((config['private_ip'], config['health_port']), Handler)
    threading.Thread(target=refresh, daemon=True).start()
    address = os.environ['NOTIFY_SOCKET']
    if address.startswith('@'):
        address = '\0' + address[1:]
    with socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM) as notify:
        notify.connect(address)
        notify.sendall(b'READY=1')
    server.serve_forever()


def install(config, source):
    validate(config)
    ROOT.mkdir(mode=0o700, parents=True, exist_ok=True)
    with (ROOT / 'install.lock').open('w') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        current = FIREWALL.read_text()
        baseline_path = ROOT / 'baseline.nft'
        installed_path = ROOT / 'installed.nft'
        baseline = baseline_path.read_text() if baseline_path.exists() else current
        if installed_path.exists() and current not in (installed_path.read_text(), baseline):
            raise RuntimeError('firewall changed outside egress installer; reconcile before retry')
        if not config['enabled'] and not baseline_path.exists():
            print('Egress remains disabled; router unchanged.')
            return
        if config['enabled']:
            route = json.loads(run('ip', '-j', 'route', 'get', '1.1.1.1').stdout)[0]
            content = render(baseline, config, route['dev'])
        else:
            # Recovery must work even when the router has lost Internet routing.
            content = baseline
        atomic(ROOT / 'candidate.nft', content)
        run('nft', '-c', '-f', str(ROOT / 'candidate.nft'))
        if not baseline_path.exists():
            atomic(baseline_path, baseline)
        # Withdraw this router from new flows before replacing its rules.
        subprocess.run(['systemctl', 'stop', 'o2csi-egress-health.service'],
                       check=False, capture_output=True, timeout=30)
        atomic(FIREWALL, content)
        try:
            run('/usr/local/sbin/ts-router-firewall.sh')
        except Exception:
            atomic(FIREWALL, current)
            run('/usr/local/sbin/ts-router-firewall.sh')
            raise
        atomic(installed_path, content)
        if not config['enabled']:
            run('systemctl', 'disable', 'o2csi-egress-health.service')
            print('Egress disabled; original router firewall restored.')
            return
        atomic(CONFIG, json.dumps(config))
        atomic(RUNTIME, source.decode(), 0o700)
        atomic(ROOT / 'rules.sha256', rules_digest())
        atomic(SERVICE, '\n'.join([
            '[Unit]', 'Description=Shared egress readiness',
            'Requires=ts-router-firewall.service',
            'After=network-online.target ts-router-firewall.service',
            'Wants=network-online.target', '[Service]', 'Type=notify',
            'NotifyAccess=main', 'TimeoutStartSec=25',
            f'ExecStart=/usr/bin/python3 {RUNTIME} serve',
            'Restart=on-failure', 'RestartSec=5', 'NoNewPrivileges=yes',
            'ProtectSystem=strict', 'ProtectHome=yes', 'PrivateTmp=yes',
            'CapabilityBoundingSet=CAP_NET_ADMIN', '[Install]',
            'WantedBy=multi-user.target', '']), 0o644)
        run('systemctl', 'daemon-reload')
        run('systemctl', 'enable', '--now', 'o2csi-egress-health.service')
        if not healthy(config):
            raise RuntimeError('egress installed but not ready; evidence retained, probe stays unhealthy')
        run('systemctl', 'is-active', '--quiet', 'o2csi-egress-health.service')
        print('Egress installed; firewall and direct TLS egress verified.')


if __name__ == '__main__':
    if len(sys.argv) == 2 and sys.argv[1] == 'serve':
        serve()
    else:
        install(json.loads(base64.b64decode(sys.argv[1], validate=True)), INSTALLER_SOURCE)
