#!/usr/bin/env python3
"""Exercise release validation and rollback without touching host services."""
import hashlib
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import tarfile
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class UpdateTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='fkgfw-update-')
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        for directory in ['usr/local/bin', 'etc/sing-box', 'etc/systemd/system', 'var/backups/fkgfw', 'mock', 'root/self-cert']:
            (self.root / directory).mkdir(parents=True)
        library = (ROOT / 'lib/releases.sh').read_text()
        for prefix in ['/usr/local/bin', '/etc/sing-box', '/etc/systemd/system', '/etc/caddy', '/var/backups/fkgfw', '/root/']:
            library = library.replace(prefix, str(self.root) + prefix)
        self.library = self.root / 'releases.sh'
        self.library.write_text(library)
        self.env = dict(os.environ, SCRIPT_DIR=str(ROOT), TEST_ROOT=str(self.root), ARCH='x86_64',
                        PATH=str(self.root / 'mock') + ':' + os.environ['PATH'])
        self.mock('uname', 'printf "%s\\n" "$ARCH"')
        self.mock('chown', 'exit 0')
        self.mock('sleep', 'exit 0')
        self.mock('sha256sum', '''python3 - "$1" <<'END'
import hashlib, sys
print(hashlib.sha256(open(sys.argv[1], 'rb').read()).hexdigest(), sys.argv[1])
END''')
        self.mock('install', '''python3 - "$@" <<'END'
import sys, shutil, os
args=sys.argv[1:]; rest=[]; mode=0o755
while args:
    value=args.pop(0)
    if value in ['-o', '-g']: args.pop(0)
    elif value == '-m': mode=int(args.pop(0), 8)
    elif value == '-d': pass
    else: rest.append(value)
if '-d' in sys.argv:
    for path in rest: os.makedirs(path, exist_ok=True); os.chmod(path, mode)
else: shutil.copyfile(*rest); os.chmod(rest[-1], mode)
END''')
        self.mock('curl', '''[ "${DOWNLOAD_FAIL:-0}" = 0 ] || exit 22
url=""; output=""
while [ "$#" -gt 0 ]; do
    case "$1" in https://*) url="$1";; -o) shift; output="$1";; esac
    shift
done
case "$url" in
    */releases/latest) cp "$TEST_ROOT/release.json" "$output";;
    *) cp "$TEST_ROOT/package" "$output";;
esac''')
        self.mock('systemctl', '''echo "$*" >> "$TEST_ROOT/events"
case "$1" in
    is-active) [ "$(cat "$TEST_ROOT/active")" = 1 ];;
    restart)
        if [ "${RESTART_FAIL:-0}" = 1 ] && grep -q NEW "$TEST_ROOT/usr/local/bin/$2"; then
            echo 0 > "$TEST_ROOT/active"; exit 1
        fi
        echo 1 > "$TEST_ROOT/active";;
    stop) echo 0 > "$TEST_ROOT/active";;
esac''')
        (self.root / 'active').write_text('1')
        self.binary = self.root / 'usr/local/bin/sing-box'
        self.binary.write_text('#!/bin/sh\n# OLD\nexit 0\n')
        self.binary.chmod(0o755)
        self.config = self.root / 'etc/sing-box/config.json'
        self.original_config = json.dumps({'inbounds': [{'type': 'vless', 'tag': 'vless-in', 'sniff': True,
                                                       'users': [{'uuid': 'preserved-uuid'}]}],
                                           'outbounds': [{'type': 'direct', 'tag': 'direct'}, {'type': 'block', 'tag': 'block'}]})
        self.config.write_text(self.original_config)
        (self.root / 'etc/systemd/system/sing-box.service').write_text('ORIGINAL SERVICE\n')
        self.release()

    def mock(self, name, code):
        path = self.root / 'mock' / name
        path.write_text('#!/bin/bash\nset -e\n' + code + '\n')
        path.chmod(0o755)

    def release(self, component='sing-box', arch='amd64', prerelease=False, digest=None):
        version = '1.14.4' if component == 'sing-box' else '2026.10.5'
        tag = 'v' + version if component == 'sing-box' else version
        repo = 'SagerNet/sing-box' if component == 'sing-box' else 'cloudflare/cloudflared'
        content = b'#!/bin/bash\n# NEW\nif [ "$1" = check ] && [ "${CHECK_FAIL:-0}" = 1 ]; then exit 1; fi\necho new-version\n'
        if component == 'sing-box':
            name = f'sing-box-{version}-linux-{arch}.tar.gz'
            with tarfile.open(self.root / 'package', 'w:gz') as archive:
                info = tarfile.TarInfo(name[:-7] + '/sing-box')
                info.size = len(content); info.mode = 0o755
                archive.addfile(info, io.BytesIO(content))
        else:
            name = 'cloudflared-linux-' + arch
            (self.root / 'package').write_bytes(content)
        checksum = hashlib.sha256((self.root / 'package').read_bytes()).hexdigest()
        self.metadata = {'tag_name': tag, 'draft': False, 'prerelease': prerelease,
                         'assets': [{'name': name, 'digest': digest if digest is not None else 'sha256:' + checksum,
                                     'browser_download_url': f'https://github.com/{repo}/releases/download/{tag}/{name}'}]}
        self.save_metadata()

    def save_metadata(self):
        (self.root / 'release.json').write_text(json.dumps(self.metadata))

    def run_shell(self, code, **env):
        return subprocess.run(['bash', '-c', 'set -o pipefail; source "$TEST_ROOT/releases.sh"; ' + code],
                              env=dict(self.env, **env), text=True, capture_output=True)

    def assert_unchanged(self, result):
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('OLD', self.binary.read_text())
        self.assertEqual(self.config.read_text(), self.original_config)

    def test_success_preserves_credentials_and_backs_up(self):
        result = self.run_shell('update_component sing-box')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('NEW', self.binary.read_text())
        config = json.loads(self.config.read_text())
        self.assertEqual(config['inbounds'][0]['users'][0]['uuid'], 'preserved-uuid')
        self.assertNotIn('sniff', config['inbounds'][0])
        backup = next((self.root / 'var/backups/fkgfw').glob('sing-box.*'))
        self.assertIn('OLD', (backup / 'binary').read_text())
        self.assertEqual((backup / 'config').read_text(), self.original_config)

    def test_download_failure_keeps_existing(self):
        self.assert_unchanged(self.run_shell('update_component sing-box', DOWNLOAD_FAIL='1'))
        self.assertFalse((self.root / 'events').exists())

    def test_missing_digest_rejected_even_in_conditional_call(self):
        self.metadata['assets'][0]['digest'] = None; self.save_metadata()
        self.assert_unchanged(self.run_shell('download_singbox || exit 17'))

    def test_checksum_failure_keeps_existing(self):
        self.release(digest='sha256:' + '0' * 64)
        self.assert_unchanged(self.run_shell('update_component sing-box'))

    def test_prerelease_rejected(self):
        self.release(prerelease=True)
        self.assert_unchanged(self.run_shell('update_component sing-box'))

    def test_missing_architecture_asset_rejected(self):
        self.assert_unchanged(self.run_shell('update_component sing-box', ARCH='aarch64'))

    def test_armv7_cloudflared_mapping(self):
        self.release(component='cloudflared', arch='arm')
        result = self.run_shell('fetch_binary cloudflared "$TEST_ROOT/result"', ARCH='armv7l')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('NEW', (self.root / 'result').read_text())

    def test_bad_config_keeps_existing_service_running(self):
        self.assert_unchanged(self.run_shell('update_component sing-box', CHECK_FAIL='1'))
        self.assertFalse((self.root / 'events').exists())

    def test_restart_failure_rolls_back_binary_and_config(self):
        self.assert_unchanged(self.run_shell('update_component sing-box', RESTART_FAIL='1'))
        self.assertEqual((self.root / 'active').read_text().strip(), '1')

    def test_previously_stopped_service_stays_stopped_after_failure(self):
        (self.root / 'active').write_text('0')
        self.assert_unchanged(self.run_shell('update_component sing-box', RESTART_FAIL='1'))
        self.assertEqual((self.root / 'active').read_text().strip(), '0')

    def test_cloudflared_updates_unit_and_helper(self):
        self.release(component='cloudflared')
        shutil.copy2(self.binary, self.binary.with_name('cloudflared'))
        unit = self.root / 'etc/systemd/system/cloudflared.service'
        unit.write_text('ExecStartPre=/bin/sleep 3\nExecStart=cloudflared --protocol h2mux\n')
        helper = self.binary.with_name('cloudflared-post-start.sh'); helper.write_text('OLD HELPER')
        result = self.run_shell('update_component cloudflared')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('--protocol auto', unit.read_text())
        self.assertIn('truncate -s 0', unit.read_text())
        self.assertIn('attempt < 60', helper.read_text())

    def test_legacy_migration_preserves_root_files(self):
        self.config.unlink()
        old = self.root / 'root/sbconfig_server.json'; old.write_text(self.original_config)
        for name in ['cert.pem', 'private.key']: (self.root / 'root/self-cert' / name).write_text('fixture')
        (self.root / 'root/public.key.b64').write_text('fixture')
        result = self.run_shell('migrate_legacy_install')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(old.read_text(), self.original_config)
        self.assertIn('NEW', self.binary.read_text())
        self.assertTrue(self.config.exists())


if __name__ == '__main__':
    unittest.main(verbosity=2)
