#!/usr/bin/env python3
"""Disposable Linux integration: real procfs/pidfd, simulated systemd only."""
import fcntl
import json
import os
from pathlib import Path
import shutil
import subprocess
import time

if os.environ.get('FKGFW_CONTAINER_TEST') != '1' or not Path('/.dockerenv').exists():
    raise SystemExit('Run only in the disposable Docker test container described in README.md')


def put(filename, text):
    target = Path(filename); target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(text)
    return target


def config(filename, ws=False):
    value = {'inbounds': [
        {'type': 'vless', 'tag': 'vless-in', 'tls': {'reality': {'enabled': True}}},
        {'type': 'hysteria2', 'tag': 'hy2-in', 'tls': {'certificate_path': '/root/self-cert/cert.pem', 'key_path': '/root/self-cert/private.key'}}],
        'outbounds': [{'type': 'direct', 'tag': 'direct'}]}
    if ws:
        value['inbounds'].append({'type': 'vmess', 'tag': 'vmess-in', 'listen_port': 18443, 'transport': {'type': 'ws'}})
    put(filename, json.dumps(value))


def unit(name, description, command):
    put('/etc/systemd/system/' + name + '.service', f'[Unit]\nDescription={description}\n[Service]\nExecStart={command}\n')
    put('/tmp/state-' + name, 'active')


mock = put('/tmp/cleanup-mock/systemctl', '''#!/usr/bin/python3
import pathlib, sys
args=sys.argv[1:]; action=args[0]
if action == 'show':
 name=args[1].removesuffix('.service'); key=args[2].split('=',1)[1]
 state=pathlib.Path('/tmp/state-'+name)
 print({'FragmentPath':'/etc/systemd/system/'+name+'.service','DropInPaths':'','NeedDaemonReload':'no',
        'ActiveState':state.read_text() if state.exists() else 'inactive','UnitFileState':'enabled'}[key])
elif action == 'stop':
 name=args[1].removesuffix('.service'); pathlib.Path('/tmp/state-'+name).write_text('inactive')
 logfile={'cloudflared':'/var/log/cloudflared.log','cloudflared-vmess':'/var/log/cf-vmess.log','cloudflared-vless':'/var/log/cf-vless.log'}.get(name)
 if logfile:
  with open(logfile,'a') as stream: stream.write('stopped\\n')
elif action not in ('disable','daemon-reload'): sys.exit(1)
''')
mock.chmod(0o755)
os.environ['PATH'] = str(mock.parent) + ':' + os.environ['PATH']
os.environ['POSIXLY_CORRECT'] = '1'  # yes treats all arguments after run/tunnel as operands.
children = []


