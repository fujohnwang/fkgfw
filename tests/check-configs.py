#!/usr/bin/env python3
"""Check all 15 protocol combinations with the real sing-box executable."""
import itertools
import json
import os
from pathlib import Path
import subprocess
import tempfile
import yaml

ROOT = Path(__file__).resolve().parents[1]
BINARY = os.environ.get('SING_BOX_BINARY', 'sing-box')
TAGS = ['vless-in', 'hy2-in', 'vmess-in', 'vless-ws-in']


def run(*args, **kwargs):
    return subprocess.check_output(args, text=True, **kwargs)


def filter_json(name, data, **args):
    flags = [item for key, value in args.items() for item in ['--argjson', key, json.dumps(value)]]
    return json.loads(run('jq', *flags, '-f', str(ROOT / 'lib' / name), input=json.dumps(data)))


with tempfile.TemporaryDirectory(prefix='fkgfw-config-') as temp:
    tmp = Path(temp)
    run('openssl', 'req', '-x509', '-newkey', 'ec', '-pkeyopt', 'ec_paramgen_curve:prime256v1',
        '-nodes', '-keyout', str(tmp / 'private.key'), '-out', str(tmp / 'cert.pem'),
        '-days', '1', '-subj', '/CN=example.com', stderr=subprocess.DEVNULL)
    keys = dict(line.split(': ', 1) for line in run(BINARY, 'generate', 'reality-keypair').splitlines())
    params = dict(server_name='example.com', private_key=keys['PrivateKey'], short_id='0123456789abcdef',
                  uuid=run(BINARY, 'generate', 'uuid').strip(), password='test-password')
    inbounds = [filter_json('new-inbound.jq', dict(params, tag=tag, port=10443 + index, path='/ws' + str(index)))
                for index, tag in enumerate(TAGS)]
    inbounds[1]['tls'].update(certificate_path=str(tmp / 'cert.pem'), key_path=str(tmp / 'private.key'))
    base = {'log': {'level': 'info'}, 'inbounds': [], 'outbounds': [{'type': 'direct', 'tag': 'direct'}]}
    combinations = [list(c) for n in range(1, 5) for c in itertools.combinations(TAGS, n)]
    for selected in combinations:
        server = filter_json('server.jq', base, selected=selected, additions=inbounds)
        path = tmp / 'server.json'; path.write_text(json.dumps(server))
        run(BINARY, 'check', '-c', str(path))
        client = filter_json('client.jq', server, server_ip='2001:db8::1',
                             public_key=keys['PublicKey'] if 'vless-in' in selected else '',
                             certificate_name='example.com' if 'hy2-in' in selected else '',
                             argo='example.trycloudflare.com' if set(selected) & set(TAGS[2:]) else '')
        proxies = [o for o in client['outbounds'] if o['type'] in ['vless', 'vmess', 'hysteria2']]
        assert len(proxies) == len(selected)
        assert all(o.get('uuid') == params['uuid'] for o in proxies if 'uuid' in o)
        path = tmp / 'client.json'; path.write_text(json.dumps(client))
        run(BINARY, 'check', '-c', str(path))
        links = run('jq', '-r', '-f', str(ROOT / 'lib/links.jq'), input=json.dumps(client)).splitlines()
        assert len(links) == len(selected)
        if 'vless-in' in selected: assert any('@[2001:db8::1]:10443' in link for link in links)
        clash = filter_json('clash.jq', client)
        clash_yaml = run('jq', '-r', '-f', str(ROOT / 'lib/yaml.jq'), input=json.dumps(clash))
        assert yaml.safe_load(clash_yaml) == clash
        assert len(clash['proxies']) == len(selected)
        assert all(p.get('uuid') == params['uuid'] for p in clash['proxies'] if p['type'] != 'hysteria2')
        # All selection transitions preserve retained credentials, ports and custom fields.
        server['custom_check_marker'] = 'preserve'
        for target in combinations:
            merged = filter_json('server.jq', server, selected=target, additions=inbounds)
            assert merged['custom_check_marker'] == 'preserve'
            assert {i['tag'] for i in merged['inbounds']} == set(target)
            for old in server['inbounds']:
                if old['tag'] in target: assert old == next(i for i in merged['inbounds'] if i['tag'] == old['tag'])
        server.pop('custom_check_marker')
        # Old inbound options migrate without dropping credentials, also for WS-only installs.
        old = json.loads(json.dumps(server))
        old['inbounds'][0].update(sniff=True, sniff_override_destination=True, domain_strategy='ipv4_only')
        old['outbounds'].append({'type': 'block', 'tag': 'block'})
        old['route'] = {'rules': [{'domain': ['ads.example.com'], 'outbound': 'block'}]}
        migrated = filter_json('migrate-server.jq', old)
        assert migrated['inbounds'][0]['users'] == old['inbounds'][0]['users']
        assert migrated == filter_json('migrate-server.jq', migrated)
        path = tmp / 'migrated.json'; path.write_text(json.dumps(migrated))
        run(BINARY, 'check', '-c', str(path))
        print('PASS server/client/links/Mihomo/migration:', ', '.join(selected))
    # Remove stale rules aimed exclusively at removed inbounds, not custom traffic rules.
    base['inbounds'] = inbounds
    base['route'] = {'rules': [{'inbound': ['vless-in'], 'action': 'sniff'},
                              {'inbound': ['vless-in', 'hy2-in'], 'action': 'resolve'},
                              {'domain': ['example.com'], 'outbound': 'direct'}]}
    merged = filter_json('server.jq', base, selected=['hy2-in'], additions=[])
    assert len(merged['route']['rules']) == 2
    assert merged['route']['rules'][0]['inbound'] == ['hy2-in']
    print('PASS 15 combinations, 225 transitions, removed-inbound route cleanup')
