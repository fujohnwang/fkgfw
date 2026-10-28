#!/usr/bin/env python3
"""One-time cleanup before installing the new scripts, with an automatic backup.

No discovery by process name alone. CLI always uses the real root/procfs;
filesystem and command adapters are injectable only for isolated tests.
"""
import argparse
from dataclasses import dataclass, field
import fcntl
import json
import os
from pathlib import Path
import re
import select
import shlex
import shutil
import signal
import stat
import subprocess
import sys
import tempfile

if sys.version_info < (3, 9):
    raise SystemExit('错误: 清理脚本需要 Python 3.9+。')

CONFIGS = ['/root/sbconfig_server.json', '/root/sbox/sbconfig_server.json', '/etc/sing-box/config.json']
SB_PAIRS = {
    '/root/sing-box': CONFIGS[0],
    '/root/sbox/sing-box': CONFIGS[1],
    '/usr/local/bin/sing-box': CONFIGS[2],
}
UNITS = {name: f'/etc/systemd/system/{name}.service' for name in ['sing-box', 'caddy', 'cloudflared']}
MANAGED = {'vless-in': 'vless', 'hy2-in': 'hysteria2', 'vmess-in': 'vmess', 'vless-ws-in': 'vless'}


@dataclass(frozen=True)
class Process:
    pid: int
    start: str
    executable: str
    argv: tuple
    cgroup: str

    @property
    def binary(self):
        return self.executable.removesuffix(' (deleted)')


@dataclass
class Plan:
    files: dict = field(default_factory=dict)
    services: dict = field(default_factory=dict)
    processes: list = field(default_factory=list)
    notes: list = field(default_factory=list)

    def note(self, message):
        if message not in self.notes:
            self.notes.append(message)