def spawn(binary, args):
    target = Path(binary); target.parent.mkdir(parents=True, exist_ok=True)
    if not target.exists(): shutil.copy2('/usr/bin/yes', target)
    process = subprocess.Popen([binary] + args, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
    children.append(process)
    time.sleep(.05)
    assert process.poll() is None, process.stderr.read().decode()
    return process


def invoke(*args, success=True, answers='yes\n', entry='migration.sh'):
    result = subprocess.run(['bash', '/repo/' + entry, *args], input=answers, text=True, capture_output=True)
    if (result.returncode == 0) != success:
        raise AssertionError(result.stdout + result.stderr)
    return result.stdout + result.stderr


def alive(process):
    return process.poll() is None


try:
    config('/root/sbconfig_server.json')
    config('/root/sbox/sbconfig_server.json', True)
    put('/root/self-cert/private.key', 'old-secret')
    put('/root/self-cert/cert.pem', 'old-certificate')
    put('/root/sbox/personal.txt', 'keep-me')
    put('/root/sing-box-1.8.0-linux-arm64.tar.gz', 'old-package')
    put('/var/backups/fkgfw/previous/sing-box', 'upgrade-backup')
    unit('sing-box', 'sing-box service', '/root/sbox/sing-box run -c /root/sbox/sbconfig_server.json')
    old = spawn('/root/sing-box', ['run', '-c', '/root/sbconfig_server.json'])
    old_sbox = spawn('/root/sbox/sing-box', ['run', '-c', '/root/sbox/sbconfig_server.json'])
    old_tunnel = spawn('/root/sbox/cloudflared-linux', ['tunnel', '--url', 'http://localhost:18443', '--no-autoupdate', '--edge-ip-version', 'auto', '--protocol', 'h2mux'])
    Path('/root/sing-box').unlink()  # A still-running old executable marked (deleted).

    output = invoke('--dry-run')
    assert '仅预览' in output
    assert all(alive(p) for p in children)
    assert not list(Path('/var/backups/fkgfw').glob('cleanup.*'))
    assert not Path('/run/lock/fkgfw.lock').exists()
    print('PASS: preview is read-only with live Linux processes', flush=True)

    assert '已取消' in invoke(answers='no\n', success=False)
    assert all(alive(p) for p in children)
    assert not Path('/run/lock/fkgfw.lock').exists()
    assert not list(Path('/var/backups/fkgfw').glob('cleanup.*'))
    print('PASS: default entry asks for confirmation; cancelling preserves old deployment', flush=True)

    lock = Path('/run/lock/fkgfw.lock'); lock.parent.mkdir(parents=True, exist_ok=True)
    with lock.open('w') as stream:
        fcntl.flock(stream, fcntl.LOCK_EX | fcntl.LOCK_NB)
        assert '另一个安装' in invoke('--yes', success=False)
        assert all(alive(p) for p in children)
    print('PASS: installer/cleanup shared lock prevents concurrent mutation', flush=True)

    output = invoke()
    assert not any(alive(p) for p in [old, old_sbox, old_tunnel])
    assert not Path('/root/sbox/sing-box').exists()
    assert not Path('/root/sbox/cloudflared-linux').exists()
    assert not Path('/root/sing-box-1.8.0-linux-arm64.tar.gz').exists()
    assert not Path('/root/sbox/sbconfig_server.json').exists()
    assert not Path('/root/sbconfig_server.json').exists()
    assert not Path('/etc/sing-box/config.json').exists()
    assert not Path('/root/self-cert/private.key').exists()
    assert not Path('/etc/systemd/system/sing-box.service').exists()
    backup = next(Path('/var/backups/fkgfw').glob('cleanup.*'))
    assert (backup / 'files/root/self-cert/private.key').read_text() == 'old-secret'
    assert '迁移准备完成' in output
    print('PASS: default migration cleans an old-only deployment, configs and orphan processes before any new installation', flush=True)

    config('/etc/sing-box/config.json', True)
    put('/etc/sing-box/certs/private.key', 'current-secret')
    os.chown('/etc/sing-box/certs/private.key', 65534, 65534)
    os.chmod('/etc/sing-box/certs/private.key', 0o600)
    put('/var/backups/fkgfw/legacy-migrated', 'marker')
    put('/etc/caddy/Caddyfile', '{\n auto_https off\n admin off\n}\n:28080 {\n bind 127.0.0.1\n handle /vmess {\n reverse_proxy 127.0.0.1:18443\n }\n respond 404\n}\n')
    put('/usr/local/bin/cloudflared-post-start.sh', '# fixture helper\n')
    put('/var/log/cloudflared.log', 'started\n')
    unit('sing-box', 'sing-box service', '/usr/local/bin/sing-box run -c /etc/sing-box/config.json')
    unit('caddy', 'Caddy Local Reverse Proxy', '/usr/local/bin/caddy run --config /etc/caddy/Caddyfile')
    unit('cloudflared', 'Cloudflared Tunnel', '/usr/local/bin/cloudflared tunnel --url http://127.0.0.1:28080 --no-autoupdate --protocol auto --logfile /var/log/cloudflared.log')
    current = spawn('/usr/local/bin/sing-box', ['run', '-c', '/etc/sing-box/config.json'])
    caddy = spawn('/usr/local/bin/caddy', ['run', '--config', '/etc/caddy/Caddyfile'])
    tunnel = spawn('/usr/local/bin/cloudflared', ['tunnel', '--url', 'http://127.0.0.1:28080', '--no-autoupdate', '--protocol', 'auto', '--logfile', '/var/log/cloudflared.log'])
    unrelated = spawn('/usr/local/bin/cloudflared', ['tunnel', 'run', '--token', 'fixture-secret-token'])
    invoke('--dry-run', entry='cleanup.sh', success=False)
    assert all(alive(p) for p in [current, caddy, tunnel, unrelated])
    output = invoke(entry='cleanup.sh', success=False)
    assert '处理后再安装' in output and '迁移准备完成' not in output
    assert '清理前检查未通过' in output
    assert all(alive(p) for p in [current, caddy, tunnel, unrelated])
    assert Path('/etc/caddy/Caddyfile').exists() and Path('/etc/sing-box/config.json').exists()
    assert len(list(Path('/var/backups/fkgfw').glob('cleanup.*'))) == 1
    print('PASS: unrelated token tunnel blocks all cleanup before any service or file changes', flush=True)
    unrelated.terminate(); unrelated.wait(timeout=3)  # Only this test fixture removes its unrelated process.
    output = invoke(entry='cleanup.sh')
    assert not any(alive(p) for p in [current, caddy, tunnel])
    assert not Path('/usr/local/bin/cloudflared').exists()
    assert 'fixture-secret-token' not in output
    assert not Path('/etc/sing-box').exists()
    assert not Path('/root/sbox/sbconfig_server.json').exists()
    assert Path('/root/sbox/personal.txt').read_text() == 'keep-me'
    backups = list(Path('/var/backups/fkgfw').glob('cleanup.*'))
    reset = next(b for b in backups if '/etc/sing-box' in json.loads((b / 'manifest.json').read_text())['files'])
    assert reset.stat().st_mode & 0o777 == 0o700
    assert (reset / 'files/etc/sing-box/certs/private.key').read_text() == 'current-secret'
    key_stat = (reset / 'files/etc/sing-box/certs/private.key').stat()
    assert (key_stat.st_uid, key_stat.st_gid, key_stat.st_mode & 0o777) == (65534, 65534, 0o600)
    assert (reset / 'files/var/log/cloudflared.log').read_text() == 'started\n'
    assert (reset / 'cloudflared-stopped.log').read_text() == 'started\nstopped\n'
    assert Path('/var/backups/fkgfw/legacy-migrated').read_text() == 'marker'
    assert Path('/var/backups/fkgfw/previous/sing-box').read_text() == 'upgrade-backup'
    print('PASS: cleanup alias handles /etc layout and preserves backups', flush=True)

    # Reproduce the diagnosed server after its earlier partial cleanup: Caddy
    # is gone, the loaded sing-box unit points to /root, but its live process
    # uses /etc; each WS protocol has an independent Quick Tunnel unit.
    config('/root/sbconfig_server.json')
    config('/etc/sing-box/config.json', True)
    value = json.loads(Path('/etc/sing-box/config.json').read_text())
    value['inbounds'].append({'type': 'vless', 'tag': 'vless-ws-in', 'listen_port': 18444, 'transport': {'type': 'ws'}})
    Path('/etc/sing-box/config.json').write_text(json.dumps(value))
    shutil.copy2('/usr/bin/yes', '/root/sing-box')
    unit('sing-box', 'sing-box service', '/root/sing-box run -c /root/sbconfig_server.json')
    current = spawn('/usr/local/bin/sing-box', ['run', '-c', '/etc/sing-box/config.json'])
    direct = []
    for name, description, port in [('vmess', 'VMess', 18443), ('vless', 'VLESS', 18444)]:
        logfile = '/var/log/cf-' + name + '.log'
        put(logfile, 'started\n'); put('/usr/local/bin/cf-' + name + '-post.sh', '# fixture helper')
        unit('cloudflared-' + name, 'Cloudflared ' + description + ' Tunnel', f'/usr/local/bin/cloudflared tunnel --url http://localhost:{port} --logfile {logfile}')
        direct.append(spawn('/usr/local/bin/cloudflared', ['tunnel', '--url', f'http://localhost:{port}', '--logfile', logfile]))
    output = invoke('--dry-run')
    assert 'cloudflared-vmess' in output and 'cloudflared-vless' in output
    assert all(alive(p) for p in [current, *direct])
    invoke()
    assert not any(alive(p) for p in [current, *direct])
    assert not Path('/root/sing-box').exists() and not Path('/etc/sing-box').exists()
    for name in ['vmess', 'vless']:
        assert not Path('/etc/systemd/system/cloudflared-' + name + '.service').exists()
        assert not Path('/usr/local/bin/cf-' + name + '-post.sh').exists()
        assert any((b / ('cf-' + name + '-stopped.log')).read_text() == 'started\nstopped\n'
                   for b in Path('/var/backups/fkgfw').glob('cleanup.*') if (b / ('cf-' + name + '-stopped.log')).exists())
    print('PASS: mixed sing-box paths and independent VMess/VLESS tunnels migrate after prior partial cleanup', flush=True)
finally:
    for process in children:
        if process.poll() is None: process.terminate()
    for process in children:
        try: process.wait(timeout=3)
        except subprocess.TimeoutExpired:
            process.kill(); process.wait()
