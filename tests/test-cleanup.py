#!/usr/bin/env python3
"""Cleanup regression tests using only temporary files, procfs and services."""
import contextlib
import importlib.util
import io
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('fkgfw_cleanup', ROOT / 'lib/cleanup.py')
cleanup = importlib.util.module_from_spec(spec); sys.modules[spec.name] = cleanup; spec.loader.exec_module(cleanup)


class CleanupTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='fkgfw-cleanup-')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        (self.root / 'proc').mkdir()
        self.states = {}; self.events = []; self.signals = []
        self.overrides = {}; self.fail_stop = False; self.append_log = False
        self.cleaner = cleanup.Cleaner(self.root, self.root / 'proc', self.systemctl, self.terminate)

    def put(self, name, text='fixture'):
        target = self.root / name.lstrip('/'); target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(text); return target

    def config(self, filename, ws=False):
        value = {'inbounds': [
            {'type': 'vless', 'tag': 'vless-in', 'tls': {'reality': {'enabled': True}}},
            {'type': 'hysteria2', 'tag': 'hy2-in', 'tls': {'certificate_path': '/root/self-cert/cert.pem', 'key_path': '/root/self-cert/private.key'}}],
            'outbounds': [{'type': 'direct', 'tag': 'direct'}]}
        if ws: value['inbounds'].append({'type': 'vmess', 'tag': 'vmess-in', 'listen_port': 18443, 'transport': {'type': 'ws', 'path': '/vmess'}})
        return self.put(filename, json.dumps(value))

    def unit(self, name, command, description=None):
        descriptions = {'sing-box': 'sing-box service', 'cloudflared': 'Cloudflared Tunnel', 'caddy': 'Caddy Local Reverse Proxy'}
        self.put(cleanup.UNITS[name], f'[Unit]\nDescription={description or descriptions[name]}\n[Service]\nExecStart={command}\n')
        self.states[name] = 'active'

    def modern(self, ws=False):
        self.config(cleanup.CONFIGS[2], ws)
        self.put('/usr/local/bin/sing-box')
        self.unit('sing-box', '/usr/local/bin/sing-box run -c /etc/sing-box/config.json')
        if ws:
            self.put('/etc/caddy/Caddyfile', '{\n auto_https off\n admin off\n}\n:28080 {\n bind 127.0.0.1\n handle /vmess {\n reverse_proxy 127.0.0.1:18443\n }\n respond 404\n}\n')
            self.put('/usr/local/bin/caddy'); self.put('/usr/local/bin/cloudflared')
            self.put('/usr/local/bin/cloudflared-post-start.sh')
            self.put('/var/log/cloudflared.log', 'before\n')
            self.unit('caddy', '/usr/local/bin/caddy run --config /etc/caddy/Caddyfile')
            self.unit('cloudflared', '/usr/local/bin/cloudflared tunnel --url http://127.0.0.1:28080 --no-autoupdate --protocol auto --logfile /var/log/cloudflared.log')

    def legacy(self, sbox=False, service=False):
        config = cleanup.CONFIGS[1 if sbox else 0]
        binary = '/root/sbox/sing-box' if sbox else '/root/sing-box'
        self.config(config, sbox); self.put(binary)
        self.put(str(Path(config).parent / 'public.key.b64'), 'secret-public-key')
        self.put('/root/self-cert/cert.pem', 'certificate'); self.put('/root/self-cert/private.key', 'secret-private-key')
        if service: self.unit('sing-box', binary + ' run -c ' + config)
        if sbox: self.put('/root/sbox/cloudflared-linux')
        return binary, config

    def process(self, pid, binary, args, group='', start='123', deleted=False):
        directory = self.root / 'proc' / str(pid); directory.mkdir()
        (directory / 'exe').symlink_to(binary + (' (deleted)' if deleted else ''))
        (directory / 'cmdline').write_bytes(b'\0'.join(a.encode() for a in [binary] + args) + b'\0')
        tail = ['S'] + ['0'] * 18 + [start]
        (directory / 'stat').write_text(str(pid) + ' (name with ) parentheses) ' + ' '.join(tail))
        (directory / 'cgroup').write_text('0::/' + group + '\n')

    def systemctl(self, args):
        if args[1] == 'show':
            name = args[2].removesuffix('.service'); key = args[3].split('=', 1)[1]
            value = {'FragmentPath': cleanup.UNITS[name], 'DropInPaths': '', 'NeedDaemonReload': 'no',
                     'ActiveState': self.states.get(name, 'inactive'), 'UnitFileState': 'enabled'}[key]
            value = self.overrides.get((name, key), value)
            return subprocess.CompletedProcess(args, 0, value + '\n', '')
        self.events.append(args[1:])
        if args[1] == 'stop':
            if self.fail_stop: return subprocess.CompletedProcess(args, 1, '', 'failure')
            name = args[2].removesuffix('.service'); self.states[name] = 'inactive'
            if name == 'cloudflared' and self.append_log:
                with (self.root / 'var/log/cloudflared.log').open('a') as stream: stream.write('shutdown\n')
        return subprocess.CompletedProcess(args, 0, '', '')

    def terminate(self, process):
        if self.cleaner.process(process.pid) is not None:
            self.signals.append(process.pid)
            shutil.rmtree(self.root / 'proc' / str(process.pid))

    def apply(self, plan):
        with contextlib.redirect_stdout(io.StringIO()): return self.cleaner.apply(plan)

    def cli(self, *args, answer='yes'):
        output = io.StringIO()
        with mock.patch.object(cleanup.sys, 'platform', 'linux'), mock.patch.object(cleanup.os, 'geteuid', return_value=0), \
                mock.patch.object(cleanup, 'Cleaner', return_value=self.cleaner), \
                mock.patch('builtins.input', return_value=answer), contextlib.redirect_stdout(output), contextlib.redirect_stderr(output):
            result = cleanup.main(list(args))
        return result, output.getvalue()

    def test_preview_is_read_only(self):
        self.modern(); binary, config = self.legacy()
        self.process(101, binary, ['run', '-c', config])
        plan = self.cleaner.plan()
        self.assertIn(binary, plan.files); self.assertEqual([p.pid for p in plan.processes], [101])
        self.assertEqual(self.events, []); self.assertEqual(self.signals, [])
        self.assertFalse((self.root / 'var/backups').exists())

    def test_migration_removes_both_layouts_and_backs_up_secrets(self):
        self.modern(); binary, config = self.legacy()
        self.process(101, binary, ['run', '-c', config], deleted=True)
        self.process(102, '/usr/local/bin/sing-box', ['run', '-c', cleanup.CONFIGS[2]], 'system.slice/sing-box.service')
        backup = self.apply(self.cleaner.plan())
        self.assertCountEqual(self.signals, [101, 102])
        self.assertFalse((self.root / config.lstrip('/')).exists())
        self.assertFalse((self.root / 'usr/local/bin/sing-box').exists())
        self.assertFalse((self.root / binary.lstrip('/')).exists())
        self.assertEqual((backup / 'files/root/sing-box').read_text(), 'fixture')
        self.assertEqual((backup / 'files/root/self-cert/private.key').read_text(), 'secret-private-key')
        self.assertEqual(backup.stat().st_mode & 0o777, 0o700)

    def test_default_cli_cleans_old_deployment_before_new_install(self):
        binary, config = self.legacy(service=True)
        self.process(101, binary, ['run', '-c', config], 'system.slice/sing-box.service')
        result, output = self.cli()
        self.assertEqual(result, 0, output)
        self.assertEqual(self.signals, [101])
        self.assertFalse((self.root / config.lstrip('/')).exists())
        self.assertFalse((self.root / 'etc/sing-box/config.json').exists())
        self.assertFalse((self.root / 'etc/systemd/system/sing-box.service').exists())
        self.assertIn('sudo bash install.sh', output)
        self.assertIn('sudo bash reality_hy2_ws.sh', output)

    def test_dry_run_never_prompts_or_mutates(self):
        self.legacy(service=True)
        result, output = self.cli('--dry-run')
        self.assertEqual(result, 0, output)
        self.assertIn('仅预览', output)
        self.assertEqual(self.events, [])
        self.assertFalse((self.root / 'run/lock').exists())
        self.assertFalse((self.root / 'var/backups').exists())

    def test_cancel_preserves_old_deployment_without_backups_or_lock(self):
        self.legacy(service=True)
        result, output = self.cli(answer='no')
        self.assertNotEqual(result, 0)
        self.assertIn('已取消', output)
        self.assertEqual(self.events, [])
        self.assertTrue((self.root / 'root/sbconfig_server.json').exists())
        self.assertFalse((self.root / 'run/lock').exists())
        self.assertFalse((self.root / 'var/backups').exists())

    def test_yes_flag_skips_confirmation(self):
        self.legacy(sbox=True, service=True)
        result, output = self.cli('--yes', answer='no')
        self.assertEqual(result, 0, output)
        self.assertFalse((self.root / 'root/sbox/sbconfig_server.json').exists())

    def test_no_deployment_is_ready_without_prompt_or_backup(self):
        result, output = self.cli(answer='no')
        self.assertEqual(result, 0, output)
        self.assertIn('迁移准备完成', output)
        self.assertFalse((self.root / 'var/backups').exists())

    def test_unrecognized_deployment_does_not_claim_ready(self):
        self.put('/root/sbconfig_server.json', 'invalid config')
        result, output = self.cli('--yes')
        self.assertNotEqual(result, 0)
        self.assertIn('处理后再安装', output)
        self.assertNotIn('迁移准备完成', output)

    def test_deleted_unknown_executable_still_blocks_new_install(self):
        self.process(101, '/root/sing-box', ['run', '-c', '/opt/other.json'], deleted=True)
        result, output = self.cli('--yes')
        self.assertNotEqual(result, 0)
        self.assertIn('PID 101', output)
        self.assertNotIn('迁移准备完成', output)
        self.assertEqual(self.signals, [])

    def test_scan_changed_during_confirmation_aborts_before_backup(self):
        binary, _ = self.legacy(service=True)
        original = self.cleaner.plan
        scans = 0

        def rescan():
            nonlocal scans
            scans += 1
            if scans == 2: self.put(binary, 'changed')
            return original()

        with mock.patch.object(self.cleaner, 'plan', side_effect=rescan):
            result, output = self.cli()
        self.assertNotEqual(result, 0)
        self.assertIn('部署在扫描后发生变化', output)
        self.assertEqual(self.events, [])
        self.assertFalse((self.root / 'var/backups').exists())

    def test_migration_stops_legacy_service_and_preserves_unrelated_sbox_files(self):
        binary, config = self.legacy(sbox=True, service=True)
        self.put('/root/sbox/keep.txt', 'unrelated')
        self.process(101, binary, ['run', '-c', config], 'system.slice/sing-box.service')
        self.process(102, '/root/sbox/cloudflared-linux', ['tunnel', '--url', 'http://localhost:18443', '--no-autoupdate'])
        backup = self.apply(self.cleaner.plan())
        self.assertCountEqual(self.signals, [101, 102])
        self.assertEqual(self.events[0], ['stop', 'sing-box.service'])
        self.assertTrue((self.root / 'root/sbox/keep.txt').exists())
        self.assertEqual((backup / 'files/root/self-cert/private.key').read_text(), 'secret-private-key')

    def test_migration_etc_layout_backs_up_secrets_and_log_shutdown(self):
        self.modern(ws=True); self.append_log = True
        self.put('/etc/sing-box/certs/private.key', 'keep-me-in-backup')
        self.put('/var/backups/fkgfw/legacy-migrated', 'keep-marker')
        self.put('/var/backups/fkgfw/old-backup/binary', 'keep-backup')
        backup = self.apply(self.cleaner.plan())
        self.assertFalse((self.root / 'etc/sing-box').exists())
        self.assertTrue((self.root / 'var/backups/fkgfw/legacy-migrated').exists())
        self.assertTrue((self.root / 'var/backups/fkgfw/old-backup/binary').exists())
        self.assertEqual((backup / 'files/etc/sing-box/certs/private.key').read_text(), 'keep-me-in-backup')
        self.assertEqual((backup / 'files/var/log/cloudflared.log').read_text(), 'before\n')
        self.assertEqual((backup / 'cloudflared-stopped.log').read_text(), 'before\nshutdown\n')

    def test_same_name_other_config_and_token_tunnel_survive(self):
        self.modern(ws=True)
        self.process(101, '/usr/local/bin/sing-box', ['run', '-c', '/opt/other/config.json'])
        self.process(102, '/usr/local/bin/cloudflared', ['tunnel', 'run', '--token', 'secret-token'])
        plan = self.cleaner.plan()
        self.assertNotIn('/usr/local/bin/sing-box', plan.files)
        self.assertNotIn('/usr/local/bin/cloudflared', plan.files)
        self.assertFalse(plan.processes)
        output = io.StringIO()
        with contextlib.redirect_stdout(output): self.cleaner.show(plan)
        self.assertNotIn('secret-token', output.getvalue())

    def test_unknown_service_cgroup_prevents_process_and_binary_cleanup(self):
        self.modern(); binary, config = self.legacy()
        self.process(101, binary, ['run', '-c', config], 'system.slice/other.service')
        plan = self.cleaner.plan()
        self.assertFalse(plan.processes); self.assertNotIn(binary, plan.files)

    def test_dropin_and_foreign_unit_protect_deployment(self):
        self.modern()
        self.overrides[('sing-box', 'DropInPaths')] = '/etc/systemd/system/sing-box.service.d/custom.conf'
        plan = self.cleaner.plan()
        self.assertNotIn('sing-box', plan.services)
        self.assertNotIn('/etc/sing-box', plan.files)

    def test_other_service_reference_protects_shared_binary(self):
        self.modern()
        self.put('/etc/systemd/system/other.service', '[Service]\nExecStart=/usr/local/bin/sing-box run -c /opt/other.json\n')
        plan = self.cleaner.plan()
        self.assertNotIn('/usr/local/bin/sing-box', plan.files)

    def test_other_service_dropin_protects_shared_config(self):
        self.modern()
        self.put('/run/systemd/system/other.service.d/custom.conf', '[Service]\nEnvironment=CONFIG=/etc/sing-box/config.json\n')
        self.assertNotIn('/etc/sing-box', self.cleaner.plan().files)

    def test_unknown_process_config_option_protects_config(self):
        self.modern()
        self.process(101, '/opt/another-program', ['--config=/etc/sing-box/custom.json'])
        self.assertNotIn('/etc/sing-box', self.cleaner.plan().files)

    def test_malformed_config_is_preserved(self):
        self.modern()
        self.put(cleanup.CONFIGS[2], '{"inbounds":[{"tag":"vless-in","type":"vless","tls":null}],"outbounds":[]}')
        plan = self.cleaner.plan()
        self.assertNotIn('/etc/sing-box', plan.files)
        self.assertNotIn('sing-box', plan.services)

    def test_pid_identity_change_never_signals(self):
        old = cleanup.Process(101, '123', '/root/sing-box', ('/root/sing-box',), '')
        new = cleanup.Process(101, '456', '/root/sing-box', ('/root/sing-box',), '')
        with mock.patch.object(self.cleaner, 'process', return_value=new), mock.patch.object(cleanup.os, 'pidfd_open', create=True) as pidfd:
            with self.assertRaisesRegex(RuntimeError, '身份已变化'):
                self.cleaner.terminate(old)
            pidfd.assert_not_called()

    def test_symlinked_old_binary_is_preserved(self):
        self.modern(); binary, config = self.legacy()
        target = self.root / binary.lstrip('/'); target.unlink()
        target.symlink_to(self.root / 'usr/local/bin/sing-box')
        self.assertNotIn(binary, self.cleaner.plan().files)

    def test_exact_archive_names_only(self):
        self.modern()
        self.put('/root/sing-box-1.14.4-linux-arm64.tar.gz')
        self.put('/root/sing-box-personal.tar.gz')
        plan = self.cleaner.plan()
        self.assertIn('/root/sing-box-1.14.4-linux-arm64.tar.gz', plan.files)
        self.assertNotIn('/root/sing-box-personal.tar.gz', plan.files)

    def test_backup_failure_prevents_stop_and_delete(self):
        self.modern()
        plan = self.cleaner.plan()
        with mock.patch.object(cleanup.shutil, 'copy2', side_effect=OSError('disk full')):
            with self.assertRaises(OSError): self.apply(plan)
        self.assertEqual(self.events, [])
        self.assertTrue((self.root / 'etc/sing-box/config.json').exists())

    def test_stop_failure_keeps_files(self):
        self.modern(); self.fail_stop = True
        with self.assertRaises(RuntimeError): self.apply(self.cleaner.plan())
        self.assertTrue((self.root / 'usr/local/bin/sing-box').exists())
        self.assertTrue((self.root / 'etc/sing-box/config.json').exists())
        self.assertFalse(any(e[0] == 'disable' for e in self.events))

    def test_file_changed_after_preview_aborts(self):
        self.modern(); binary, config = self.legacy()
        plan = self.cleaner.plan()
        self.put(binary, 'changed')
        with self.assertRaises(RuntimeError): self.apply(plan)
        self.assertEqual(self.events, [])

    def test_respawn_prevents_deletion(self):
        self.modern(); binary, config = self.legacy()
        self.process(101, binary, ['run', '-c', config])
        plan = self.cleaner.plan()
        self.cleaner.terminator = lambda process: None
        with self.assertRaises(RuntimeError): self.apply(plan)
        self.assertTrue((self.root / binary.lstrip('/')).exists())

    def test_retained_config_protects_shared_old_certificate(self):
        self.modern(); self.legacy()
        self.overrides[('sing-box', 'DropInPaths')] = '/etc/systemd/system/sing-box.service.d/custom.conf'
        plan = self.cleaner.plan()
        self.assertNotIn('/root/self-cert/private.key', plan.files)


if __name__ == '__main__':
    unittest.main(verbosity=2)
