#!/usr/bin/env python3
"""Container-only 15-combination installs and traffic tests; no public tunnel."""
import itertools
import json
import os
from pathlib import Path
import shutil
import subprocess
import time
import yaml

if os.environ.get('FKGFW_CONTAINER_TEST') != '1' or not Path('/.dockerenv').exists():
    raise SystemExit('Run only in the disposable Docker test container described in README.md')

TAGS = ['vless-in', 'hy2-in', 'vmess-in', 'vless-ws-in']
CONFIG = Path('/etc/sing-box/config.json')
mock = Path('/tmp/mock'); mock.mkdir()
os.environ['PATH'] = str(mock) + ':' + os.environ['PATH']
os.environ['SERVER_ADDRESS'] = '127.0.0.1'


def write(name, text):
    target = mock / name; target.write_text(text); target.chmod(0o755)


write('curl', '''#!/usr/bin/python3
import hashlib, os, pathlib, subprocess, sys
args=sys.argv[1:]
url=next((a for a in args if a.startswith('https://')), '')
if url == 'https://api.ipify.org': print('127.0.0.1'); sys.exit(0)
output=args[args.index('-o')+1] if '-o' in args else None
# Cache only official release responses within this disposable test run.
cache=pathlib.Path('/tmp/download-cache'); cache.mkdir(exist_ok=True)
key=cache / hashlib.sha256(url.encode()).hexdigest()
if output and key.exists(): pathlib.Path(output).write_bytes(key.read_bytes()); sys.exit(0)
result=subprocess.run(['/usr/bin/curl']+args)
if result.returncode == 0 and output: key.write_bytes(pathlib.Path(output).read_bytes())
sys.exit(result.returncode)
''')
write('systemctl', '''#!/usr/bin/python3
import os, sys, signal, subprocess, time, pathlib, shlex
args=sys.argv[1:]; action=args[0]; names=[a.removesuffix('.service') for a in args[1:] if not a.startswith('-')]
if action=='show':
 name=names[0]; key=next(a.split('=',1)[1] for a in args if a.startswith('--property='))
 print({'FragmentPath':'/etc/systemd/system/'+name+'.service','DropInPaths':'','NeedDaemonReload':'no',
        'ActiveState':'active' if pathlib.Path('/tmp/service-'+name).exists() else 'inactive',
        'UnitFileState':'enabled' if pathlib.Path('/tmp/service-'+name+'.enabled').exists() else 'disabled'}[key])
 sys.exit(0)
for name in names:
 path=pathlib.Path('/tmp/service-'+name)
 enabled=pathlib.Path(str(path)+'.enabled')
 if action=='enable': enabled.touch()
 if action=='disable': enabled.unlink(missing_ok=True)
 if action=='is-enabled' and not enabled.exists(): sys.exit(1)
 if action in ('stop','restart') and path.exists():
  pid=int(path.read_text())
  if pid:
   try: os.killpg(pid, signal.SIGTERM)
   except ProcessLookupError: pass
  path.unlink(); time.sleep(.2)
 if action in ('start','restart') and not path.exists():
  unit=pathlib.Path('/etc/systemd/system/'+name+'.service').read_text()
  if name=='cloudflared':
   subprocess.run(['/usr/local/bin/cloudflared','tunnel','--protocol','auto','--help'],check=True,stdout=subprocess.DEVNULL)
   counter=pathlib.Path('/tmp/tunnel-generation'); number=int(counter.read_text())+1 if counter.exists() else 1
   counter.write_text(str(number))
   pathlib.Path('/var/log/cloudflared.log').write_text(f'https://smoke-{number}.trycloudflare.com\\n')
   subprocess.run(['runuser','-u','singbox','--','/usr/local/bin/cloudflared-post-start.sh'],check=True)
   path.write_text('0')
  else:
   cmd=next(line[10:] for line in unit.splitlines() if line.startswith('ExecStart='))
   command=shlex.split(cmd)
   if name=='sing-box': command=['runuser','-u','singbox','--']+command
   log=open('/tmp/'+name+'.log','ab')
   p=subprocess.Popen(command,stdout=log,stderr=log,start_new_session=True)
   path.write_text(str(p.pid)); time.sleep(.4)
 if action=='is-active':
  if not path.exists(): sys.exit(3)
  pid=int(path.read_text())
  if pid:
   try: os.kill(pid,0)
   except ProcessLookupError: sys.exit(3)
''')