class Cleaner:
    def __init__(self, root=Path('/'), proc=Path('/proc'), runner=None, terminator=None):
        self.root = Path(root)
        self.proc = Path(proc)
        self.runner = runner or self.run_command
        self.terminator = terminator or self.terminate
        if self.proc != Path('/proc') and terminator is None:
            raise ValueError('Fixture procfs requires an explicit test terminator')
        self.configs = {}
        self.units = {}
        self.caddy_port = None

    @staticmethod
    def run_command(args):
        return subprocess.run(args, text=True, capture_output=True, check=False)

    def path(self, name):
        return self.root / name.lstrip('/')

    def safe(self, name):
        """Do not cross symlinked directories or operate on a symlink target."""
        target = self.root
        for part in Path(name).parts[1:]:
            target /= part
            if target.is_symlink():
                return False
        return True

    def regular(self, name):
        return self.safe(name) and self.path(name).is_file()

    def text(self, name):
        if not self.regular(name):
            return ''
        return self.path(name).read_text(errors='replace')

    def property(self, service, key):
        result = self.runner(['systemctl', 'show', service + '.service', '--property=' + key, '--value'])
        if result.returncode:
            raise RuntimeError(f'无法查询 {service} 的 {key}；停止清理，未假定服务不存在。')
        return result.stdout.strip()

    @staticmethod
    def signature(value):
        if not isinstance(value, dict) or not isinstance(value.get('inbounds'), list):
            return False
        if not all(isinstance(i, dict) for i in value['inbounds']) or not isinstance(value.get('outbounds'), list):
            return False
        known = [i for i in value['inbounds'] if isinstance(i, dict) and i.get('tag') in MANAGED]
        if not known or any(i.get('type') != MANAGED[i['tag']] for i in known):
            return False
        for inbound in known:
            if inbound['tag'] == 'vless-in':
                tls = inbound.get('tls')
                reality = tls.get('reality') if isinstance(tls, dict) else None
                if not isinstance(reality, dict) or reality.get('enabled') is not True:
                    return False
            if inbound['tag'] in ['vmess-in', 'vless-ws-in']:
                transport = inbound.get('transport')
                if not isinstance(transport, dict) or transport.get('type') != 'ws':
                    return False
        return any(isinstance(o, dict) and o.get('type') == 'direct' for o in value.get('outbounds', []))

    def read_configs(self):
        self.configs = {}
        for name in CONFIGS:
            try:
                value = json.loads(self.text(name))
                if self.signature(value):
                    self.configs[name] = value
            except (ValueError, TypeError):
                pass

    def caddy_signature(self):
        value = self.text('/etc/caddy/Caddyfile')
        match = re.fullmatch(
            r'\s*\{\s*auto_https off\s+admin off\s*\}\s*:(\d+)\s*\{\s*'
            r'(?:bind 127\.0\.0\.1\s+)?((?:handle /[A-Za-z0-9_/-]+\*?\s*\{\s*'
            r'reverse_proxy (?:localhost|127\.0\.0\.1):\d+\s*\}\s*)+)respond 404\s*\}\s*', value)
        return match.group(1) if match else None

    def command_role(self, executable, argv):
        if not argv:
            return None
        args = list(argv[1:])
        if executable in SB_PAIRS and args == ['run', '-c', SB_PAIRS[executable]]:
            config = SB_PAIRS[executable]
            if config in self.configs:
                return 'modern' if config == CONFIGS[2] else 'legacy'
        if executable == '/usr/local/bin/caddy' and args == ['run', '--config', '/etc/caddy/Caddyfile'] and self.caddy_port:
            return 'modern'
        if executable not in ['/root/sbox/cloudflared-linux', '/usr/local/bin/cloudflared'] or not args or args.pop(0) != 'tunnel':
            return None
        options = {}
        while args:
            key = args.pop(0)
            if key in options:
                return None
            if key == '--no-autoupdate':
                options[key] = True
            elif key in ['--url', '--edge-ip-version', '--protocol', '--logfile'] and args:
                options[key] = args.pop(0)
            else:
                return None  # Includes named/token tunnels and unknown subcommands.
        if options.get('--logfile', '/var/log/cloudflared.log') != '/var/log/cloudflared.log':
            return None
        url = re.fullmatch(r'http://(?:localhost|127\.0\.0\.1):(\d+)', str(options.get('--url', '')))
        if not url:
            return None
        if executable == '/usr/local/bin/cloudflared' and url.group(1) == self.caddy_port:
            return 'modern'
        if executable == '/root/sbox/cloudflared-linux':
            ports = [str(i.get('listen_port')) for i in self.configs.get(CONFIGS[1], {}).get('inbounds', []) if i.get('tag') == 'vmess-in']
            if url.group(1) in ports:
                return 'legacy'
        return None

    def read_unit(self, name, plan):
        filename = UNITS[name]
        if not self.path(filename).exists() and not self.path(filename).is_symlink():
            return None
        if not self.regular(filename):
            plan.note(f'保留 {filename}：符号链接或非普通文件。')
            return None
        section = ''; values = {}
        for line in self.text(filename).splitlines():
            line = line.strip()
            if line.startswith('['):
                section = line
            elif line and not line.startswith(('#', ';')) and '=' in line:
                key, value = line.split('=', 1)
                values.setdefault((section, key), []).append(value)
        descriptions = {'sing-box': 'sing-box service', 'caddy': 'Caddy Local Reverse Proxy', 'cloudflared': 'Cloudflared Tunnel'}
        starts = values.get(('[Service]', 'ExecStart'), [])
        if values.get(('[Unit]', 'Description')) != [descriptions[name]] or len(starts) != 1:
            plan.note(f'保留 {filename}：服务定义与本项目不匹配。')
            return None
        try:
            argv = shlex.split(starts[0])
        except ValueError:
            argv = []
        role = self.command_role(argv[0], argv) if argv else None
        if not role:
            plan.note(f'保留 {filename}：启动参数或配置无法确认归属。')
            return None
        # Effective units may differ from the file due to overrides or stale loads.
        if self.property(name, 'FragmentPath') != filename or self.property(name, 'DropInPaths') or self.property(name, 'NeedDaemonReload') == 'yes':
            plan.note(f'保留 {filename}：存在覆盖配置、其他加载路径或尚未 reload 的变更。')
            return None
        return {'role': role, 'binary': argv[0], 'active': self.property(name, 'ActiveState'),
                'enabled': self.property(name, 'UnitFileState'), 'path': filename}

    def process(self, pid):
        directory = self.proc / str(pid)
        try:
            raw_stat = (directory / 'stat').read_text()
            tail = raw_stat.rsplit(') ', 1)[1].split()
            if tail[0] == 'Z':
                return None
            argv = tuple(os.fsdecode(a) for a in (directory / 'cmdline').read_bytes().split(b'\0') if a)
            return Process(int(pid), tail[19], os.readlink(directory / 'exe'), argv, (directory / 'cgroup').read_text())
        except (FileNotFoundError, ProcessLookupError, IndexError):
            return None
        except PermissionError as error:
            raise RuntimeError(f'无法检查 PID {pid}，停止清理。') from error

    def processes(self):
        found = []
        for directory in self.proc.iterdir():
            if directory.name.isdigit():
                value = self.process(int(directory.name))
                if value:
                    found.append(value)
        return found

    @staticmethod
    def groups(process):
        return set(re.findall(r'/([^/\n]+\.service)(?:/|$)', process.cgroup, re.MULTILINE))

    @staticmethod
    def references(process, name):
        refs = [process.binary]
        for arg in process.argv[1:]:
            # Also protect paths supplied as --config=/path/to/config.json.
            refs.append(arg.split('=', 1)[1] if arg.startswith('-') and '=' in arg else arg)
        return any(ref == name or ref.startswith(name + '/') for ref in refs)

    def fingerprint(self, name):
        target = self.path(name)
        value = target.lstat()
        record = self.file_stat(target)
        if stat.S_ISDIR(value.st_mode):
            return record, tuple((str(p.relative_to(target)), self.file_stat(p)) for p in sorted(target.rglob('*')))
        return record

    @staticmethod
    def file_stat(path):
        value = path.lstat()
        return value.st_dev, value.st_ino, value.st_mode, value.st_size, value.st_mtime_ns, value.st_uid, value.st_gid

    def add_file(self, plan, name, reason):
        if not self.path(name).exists() and not self.path(name).is_symlink():
            return
        if not self.safe(name):
            plan.note(f'保留 {name}：路径包含符号链接。')
            return
        if not (self.path(name).is_file() or self.path(name).is_dir()):
            plan.note(f'保留 {name}：不是普通文件或目录。')
            return
        if any(name == parent or name.startswith(parent + '/') for parent in plan.files):
            return
        plan.files[name] = {'reason': reason, 'fingerprint': self.fingerprint(name)}

    def plan(self):
        plan = Plan()
        self.read_configs()
        self.caddy_port = self.caddy_signature()
        self.units = {name: self.read_unit(name, plan) for name in UNITS}
        for name, unit in self.units.items():
            if unit:
                plan.services[name] = unit
                self.add_file(plan, unit['path'], '本项目服务定义')
        for binary, config in SB_PAIRS.items():
            if config not in self.configs:
                if self.path(binary).exists(): plan.note(f'保留 {binary}：没有可确认归属的配置。')
                continue
            modern = config == CONFIGS[2]
            if self.path(UNITS['sing-box']).exists() and not self.units['sing-box']:
                plan.note(f'保留 {binary} 及配置：sing-box 服务归属不明确。')
                continue
            self.add_file(plan, binary, '本项目程序')
            if modern:
                self.add_file(plan, '/etc/sing-box', '本项目配置、密钥和客户端文件')
            else:
                folder = str(Path(config).parent)
                for leaf in ['sbconfig_server.json', 'sbconfig_client.json', 'public.key.b64', 'argo.txt.b64']:
                    self.add_file(plan, folder + '/' + leaf, '旧版配置或密钥')
                for leaf in ['cert.pem', 'private.key']:
                    certificate = '/root/self-cert/' + leaf
                    if certificate in json.dumps(self.configs[config]):
                        self.add_file(plan, certificate, '旧版证书或私钥')
        if CONFIGS[1] in self.configs:
            if not self.path(UNITS['cloudflared']).exists() or self.units['cloudflared']:
                self.add_file(plan, '/root/sbox/cloudflared-linux', '旧版 Quick Tunnel 程序')
        for name in ['caddy', 'cloudflared']:
            if name in plan.services:
                self.add_file(plan, plan.services[name]['binary'], '本项目辅助程序')
                if name == 'caddy': self.add_file(plan, '/etc/caddy/Caddyfile', '本项目反向代理配置')
                if name == 'cloudflared':
                    self.add_file(plan, '/usr/local/bin/cloudflared-post-start.sh', '本项目 Tunnel 辅助脚本')
                    self.add_file(plan, '/var/log/cloudflared.log', '本项目 Tunnel 日志')
        # Only exact download filenames used by historical installers.
        if self.configs and self.safe('/root') and self.path('/root').is_dir():
            pattern = r'sing-box-\d+\.\d+\.\d+(?:-[A-Za-z0-9.-]+)?-linux-(?:amd64|arm64|armv7)\.tar\.gz(?:\.sha256sum)?'
            for archive in self.path('/root').iterdir():
                if re.fullmatch(pattern, archive.name):
                    self.add_file(plan, '/root/' + archive.name, '历史安装包或校验文件')
        all_processes = self.processes()
        for process in all_processes:
            role = self.command_role(process.binary, process.argv)
            relevant = process.binary in list(SB_PAIRS) + ['/root/sbox/cloudflared-linux', '/usr/local/bin/cloudflared', '/usr/local/bin/caddy']
            if not relevant:
                continue
            if not role:
                plan.note(f'保留 PID {process.pid}：启动参数无法确认归属。')
                continue
            groups = self.groups(process)
            allowed = {name + '.service' for name in plan.services}
            if groups - allowed:
                plan.note(f'保留 PID {process.pid}：属于未纳入清理的服务控制组。')
                continue
            plan.processes.append(process)
        # Any surviving process referencing a candidate prevents deleting it.
        removable = {p.pid for p in plan.processes}
        for process in all_processes:
            if process.pid in removable:
                continue
            for name in list(plan.files):
                if self.references(process, name):
                    plan.files.pop(name)
                    plan.note(f'保留 {name}：仍由未清理的 PID {process.pid} 使用。')
        self.protect_other_units(plan)
        # A retained deployment may still reference certificates in an old
        # directory even when another old deployment is eligible for cleanup.
        for config, value in self.configs.items():
            if any(config == name or config.startswith(name + '/') for name in plan.files):
                continue
            serialized = json.dumps(value)
            for name in list(plan.files):
                if name in serialized:
                    plan.files.pop(name)
                    plan.note(f'保留 {name}：保留的配置 {config} 仍引用该路径。')
        return plan

    def protect_other_units(self, plan):
        selected = {unit['path'] for unit in plan.services.values()}
        for folder in ['/etc/systemd/system', '/run/systemd/system', '/usr/lib/systemd/system', '/lib/systemd/system']:
            if not self.path(folder).is_dir(): continue
            units = list(self.path(folder).glob('*.service')) + list(self.path(folder).glob('*.service.d/*.conf'))
            for unit in units:
                filename = '/' + str(unit.relative_to(self.root))
                if filename in selected or not unit.is_file(): continue
                content = unit.read_text(errors='replace')
                for name in list(plan.files):
                    if re.search(re.escape(name) + r'(?=[\s/"\x27;]|$)', content):
                        plan.files.pop(name)
                        plan.note(f'保留 {name}：其他服务定义 {filename} 仍引用该路径。')

    @staticmethod
    def show(plan):
        print('迁移准备：备份并清理已有部署，然后使用新版安装脚本重新安装。')
        for name in sorted(plan.services): print(f'停止并禁用服务: {name}')
        for process in plan.processes: print(f'终止进程: PID {process.pid}  {process.binary}')
        for name, detail in plan.files.items(): print(f'备份后删除: {name}（{detail["reason"]}）')
        for message in plan.notes: print(message)
        print(f'计划: {len(plan.services)} 个服务、{len(plan.processes)} 个进程、{len(plan.files)} 个文件/目录。')

    def terminate(self, process):
        current = self.process(process.pid)
        if current is None: return
        if current != process:
            raise RuntimeError(f'PID {process.pid} 的身份已变化，未发送信号。')
        if not hasattr(os, 'pidfd_open') or not hasattr(signal, 'pidfd_send_signal'):
            raise RuntimeError('系统不支持 pidfd，保留独立进程；需要 Python 3.9+ 和支持 pidfd 的 Linux 内核。')
        try:
            descriptor = os.pidfd_open(process.pid)
        except ProcessLookupError:
            return
        try:
            current = self.process(process.pid)
            if current is None:
                return
            if current != process:
                raise RuntimeError(f'PID {process.pid} 的身份已变化，未发送信号。')
            signal.pidfd_send_signal(descriptor, signal.SIGTERM)
            poller = select.poll(); poller.register(descriptor, select.POLLIN)
            if not poller.poll(10000):
                raise RuntimeError(f'PID {process.pid} 未在 10 秒内退出，停止删除文件；请检查进程后重试。')
        finally:
            os.close(descriptor)

    def verify_files(self, plan):
        for name, detail in plan.files.items():
            if not self.safe(name) or not self.path(name).exists() or self.fingerprint(name) != detail['fingerprint']:
                raise RuntimeError(f'{name} 在扫描后发生变化，停止清理。')

    @staticmethod
    def copy_backup(source, target):
        if source.is_dir(): shutil.copytree(source, target, symlinks=True)
        else: shutil.copy2(source, target)
        # copy2 preserves mode/timestamps but not ownership. Retain service
        # account ownership so a cp -a restore can read private configuration.
        originals = [source] + (list(source.rglob('*')) if source.is_dir() else [])
        for original in originals:
            destination = target / original.relative_to(source)
            before = original.lstat(); after = destination.lstat()
            if (before.st_uid, before.st_gid) != (after.st_uid, after.st_gid):
                os.chown(destination, before.st_uid, before.st_gid, follow_symlinks=False)

    def apply(self, plan):
        if not plan.files and not plan.services and not plan.processes:
            print('没有可自动清理的项目。')
            return None
        self.verify_files(plan)
        folder = '/var/backups/fkgfw'
        if not self.safe(folder): raise RuntimeError('备份目录包含符号链接，停止清理。')
        self.path(folder).mkdir(parents=True, exist_ok=True)
        backup = Path(tempfile.mkdtemp(prefix='cleanup.', dir=self.path(folder)))
        os.chmod(backup, 0o700)
        # Complete and verify every backup before stopping any service/process.
        for name in plan.files:
            source = self.path(name); target = backup / 'files' / name.lstrip('/')
            target.parent.mkdir(parents=True, exist_ok=True)
            self.copy_backup(source, target)
        self.verify_files(plan)
        manifest = {'mode': 'migration', 'files': list(plan.files),
                    'services': plan.services, 'pids': [p.pid for p in plan.processes], 'notes': plan.notes}
        (backup / 'manifest.json').write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + '\n')
        print(f'备份完成: {backup}', flush=True)
        for name, unit in plan.services.items():
            # Recheck effective ownership immediately before service operations.
            if self.read_unit(name, Plan()) != unit:
                raise RuntimeError(f'{name} 服务状态或定义已变化，停止清理。')
            result = self.runner(['systemctl', 'stop', name + '.service'])
            if result.returncode or self.property(name, 'ActiveState') not in ['inactive', 'failed']:
                raise RuntimeError(f'{name} 未能停止；文件保留，备份位于 {backup}。')
        for process in plan.processes:
            self.terminator(process)
        # Detect respawns and any newly started process before deleting files.
        for process in self.processes():
            if any(self.references(process, name) for name in plan.files):
                raise RuntimeError(f'PID {process.pid} 仍使用待清理文件，停止删除；备份位于 {backup}。')
        # Cloudflared can append shutdown messages after the initial backup.
        # Keep both snapshots, then verify the stopped log like any other file.
        log = '/var/log/cloudflared.log'
        if log in plan.files:
            if not self.regular(log): raise RuntimeError('Tunnel 日志路径已变化，停止删除。')
            self.copy_backup(self.path(log), backup / 'cloudflared-stopped.log')
            plan.files[log]['fingerprint'] = self.fingerprint(log)
        self.verify_files(plan)
        for name in plan.services:
            result = self.runner(['systemctl', 'disable', name + '.service'])
            if result.returncode: raise RuntimeError(f'禁用 {name} 失败，停止删除文件；备份位于 {backup}。')
        for name in sorted(plan.files, key=lambda p: len(Path(p).parts), reverse=True):
            target = self.path(name)
            if target.is_dir(): shutil.rmtree(target)
            else: target.unlink()
        if plan.services:
            if self.runner(['systemctl', 'daemon-reload']).returncode:
                raise RuntimeError(f'文件已清理，但 daemon-reload 失败；备份位于 {backup}。')
        # Only remove known directories if empty, preserving unrelated files.
        for name in ['/root/sbox', '/root/self-cert', '/etc/caddy']:
            if any(item.startswith(name + '/') for item in plan.files) and self.safe(name) and self.path(name).is_dir():
                try: self.path(name).rmdir()
                except OSError: pass
        print('计划内清理完成；所有升级备份及迁移标记均保留。')
        if plan.notes: print('部分项目被保留，请查看上面的说明。')
        return backup

    def check_ready(self):
        # Retained conflicting paths must not silently lead into a fresh install.
        names = CONFIGS + list(SB_PAIRS) + list(UNITS.values()) + [
            '/root/sbox/cloudflared-linux', '/usr/local/bin/caddy', '/usr/local/bin/cloudflared',
            '/etc/caddy/Caddyfile', '/usr/local/bin/cloudflared-post-start.sh']
        remaining = [name for name in names if self.path(name).exists() or self.path(name).is_symlink()]
        remaining += [f'PID {p.pid} ({p.binary})' for p in self.processes() if p.binary in names]
        if remaining:
            raise RuntimeError('以下部署路径或进程仍保留，请根据扫描提示处理后再安装：' + '、'.join(remaining))


