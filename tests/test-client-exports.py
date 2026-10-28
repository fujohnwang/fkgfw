#!/usr/bin/env python3
"""Check YAML semantics, client export permissions and failed export handling."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

import yaml

ROOT = Path(__file__).resolve().parents[1]


class ClientExportTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='fkgfw-client-export-')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.configs = self.root / 'etc/sing-box'; self.configs.mkdir(parents=True)
        (self.configs / 'config.json').write_text('{"inbounds":[{"tag":"hy2-in"}]}')
        self.client = {'outbounds': [{'type': 'hysteria2', 'tag': 'sing-box-hy2', 'server': '2001:db8::1',
            'server_port': 8443, 'password': '00123:# "secret"\\\n中文', 'tls': {'server_name': 'example.com', 'insecure': True}}]}
        self.fixture = self.root / 'client-fixture.json'; self.fixture.write_text(json.dumps(self.client))
        self.library = self.root / 'installer.sh'
        self.library.write_text((ROOT / 'lib/installer.sh').read_text().replace('/etc/sing-box', str(self.configs)))
        self.env = dict(os.environ, SCRIPT_DIR=str(ROOT), EXPORT_TEST_LIBRARY=str(self.library), EXPORT_TEST_CLIENT=str(self.fixture))

    def run_shell(self, command):
        setup = '''source "$EXPORT_TEST_LIBRARY"
render_client_config() { cat "$EXPORT_TEST_CLIENT"; }
server_address() { printf '%s\\n' '2001:db8::1'; }
'''
        return subprocess.run(['bash', '-c', setup + command], env=self.env, text=True, capture_output=True)

    def test_yaml_roundtrip_preserves_nested_data_and_scalar_types(self):
        data = {'strings': ['0123456789abcdef', '00123', 'on', 'off', 'true', 'null', '1e3', '2026-10-28',
                            '2001:db8::1', '/ws: # "quoted"', 'line1\nline2\t\\', '节点😀', '\x85\u2028\u2029',
                            ''.join(chr(n) for n in range(0xA0))],
                'flags': [True, False, None, 7890, -1, 1.25], 'empty': [{}, [], ''],
                'nested': {'true': {'0123': ['value', {'Host': 'example.com'}]}}}
        result = subprocess.run(['jq', '-r', '-f', str(ROOT / 'lib/yaml.jq')], input=json.dumps(data), text=True, capture_output=True, check=True)
        self.assertFalse(result.stdout.lstrip().startswith('{'))
        self.assertEqual(yaml.safe_load(result.stdout), data)

    def test_export_and_display_include_matching_private_yaml(self):
        result = self.run_shell('show_configuration')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        clash = json.loads((self.configs / 'clash.json').read_text())
        exported = self.configs / 'clash.yaml'
        self.assertEqual(yaml.safe_load(exported.read_text()), clash)
        self.assertEqual(clash['proxies'][0]['password'], self.client['outbounds'][0]['password'])
        self.assertEqual(exported.stat().st_mode & 0o777, 0o600)
        self.assertIn('Clash Meta / Mihomo 客户端配置（YAML', result.stdout)
        self.assertIn(exported.read_text().strip(), result.stdout)
        self.assertEqual(list(self.configs.glob('.export.*')), [])

    def test_yaml_failure_preserves_all_existing_exports(self):
        names = ['client.json', 'clash.json', 'clash.yaml']
        for name in names: (self.configs / name).write_text('previous-' + name)
        mock = self.root / 'mock'; mock.mkdir()
        jq = mock / 'jq'
        jq.write_text('''#!/bin/bash
for arg in "$@"; do [[ "$arg" != */yaml.jq ]] || exit 42; done
exec "$EXPORT_TEST_JQ" "$@"
'''); jq.chmod(0o755)
        self.env.update(EXPORT_TEST_JQ=shutil.which('jq'), PATH=str(mock) + ':' + os.environ['PATH'])
        result = self.run_shell('export_clients')
        self.assertNotEqual(result.returncode, 0)
        for name in names: self.assertEqual((self.configs / name).read_text(), 'previous-' + name)
        self.assertEqual(list(self.configs.glob('.export.*')), [])


if __name__ == '__main__':
    unittest.main(verbosity=2)