def run(*args, **kw):
    return subprocess.run(args, check=True, text=True, **kw)


def invoke(entry, answers):
    log = Path('/tmp/installer.log')
    with log.open('w') as output:
        result = subprocess.run(['bash', entry], input=answers, text=True, stdout=output, stderr=subprocess.STDOUT)
    if result.returncode:
        print(log.read_text()[-7000:])
        raise RuntimeError(entry + ' failed')


def inputs(selected, existing=(), manage=False):
    presets = {('vless-in',): '1', ('hy2-in',): '2', tuple(TAGS[:2]): '3', tuple(TAGS[2:]): '4', tuple(TAGS): '5'}
    lines = ['1'] if manage else []
    if tuple(selected) in presets:
        lines.append(presets[tuple(selected)])
    else:
        lines += ['6', ','.join(str(TAGS.index(tag) + 1) for tag in selected)]
    for tag in selected:
        if tag in existing: continue
        lines.append(str(10443 + TAGS.index(tag)))
        lines.append('example.com' if tag in TAGS[:2] else '/ws' + str(TAGS.index(tag)))
    if set(selected) & set(TAGS[2:]) and not set(existing) & set(TAGS[2:]): lines.append('28080')
    return '\n'.join(lines) + '\n'


def validate(selected):
    config = json.loads(CONFIG.read_text())
    assert {i['tag'] for i in config['inbounds']} == set(selected)
    run('/usr/local/bin/sing-box', 'check', '-c', str(CONFIG))
    run('/usr/local/bin/sing-box', 'check', '-c', '/etc/sing-box/client.json')
    client = json.loads(Path('/etc/sing-box/client.json').read_text())
    assert len([o for o in client['outbounds'] if o['tag'].startswith('sing-box-')]) == len(selected)
    clash = json.loads(Path('/etc/sing-box/clash.json').read_text())
    assert len(clash['proxies']) == len(selected)
    clash_yaml = Path('/etc/sing-box/clash.yaml')
    assert yaml.safe_load(clash_yaml.read_text()) == clash
    assert clash_yaml.stat().st_mode & 0o777 == 0o600
    assert 'Clash Meta / Mihomo 客户端配置（YAML' in Path('/tmp/installer.log').read_text()
    run('systemd-analyze', 'verify', '/etc/systemd/system/sing-box.service')
    if set(selected) & set(TAGS[2:]):
        run('systemd-analyze', 'verify', '/etc/systemd/system/caddy.service', '/etc/systemd/system/cloudflared.service')
        caddy = Path('/etc/caddy/Caddyfile').read_text()
        for index in [2, 3]: assert ('/ws' + str(index) in caddy) == (TAGS[index] in selected)
    else:
        assert not Path('/tmp/service-caddy').exists()
        assert not Path('/tmp/service-cloudflared.enabled').exists()
    return config


