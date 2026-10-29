#!/usr/bin/env python3
"""Protocol selection, dependency and configuration transaction regression tests."""
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import unittest

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('update_fixtures', ROOT / 'tests/test-updates.py')
fixtures = importlib.util.module_from_spec(spec); spec.loader.exec_module(fixtures)


class CombinationTests(unittest.TestCase):
    def setUp(self):
        self.fixture = fixtures.UpdateTests()
        self.fixture.setUp()
        self.addCleanup(self.fixture.doCleanups)
        self.root = self.fixture.root
        project = self.root / 'project'; (project / 'lib').mkdir(parents=True)
        for source in (ROOT / 'lib').iterdir():
            content = source.read_text()
            for prefix in ['/usr/local/bin', '/etc/sing-box', '/etc/systemd/system', '/etc/caddy', '/var/backups/fkgfw', '/var/log/cloudflared.log', '/root/']:
                content = content.replace(prefix, str(self.root) + prefix)
            (project / 'lib' / source.name).write_text(content)
        self.fixture.env['SCRIPT_DIR'] = str(project)
        (self.root / 'var/log').mkdir()
        (self.root / 'sing-box.active').touch(); (self.root / 'sing-box.enabled').touch()
        config = json.loads(self.fixture.original_config)
        config['inbounds'][0]['listen_port'] = 443
        config['inbounds'][0]['tls'] = {'server_name': 'example.com', 'reality': {'private_key': 'kept-key', 'short_id': ['0123']}}
        self.before = config
        self.fixture.config.write_text(json.dumps(config))
        self.fixture.mock('systemctl', '''echo "$*" >> "$TEST_ROOT/events"
action="$1"; shift
for name in "$@"; do
 [[ "$name" = --* ]] && continue
 case "$action" in
  is-active) [ -f "$TEST_ROOT/$name.active" ] || exit 3;;
  is-enabled) [ -f "$TEST_ROOT/$name.enabled" ] || exit 1;;
  enable) touch "$TEST_ROOT/$name.enabled";;
  disable) rm -f "$TEST_ROOT/$name.enabled";;
  stop) rm -f "$TEST_ROOT/$name.active";;
  start|restart)
   if [ "${FAIL_SERVICE:-}" = "$name" ] && jq -e --arg tag "${FAIL_TAG:-hy2-in}" 'any(.inbounds[]; .tag == $tag)' "$TEST_ROOT/etc/sing-box/config.json" >/dev/null; then exit 1; fi
   touch "$TEST_ROOT/$name.active";;
 esac
done''')
        self.overrides = '''
source "$SCRIPT_DIR/lib/installer.sh"
create_singbox_user() { :; }
server_address() { echo 192.0.2.1; }
prompt_port() { echo "$2"; }
fetch_binary() { echo "$1" >> "$TEST_ROOT/downloads"; cp "$TEST_ROOT/usr/local/bin/sing-box" "$2"; }
collect_inbound() {
 echo "$1" >> "$TEST_ROOT/collected"
 case "$1" in
  hy2-in) echo '{"type":"hysteria2","tag":"hy2-in","listen_port":8443,"users":[{"password":"new-password"}]}' ;;
  vmess-in) echo '{"type":"vmess","tag":"vmess-in","listen":"127.0.0.1","listen_port":18443,"users":[{"uuid":"new-vmess"}],"transport":{"type":"ws","path":"/vmess"}}' ;;
  vless-ws-in) echo '{"type":"vless","tag":"vless-ws-in","listen":"127.0.0.1","listen_port":18444,"users":[{"uuid":"new-vless"}],"transport":{"type":"ws","path":"/vless"}}' ;;
 esac
}
export_clients() {
 [ "${FAIL_EXPORT:-0}" = 0 ] || return 1
 jq '[.inbounds[].tag]' "$TEST_ROOT/etc/sing-box/config.json" > "$TEST_ROOT/etc/sing-box/client.json"
}
'''

    def call(self, script, **env):
        return self.fixture.run_shell(self.overrides + '\n' + script, **env)

    def configure(self, tags, **env):
        return self.call("configure_protocols '" + json.dumps(tags) + "'", **env)

    def assert_success(self, result):
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_custom_selection_normalizes_and_rejects_invalid(self):
        result = self.call("normalize_selection '4,1 4'")
        self.assert_success(result)
        self.assertEqual(json.loads(result.stdout), ['vless-in', 'vless-ws-in'])
        for value in ['', '0', '8', '1x', '1;echo']:
            result = self.call('normalize_selection ' + repr(value))
            self.assertNotEqual(result.returncode, 0)

    def test_add_hysteria_preserves_reality_and_skips_auxiliary_downloads(self):
        result = self.configure(['vless-in', 'hy2-in'])
        self.assert_success(result)
        config = json.loads(self.fixture.config.read_text())
        before = dict(self.before['inbounds'][0]); before.pop('sniff')
        self.assertEqual(config['inbounds'][0], before)
        self.assertFalse((self.root / 'downloads').exists())
        self.assertEqual((self.root / 'collected').read_text().strip(), 'hy2-in')
        self.assertNotIn('caddy', (self.root / 'events').read_text())

    def test_add_single_ws_installs_only_needed_services(self):
        result = self.configure(['vless-in', 'vless-ws-in'])
        self.assert_success(result)
        self.assertEqual((self.root / 'downloads').read_text().splitlines(), ['caddy', 'cloudflared'])
        caddy = (self.root / 'etc/caddy/Caddyfile').read_text()
        self.assertIn('handle /vless', caddy); self.assertNotIn('/vmess', caddy)
        self.assertTrue((self.root / 'cloudflared.active').exists())

    def test_remove_last_ws_stops_and_disables_auxiliary_services(self):
        self.assert_success(self.configure(['vless-in', 'vmess-in']))
        (self.root / 'events').write_text('')
        result = self.configure(['vless-in'])
        self.assert_success(result)
        self.assertFalse((self.root / 'cloudflared.active').exists())
        self.assertFalse((self.root / 'caddy.enabled').exists())
        self.assertEqual(json.loads((self.root / 'etc/sing-box/client.json').read_text()), ['vless-in'])

    def test_changing_ws_backends_keeps_current_tunnel(self):
        self.assert_success(self.configure(['vless-in', 'vmess-in']))
        (self.root / 'events').write_text('')
        self.assert_success(self.configure(['vless-in', 'vless-ws-in']))
        events = (self.root / 'events').read_text()
        self.assertNotIn('restart cloudflared', events)
        self.assertNotIn('stop cloudflared', events)
        caddy = (self.root / 'etc/caddy/Caddyfile').read_text()
        self.assertIn('handle /vless', caddy); self.assertNotIn('/vmess', caddy)

    def test_failed_start_restores_configuration_and_running_state(self):
        original = self.fixture.config.read_text()
        result = self.configure(['vless-in', 'hy2-in'], FAIL_SERVICE='sing-box')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.fixture.config.read_text(), original)
        self.assertTrue((self.root / 'sing-box.active').exists())
        self.assertTrue((self.root / 'sing-box.enabled').exists())

    def test_failed_export_restores_configuration(self):
        original = self.fixture.config.read_text()
        result = self.configure(['vless-in', 'hy2-in'], FAIL_EXPORT='1')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.fixture.config.read_text(), original)

    def test_failed_new_ws_removes_new_files_and_restores_old_config(self):
        original = self.fixture.config.read_text()
        result = self.configure(['vless-in', 'vmess-in'], FAIL_SERVICE='caddy', FAIL_TAG='vmess-in')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.fixture.config.read_text(), original)
        self.assertFalse((self.root / 'etc/caddy').exists())
        self.assertFalse((self.root / 'usr/local/bin/cloudflared').exists())
        self.assertFalse((self.root / 'cloudflared.enabled').exists())
        self.assertTrue((self.root / 'sing-box.active').exists())

    def test_shared_tcp_port_rejected_but_tcp_udp_allowed(self):
        config = {'inbounds': [{'type': 'vless', 'listen_port': 443}, {'type': 'hysteria2', 'listen_port': 443}]}
        self.fixture.config.write_text(json.dumps(config))
        self.assert_success(self.call('validate_listeners "$TEST_ROOT/etc/sing-box/config.json" 28080'))
        config['inbounds'][1]['type'] = 'vmess'
        self.fixture.config.write_text(json.dumps(config))
        self.assertNotEqual(self.call('validate_listeners "$TEST_ROOT/etc/sing-box/config.json" 28080').returncode, 0)


if __name__ == '__main__':
    unittest.main(verbosity=2)
