#!/usr/bin/env python3
"""Unit tests and real nftables forwarding in isolated network namespaces."""
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch, MagicMock

MODULE = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('egress', MODULE / 'files/egress.py')
egress = importlib.util.module_from_spec(spec)
spec.loader.exec_module(egress)
BASE = '''flush table inet ts_router
table inet ts_router {
  chain input {
    type filter hook input priority filter; policy drop;
    iifname "lo" accept
    ct state established,related accept
  }
  chain forward {
    type filter hook forward priority filter; policy drop;
    ct state established,related accept
    iifname "tailscale0" oifname != "tailscale0" accept
    iifname != "tailscale0" oifname "tailscale0" accept
  }
  chain output {
    type filter hook output priority filter; policy accept;
  }
}
'''
CONFIG = {'enabled': True, 'sources': ['10.16.9.0/26'],
          'private_ip': '10.16.0.4', 'health_port': 8081}


class Unit(unittest.TestCase):
    def test_refuse_unfamiliar_firewall(self):
        with self.assertRaises(ValueError):
            egress.render(BASE.replace('policy drop', 'policy accept'), CONFIG, 'eth0')

    def test_reject_broad_or_foreign_source_and_injected_interface(self):
        for cidr in ['0.0.0.0/0', '10.16.0.0/12', '192.168.1.0/24']:
            with self.assertRaises(ValueError):
                egress.render(BASE, dict(CONFIG, sources=[cidr]), 'eth0')
        with self.assertRaises(ValueError):
            egress.render(BASE, CONFIG, 'eth0" accept')

    def test_health_refuses_disabled_forwarding(self):
        with patch.object(Path, 'read_text', return_value='0'):
            self.assertFalse(egress.healthy(CONFIG))

    def test_health_refuses_changed_rules(self):
        with patch.object(Path, 'read_text', side_effect=['1', 'expected']), \
             patch.object(egress, 'rules_digest', return_value='changed'):
            self.assertFalse(egress.healthy(CONFIG))

    def test_health_refuses_no_external_tls(self):
        opener = MagicMock()
        opener.open.side_effect = OSError('unreachable')
        with patch.object(Path, 'read_text', side_effect=['1', 'expected']), \
             patch.object(egress, 'rules_digest', return_value='expected'), \
             patch.object(egress.urllib.request, 'build_opener', return_value=opener):
            self.assertFalse(egress.healthy(CONFIG))

    def test_listener_bind_failure_cannot_notify_readiness(self):
        with patch.object(Path, 'read_text', return_value=json.dumps(CONFIG)), \
             patch.object(egress.http.server, 'ThreadingHTTPServer', side_effect=OSError('address in use')), \
             patch.object(egress.socket, 'socket') as notify:
            with self.assertRaises(OSError):
                egress.serve()
            notify.assert_not_called()

    def test_rollback_does_not_require_a_route(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory); firewall=root/'firewall.nft'
            current=egress.render(BASE,CONFIG,'eth0')
            firewall.write_text(current)
            (root/'baseline.nft').write_text(BASE)
            (root/'installed.nft').write_text(current)
            def command(*args, **kwargs):
                if args[0]=='ip':
                    raise subprocess.CalledProcessError(2,args)
                return subprocess.CompletedProcess(args,0,stdout='')
            with patch.object(egress,'ROOT',root), patch.object(egress,'FIREWALL',firewall), \
                 patch.object(egress,'run',side_effect=command), patch.object(egress.subprocess,'run'):
                egress.install(dict(CONFIG,enabled=False),b'')
            self.assertEqual(firewall.read_text(),BASE)