def traffic(selected):
    config = json.loads(CONFIG.read_text())
    for inbound in config['inbounds']:
        if inbound['tag'] == 'vless-in':
            inbound['tls']['reality']['handshake'] = {'server': '127.0.0.1', 'server_port': 18446}
    CONFIG.write_text(json.dumps(config))
    run('systemctl', 'restart', 'sing-box')
    client = json.loads(Path('/etc/sing-box/client.json').read_text())
    for outbound in client['outbounds']:
        if not outbound['tag'].startswith('sing-box-'): continue
        label = outbound['tag']
        if outbound.get('transport', {}).get('type') == 'ws':
            outbound['server'] = '127.0.0.1'; outbound['server_port'] = 28080; outbound.pop('tls', None)
        outbound['tag'] = 'proxy'
        mini = {'log': {'level': 'debug'}, 'inbounds': [{'type': 'mixed', 'listen': '127.0.0.1', 'listen_port': 19080}], 'outbounds': [outbound]}
        Path('/tmp/probe.json').write_text(json.dumps(mini))
        with open('/tmp/client.log', 'w') as output:
            proc = subprocess.Popen(['/usr/local/bin/sing-box', 'run', '-c', '/tmp/probe.json'], stdout=output, stderr=output)
            try:
                time.sleep(.5)
                response = subprocess.run(['/usr/bin/curl', '-fsS', '--max-time', '15', '--noproxy', '', '--socks5-hostname', '127.0.0.1:19080', 'http://127.0.0.1:18080/payload'], capture_output=True, text=True)
                if response.returncode or response.stdout != 'fkgfw-smoke-success':
                    print(Path('/tmp/client.log').read_text()[-4000:]); print(Path('/tmp/sing-box.log').read_text()[-4000:])
                    raise RuntimeError('traffic check failed: ' + label)
            finally:
                proc.terminate(); proc.wait(timeout=5)
    print('PASS traffic:', ', '.join(selected), flush=True)


def migrate_old_deployment(sbox=False):
    folder = Path('/root/sbox' if sbox else '/root'); folder.mkdir(parents=True, exist_ok=True)
    binary = folder / 'sing-box'; config = folder / 'sbconfig_server.json'
    old = {'inbounds': [{'type': 'hysteria2', 'tag': 'hy2-in', 'listen_port': 10443,
                        'users': [{'password': 'old-password'}], 'tls': {'certificate_path': '/root/self-cert/cert.pem', 'key_path': '/root/self-cert/private.key'}}],
           'outbounds': [{'type': 'direct', 'tag': 'direct'}]}
    if sbox: old['inbounds'].append({'type': 'vmess', 'tag': 'vmess-in', 'listen_port': 18443, 'transport': {'type': 'ws'}})
    config.write_text(json.dumps(old))
    certificates = Path('/root/self-cert'); certificates.mkdir(exist_ok=True)
    (certificates / 'cert.pem').write_text('old certificate')
    (certificates / 'private.key').write_text('old private key')
    (folder / 'public.key.b64').write_text('old public key')
    shutil.copy2('/usr/bin/yes', binary)
    Path('/etc/systemd/system/sing-box.service').write_text(f'[Unit]\nDescription=sing-box service\n[Service]\nExecStart={binary} run -c {config}\n')
    proc = subprocess.Popen([str(binary), 'run', '-c', str(config)], stdout=subprocess.DEVNULL, start_new_session=True, env=dict(os.environ, POSIXLY_CORRECT='1'))
    Path('/tmp/service-sing-box').write_text(str(proc.pid)); Path('/tmp/service-sing-box.enabled').touch()
    tunnel = None
    if sbox:
        shutil.copy2('/usr/bin/yes', folder / 'cloudflared-linux')
        tunnel = subprocess.Popen([str(folder / 'cloudflared-linux'), 'tunnel', '--url', 'http://localhost:18443', '--no-autoupdate'], stdout=subprocess.DEVNULL, env=dict(os.environ, POSIXLY_CORRECT='1'))
    try:
        time.sleep(.1)
        invoke('cleanup.sh' if sbox else 'migration.sh', 'yes\n')
        assert proc.wait(timeout=5) != 0
        if tunnel: assert tunnel.wait(timeout=5) != 0
        assert not config.exists() and not binary.exists() and not CONFIG.exists()
        assert not Path('/etc/systemd/system/sing-box.service').exists()
        assert any((backup / 'files' / str(config).lstrip('/')).exists() for backup in Path('/var/backups/fkgfw').glob('cleanup.*'))
        print('PASS migration before install:', folder, flush=True)
    finally:
        for child in [proc, tunnel]:
            if child and child.poll() is None: child.terminate(); child.wait(timeout=5)