def main(argv=None):
    parser = argparse.ArgumentParser(prog='migration.sh', description='切换到新版前运行一次：确认后备份并清理已有部署，再运行 install.sh 或 reality_hy2_ws.sh。')
    options = parser.add_mutually_exclusive_group()
    options.add_argument('--dry-run', action='store_true', help='仅预览，不停止服务或修改文件')
    options.add_argument('-y', '--yes', '--apply', dest='yes', action='store_true', help='跳过交互确认，执行备份和清理（--apply 为兼容别名）')
    parser.add_argument('--reset', action='store_true', help=argparse.SUPPRESS)  # Compatibility; cleanup now always prepares a fresh install.
    args = parser.parse_args(argv)
    if sys.platform != 'linux' or os.geteuid() != 0:
        parser.error('请在 Linux 服务器上以 root 权限运行。')
    os.umask(0o077)
    cleaner = Cleaner()
    lock = None
    try:
        plan = cleaner.plan()
        cleaner.show(plan)
        if args.dry_run:
            print('仅预览；直接运行 sudo bash migration.sh 可确认并执行。')
            return 0
        if plan.files or plan.services or plan.processes:
            if not args.yes:
                try:
                    answer = input('这会停止已有部署，配置与密钥将先备份。输入 yes 开始迁移准备: ')
                except EOFError:
                    answer = ''
                if answer.strip().lower() != 'yes':
                    print('已取消，未修改部署。')
                    return 1
            if not cleaner.safe('/run/lock'):
                raise RuntimeError('锁目录包含符号链接，停止清理。')
            cleaner.path('/run/lock').mkdir(parents=True, exist_ok=True)
            lock = os.open(cleaner.path('/run/lock/fkgfw.lock'), os.O_WRONLY | os.O_CREAT | os.O_NOFOLLOW, 0o600)
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            if cleaner.plan() != plan:
                raise RuntimeError('部署在扫描后发生变化，请重新运行脚本检查；未执行清理。')
            cleaner.apply(plan)
        cleaner.check_ready()
        print('迁移准备完成。下一步二选一：sudo bash install.sh 或 sudo bash reality_hy2_ws.sh。')
        print('新版安装会生成新的配置和认证信息；后续管理直接使用新版安装入口，无需再次运行本脚本。')
    except BlockingIOError:
        print('错误: 另一个安装、升级或清理进程正在运行。', file=sys.stderr)
        return 1
    except (OSError, RuntimeError, ValueError) as error:
        print(f'错误: {error}', file=sys.stderr)
        return 1
    finally:
        if lock is not None: os.close(lock)
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