def network_test():
    # Invoke under `sudo unshare --mount --net --propagation private`.
    # No host interface, firewall, sysctl or route is modified.
    def run(*argv, **kw):
        return subprocess.run(argv, check=True, text=True, capture_output=True,
                              timeout=10, **kw).stdout.strip()
    names = ['egress-router', 'egress-client', 'egress-server']
    listener = None
    with tempfile.TemporaryDirectory(prefix='egress-test-') as directory:
        try:
            run('ip', 'link', 'add', 'br0', 'type', 'bridge')
            run('ip', 'link', 'set', 'br0', 'up')
            for index, name in enumerate(names):
                run('ip', 'netns', 'add', name)
                run('ip', 'link', 'add', f'v{index}', 'type', 'veth', 'peer', 'name', 'eth0', 'netns', name)
                run('ip', 'link', 'set', f'v{index}', 'master', 'br0')
                run('ip', 'link', 'set', f'v{index}', 'up')
                run('ip', '-n', name, 'link', 'set', 'eth0', 'up')
                run('ip', '-n', name, 'link', 'set', 'lo', 'up')
            router, client, server = names
            for ip in ['10.16.9.1/26', '10.16.9.65/26', '10.16.0.4/24', '203.0.113.1/24']:
                run('ip', '-n', router, 'addr', 'add', ip, 'dev', 'eth0')
            run('ip', '-n', client, 'addr', 'add', '10.16.9.10/26', 'dev', 'eth0')
            run('ip', '-n', client, 'route', 'add', 'default', 'via', '10.16.9.1')
            for ip in ['203.0.113.2/24', '10.17.0.2/24']:
                run('ip', '-n', server, 'addr', 'add', ip, 'dev', 'eth0')
            run('ip', '-n', server, 'route', 'add', 'default', 'via', '203.0.113.1')
            run('ip', '-n', router, 'route', 'add', '10.17.0.0/24', 'via', '203.0.113.2')
            run('ip', 'netns', 'exec', router, 'sysctl', '-qw', 'net.ipv4.ip_forward=1')
            run('ip', 'netns', 'exec', router, 'nft', 'add', 'table', 'inet', 'ts_router')
            path = Path(directory) / 'rules.nft'
            path.write_text(egress.render(BASE, CONFIG, 'eth0'))
            for _ in range(2):  # Includes the same reload used at boot.
                run('ip', 'netns', 'exec', router, 'nft', '-c', '-f', str(path))
                run('ip', 'netns', 'exec', router, 'nft', '-f', str(path))
            code = '''import socket
s=socket.socket(); s.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1)
s.bind(('0.0.0.0',18080)); s.listen(); print('ready',flush=True)
while True:
 c,a=s.accept(); c.sendall(a[0].encode()); c.close()
'''
            listener = subprocess.Popen(['ip', 'netns', 'exec', server, 'python3', '-u', '-c', code],
                                        stdout=subprocess.PIPE, text=True)
            self_ready = listener.stdout.readline().strip()
            assert self_ready == 'ready'
            def connect(destination):
                return run('ip', 'netns', 'exec', client, 'python3', '-c',
                    "import socket,sys; s=socket.create_connection((sys.argv[1],18080),1); print(s.recv(100).decode())", destination)
            assert connect('203.0.113.2') == '10.16.0.4', 'SNAT did not use the router private IP'
            try:
                connect('10.17.0.2')
                raise AssertionError('new private transit was allowed')
            except subprocess.CalledProcessError:
                pass
            # A second application subnet is not authorized by the first grant.
            run('ip', '-n', client, 'addr', 'del', '10.16.9.10/26', 'dev', 'eth0')
            run('ip', '-n', client, 'addr', 'add', '10.16.9.70/24', 'dev', 'eth0')
            run('ip', '-n', client, 'route', 'replace', 'default', 'via', '10.16.9.1')
            try:
                connect('203.0.113.2')
                raise AssertionError('unlisted subnet was allowed')
            except subprocess.CalledProcessError:
                pass
            # Restore baseline: a fresh flow must no longer be forwarded.
            run('ip', '-n', client, 'addr', 'del', '10.16.9.70/24', 'dev', 'eth0')
            run('ip', '-n', client, 'addr', 'add', '10.16.9.10/26', 'dev', 'eth0')
            run('ip', '-n', client, 'route', 'replace', 'default', 'via', '10.16.9.1')
            path.write_text(BASE)
            run('ip', 'netns', 'exec', router, 'nft', '-f', str(path))
            try:
                connect('203.0.113.2')
                raise AssertionError('rollback retained egress')
            except subprocess.CalledProcessError:
                pass
            print('PASS: real nftables SNAT, reload, private/source refusals, rollback')
        finally:
            if listener:
                listener.terminate()
                listener.wait(timeout=5)
            for name in reversed(names):
                subprocess.run(['ip', 'netns', 'del', name], capture_output=True)


if __name__ == '__main__':
    if '--network' in sys.argv:
        network_test()
    else:
        unittest.main()