run('shellcheck', '--severity=error', '-x', 'install.sh', 'reality_hy2_ws.sh', 'migration.sh', 'cleanup.sh', *map(str, Path('lib').glob('*.sh')))
run('python3', 'tests/test-updates.py')
run('python3', 'tests/test-combinations.py')
run('python3', 'tests/test-cleanup.py')
run('python3', 'tests/test-client-exports.py')
run('openssl', 'req', '-x509', '-newkey', 'ec', '-pkeyopt', 'ec_paramgen_curve:prime256v1', '-nodes',
    '-keyout', '/tmp/origin.key', '-out', '/tmp/origin.pem', '-days', '1', '-subj', '/CN=example.com', stderr=subprocess.DEVNULL)
origin = subprocess.Popen(['openssl', 's_server', '-tls1_3', '-accept', '18446', '-cert', '/tmp/origin.pem', '-key', '/tmp/origin.key', '-www'], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
Path('/tmp/payload').write_text('fkgfw-smoke-success')
http = subprocess.Popen(['python3', '-m', 'http.server', '18080', '--bind', '127.0.0.1', '--directory', '/tmp'], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
try:
    combinations = [list(c) for n in range(1, 5) for c in itertools.combinations(TAGS, n)]
    for index, selected in enumerate(combinations):
        entry = 'install.sh' if index % 2 == 0 else 'reality_hy2_ws.sh'
        if index < 2: migrate_old_deployment(sbox=index == 1)
        invoke(entry, inputs(selected))
        validate(selected)
        assert Path('/etc/sing-box/public.key.b64').exists() == ('vless-in' in selected)
        assert Path('/etc/sing-box/certs/cert.pem').exists() == ('hy2-in' in selected)
        if index == 0:
            run('python3', 'tests/check-configs.py', env=dict(os.environ, SING_BOX_BINARY='/usr/local/bin/sing-box'))
        traffic(selected)
        if index != len(combinations) - 1: invoke(entry, '4\nyes\n')
    # Both entry points can manage every existing combination.
    previous = TAGS
    for selected in [['vless-in', 'vmess-in'], ['vless-in', 'hy2-in', 'vmess-in'], ['hy2-in'], ['hy2-in', 'vless-ws-in']]:
        old = json.loads(CONFIG.read_text())
        hostname = Path('/etc/sing-box/argo.txt.b64').read_bytes() if set(previous) & set(TAGS[2:]) else None
        invoke('install.sh', inputs(selected, existing=previous, manage=True))
        current = validate(selected)
        for inbound in old['inbounds']:
            if inbound['tag'] in selected: assert inbound == next(i for i in current['inbounds'] if i['tag'] == inbound['tag'])
        if hostname and set(selected) & set(TAGS[2:]): assert Path('/etc/sing-box/argo.txt.b64').read_bytes() == hostname
        traffic(selected)
        previous = selected
    # Editing a retained protocol changes its port without rotating credentials.
    old = json.loads(CONFIG.read_text())
    invoke('reality_hy2_ws.sh', '2\n2\n10455\n')
    current = json.loads(CONFIG.read_text())
    for inbound in old['inbounds']:
        if inbound['tag'] == 'hy2-in': inbound['listen_port'] = 10455
    assert old == current
    traffic(previous)
    invoke('install.sh', '4\nyes\n')
    print('PASS Linux: migration into both installers, 15 fresh installs, protocol transitions, editing, uninstall and local traffic', flush=True)
finally:
    origin.terminate(); origin.wait(timeout=5)
    http.terminate(); http.wait(timeout=5)
