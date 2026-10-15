"""Failure-path regression tests. All effects stay in TemporaryDirectory."""
import pathlib
import configparser
import subprocess
import tempfile
import unittest

SCRIPT = pathlib.Path(__file__).resolve().parents[1] / 'MTP一键部署.sh'
VALID_CONFIG = ('PORT=8443\nSTATS_PORT=8888\n'
                'SECRET=0123456789abcdef0123456789abcdef\n'
                'DOMAIN=example.com\nSERVER=example.com\nTAG=\n')

# GNU stat/sha256sum adapters for macOS. Ownership is simulated; file identity,
# bytes, hardlink counts and permission bits use real temporary files.
PORTABLE_TOOLS = '''
    no_mounts() { :; };
    stat() { python3 -c 'import os,sys,stat
s=os.stat(sys.argv[-1], follow_symlinks=False)
print({"%u":0,"%g":991,"%h":s.st_nlink,"%a":oct(stat.S_IMODE(s.st_mode))[2:],"%d:%i":str(s.st_dev)+":"+str(s.st_ino)}[sys.argv[2]])' "$@"; };
    sha256sum() { python3 -c 'import hashlib,sys
for p in sys.argv[1:]:
 if p != "--": print(hashlib.sha256(open(p,"rb").read()).hexdigest()+"  "+p)' "$@"; };
'''


def install_mocks(base):
    return f'''APP="{base}/app"; CONFIG="{base}/config"; LOG="{base}/log";
        UNIT="{base}/unit"; TIMER="{base}/timer"; REFRESH="{base}/refresh"; ROTATE="{base}/rotate";
        root_only() {{ :; }}; preflight() {{ :; }}; lock() {{ :; }};
        ss() {{ :; }}; docker() {{ return 1; }};
        getent() {{ if [[ $1 == passwd && $# == 1 ]]; then return 0; else return 2; fi; }};
        groupadd() {{ :; }}; useradd() {{ :; }}; chown() {{ :; }};
        userdel() {{ echo userdel >> "{base}/calls"; }}; groupdel() {{ echo groupdel >> "{base}/calls"; }};
        id() {{ echo 991; }};
        {PORTABLE_TOOLS}
        sha256sum() {{ if [[ $1 == -c ]]; then cat >/dev/null;
            else python3 -c 'import hashlib,sys
for p in sys.argv[1:]:
 if p != "--": print(hashlib.sha256(open(p,"rb").read()).hexdigest()+"  "+p)' "$@"; fi; }};
        mktemp() {{ if [[ $1 == -d ]]; then mkdir "{base}/work"; echo "{base}/work";
            else command mktemp "$@"; fi; }};
        fetch() {{ case "$1" in *getProxySecret) printf '%064d' 0 > "$2";;
            *getProxyConfig) echo 'proxy_for 2 149.154.167.51:8888;' > "$2";; *) echo archive > "$2";; esac; }};
        tar() {{ if [[ $1 == -tzf ]]; then echo engine/Makefile; else touch "$4/Makefile"; fi; }};
        make() {{ mkdir -p "$2/objs/bin"; touch "$2/objs/bin/mtproto-proxy"; chmod 755 "$2/objs/bin/mtproto-proxy"; }};
        install() {{ local mode=$2; shift 2; if [[ $1 == -g ]]; then shift 2; fi; cp "$1" "$2"; chmod "$mode" "$2"; }};
        systemd-analyze() {{ :; }}; wait_running() {{ :; }};
        systemctl() {{ mock_systemctl "$@"; }};
        mock_systemctl() {{ echo "$*" >> "{base}/calls";
            if [[ ${{3:-}} == LoadState ]]; then echo not-found;
            elif [[ ${{3:-}} == FragmentPath ]]; then case "${{@: -1}}" in
                mtp.service) [[ ! -e $UNIT ]] || echo "$UNIT";;
                mtp-refresh.service) [[ ! -e $REFRESH ]] || echo "$REFRESH";;
                mtp-refresh.timer) [[ ! -e $TIMER ]] || echo "$TIMER";; esac; fi; }};
    '''


class DeepSafetyTests(unittest.TestCase):
    def run_function(self, code, input=None):
        return subprocess.run(['bash', '-c', 'source "$1"; ' + code,
                               'test', str(SCRIPT)], input=input,
                              capture_output=True, text=True, errors='replace')

    def test_config_rejects_malformed_bytes_and_records(self):
        cases = {
            'unterminated unknown field': VALID_CONFIG + 'UNKNOWN=keep',
            'nul silently discarded by shell': VALID_CONFIG.replace('PORT=8443', 'PORT=84\0' + '43'),
            'blank line': VALID_CONFIG + '\n',
            'empty required field': VALID_CONFIG.replace('DOMAIN=example.com', 'DOMAIN='),
            'duplicate': VALID_CONFIG.replace('SERVER=example.com', 'DOMAIN=example.com'),
            'long field': VALID_CONFIG.replace('TAG=', 'TAG=' + 'a' * 20000),
            'special character': VALID_CONFIG.replace('DOMAIN=example.com', 'DOMAIN=$(id)'),
            'bad secret': VALID_CONFIG.replace('0123456789abcdef0123456789abcdef', 'not-a-secret'),
        }
        with tempfile.TemporaryDirectory() as tmp:
            for name, config in cases.items():
                with self.subTest(name=name):
                    (pathlib.Path(tmp) / 'mtp.conf').write_bytes(config.encode())
                    result = self.run_function(f'CONFIG="{tmp}"; load_config')
                    self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_valid_last_field_without_newline(self):
        with tempfile.TemporaryDirectory() as tmp:
            (pathlib.Path(tmp) / 'mtp.conf').write_text(VALID_CONFIG.rstrip('\n'))
            result = self.run_function(f'CONFIG="{tmp}"; load_config; show_link')
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn('port=8443', result.stdout)

    def test_uninstall_rechecks_after_confirmation(self):
        with tempfile.TemporaryDirectory() as tmp:
            base = pathlib.Path(tmp)
            for name in ('app', 'config', 'log'):
                (base / name).mkdir()
            result = self.run_function(f'''APP="{base}/app"; CONFIG="{base}/config"; LOG="{base}/log";
                UNIT="{base}/unit"; TIMER="{base}/timer"; REFRESH="{base}/refresh"; ROTATE="{base}/rotate";
                root_only() {{ :; }}; lock() {{ :; }}; owner_check() {{ :; }}; account_check() {{ :; }};
                read() {{ if [[ "$*" == *'输入 YES'* ]]; then echo keep > "$APP/user-data"; answer=YES;
                    else builtin read "$@"; fi; }};
                systemctl() {{ if [[ ${{3:-}} == LoadState ]]; then echo not-found; fi; }};
                getent() {{ return 2; }}; port_lines() {{ :; }};
                uninstall_proxy''')
            self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertEqual((base / 'app' / 'user-data').read_text(), 'keep\n')

    def test_uninstall_rejects_directory_disguised_as_rotated_log(self):
        with tempfile.TemporaryDirectory() as tmp:
            base = pathlib.Path(tmp)
            for name in ('app', 'config', 'log', 'log/mtp.log.1'):
                (base / name).mkdir()
            result = self.run_function(f'APP="{base}/app"; CONFIG="{base}/config"; LOG="{base}/log"; no_unrelated_files')
            self.assertNotEqual(result.returncode, 0, result.stderr)

    def test_uninstall_rejects_hardlinked_file(self):
        with tempfile.TemporaryDirectory() as tmp:
            import os
            base = pathlib.Path(tmp)
            for name in ('app', 'config', 'log'):
                (base / name).mkdir()
            (base / 'external').write_text('keep')
            os.link(base / 'external', base / 'log' / 'mtp.log.1')
            result = self.run_function(f'''APP="{base}/app"; CONFIG="{base}/config"; LOG="{base}/log";
                stat() {{ python3 -c 'import os,sys; print(os.stat(sys.argv[-1]).st_nlink)' "$@"; }}; no_unrelated_files''')
            self.assertNotEqual(result.returncode, 0, result.stderr)
            self.assertEqual((base / 'external').read_text(), 'keep')

    def test_fetch_partial_failure_is_not_success_in_conditional(self):
        with tempfile.TemporaryDirectory() as tmp:
            result = self.run_function(f'''curl() {{ echo partial > "${{@: -1}}"; return 28; }};
                if fetch https://core.telegram.org/getProxyConfig "{tmp}/partial"; then echo ACCEPTED; fi''')
            self.assertNotIn('ACCEPTED', result.stdout)

    def test_install_rolls_back_each_failure_stage(self):
        stages = {
            'download': 'fetch() { echo interrupted > "$2"; return 28; };',
            'compile': 'make() { return 2; };',
            'useradd': 'useradd() { return 1; };',
            'reload': 'systemctl() { if [[ $1 == daemon-reload ]]; then return 1; elif [[ ${3:-} == LoadState ]]; then echo not-found; fi; };',
            'start': 'wait_running() { return 1; };',
            'enable': 'systemctl() { if [[ $1 == enable && $3 == mtp.service ]]; then return 1; else mock_systemctl "$@"; fi; };',
            'timer': 'systemctl() { if [[ $1 == enable && $3 == mtp-refresh.timer ]]; then return 1; else mock_systemctl "$@"; fi; };',
            'signal': 'make() { kill -TERM "$(exec python3 -c \'import os; print(os.getppid())\')"; };',
            # The empty directory exists before its marker can be written.
            'marker write': '''printf() { if [[ $1 == 'mtp-owned-v1\\n' ]]; then return 1; else builtin printf "$@"; fi; };''',
            # Incomplete file has no marker and must still be owned by this transaction.
            'partial unit': '''cat() { if [[ $# == 0 && -e $UNIT ]]; then echo partial; return 1; else command cat "$@"; fi; };''',
        }
        for name, failure in stages.items():
            with self.subTest(stage=name), tempfile.TemporaryDirectory() as tmp:
                result = self.run_function(install_mocks(tmp) + failure + 'install_proxy --server example.com')
                self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
                if name == 'signal':
                    self.assertEqual(result.returncode, 143)
                for path in ('work', 'app', 'config', 'log', 'unit', 'timer', 'refresh', 'rotate'):
                    self.assertFalse((pathlib.Path(tmp) / path).exists(), (name, path, result.stderr))

    def test_manifest_refuses_modified_unit_and_replaced_directory(self):
        for mutation in ('unit', 'directory'):
            with self.subTest(mutation=mutation), tempfile.TemporaryDirectory() as tmp:
                base = pathlib.Path(tmp)
                for name in ('app', 'app/bin', 'config', 'log'):
                    (base / name).mkdir()
                for name in ('app/mtp', 'app/bin/mtproto-proxy', 'config/account', 'unit', 'timer', 'refresh', 'rotate'):
                    (base / name).write_text('original\n')
                change = ('echo malicious >> "$UNIT";' if mutation == 'unit' else
                          'mv "$LOG" "$LOG.old"; mkdir "$LOG";')
                result = self.run_function(f'''APP="{base}/app"; CONFIG="{base}/config"; LOG="{base}/log";
                    UNIT="{base}/unit"; TIMER="{base}/timer"; REFRESH="{base}/refresh"; ROTATE="{base}/rotate";
                    {PORTABLE_TOOLS}
                    manifest_content > "$CONFIG/manifest"; chmod 600 "$CONFIG/manifest";
                    {change} manifest_check''')
                self.assertNotEqual(result.returncode, 0)
                self.assertIn('归属记录', result.stderr)

    def refresh_fixture(self, base, new, extra=''):
        path = pathlib.Path(base) / 'proxy-multi.conf'
        path.write_text('proxy_for 2 149.154.167.51:8888;\n')
        code = f'''CONFIG="{base}";
            root_only() {{ :; }}; lock() {{ :; }}; owner_check() {{ :; }};
            load_config() {{ PORT=8443; }}; runtime_permissions() {{ :; }};
            systemctl() {{ if [[ $1 == restart ]]; then echo restarted >> "{base}/calls"; fi; }};
            wait_running() {{ :; }};
            fetch() {{ printf '%s' '{new}' > "$2"; }};
            {extra} refresh_proxy'''
        return self.run_function(code)

    def test_refresh_unchanged_data_does_not_interrupt_service(self):
        with tempfile.TemporaryDirectory() as tmp:
            result = self.refresh_fixture(tmp, 'proxy_for 2 149.154.167.51:8888;\n')
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertFalse((pathlib.Path(tmp) / 'calls').exists())
            self.assertEqual([p.name for p in pathlib.Path(tmp).iterdir()], ['proxy-multi.conf'])

    def test_refresh_rejects_corrupt_payload_before_restart(self):
        payloads = ('proxy_for broken\n', 'proxy_for 2 149.154.167.51:65536;\n',
                    'proxy_for 2 149.154.167.51:8888;\n<html>error</html>')
        for payload in payloads:
            with self.subTest(payload=payload), tempfile.TemporaryDirectory() as tmp:
                result = self.refresh_fixture(tmp, payload)
                self.assertNotEqual(result.returncode, 0, result.stderr)
                self.assertFalse((pathlib.Path(tmp) / 'calls').exists())
                self.assertEqual((pathlib.Path(tmp) / 'proxy-multi.conf').read_text(),
                                 'proxy_for 2 149.154.167.51:8888;\n')

    def test_refresh_signal_after_atomic_rename_restores_old_data(self):
        with tempfile.TemporaryDirectory() as tmp:
            result = self.refresh_fixture(tmp, 'proxy_for 3 149.154.175.100:8888;\n', extra='''
                mv() { command mv "$@"; if [[ $3 == *'/.new.'* ]]; then kill -TERM "$(exec python3 -c 'import os; print(os.getppid())')"; fi; };
            ''')
            self.assertEqual(result.returncode, 143, result.stderr)
            self.assertEqual((pathlib.Path(tmp) / 'proxy-multi.conf').read_text(),
                             'proxy_for 2 149.154.167.51:8888;\n')

    def test_rollback_account_failure_preserves_files_for_recovery(self):
        with tempfile.TemporaryDirectory() as tmp:
            result = self.run_function(install_mocks(tmp) + '''
                wait_running() { return 1; }; userdel() { return 1; };
                install_proxy --server example.com''')
            self.assertNotEqual(result.returncode, 0)
            self.assertTrue((pathlib.Path(tmp) / 'config' / 'account').exists())
            self.assertTrue((pathlib.Path(tmp) / 'unit').exists())
            self.assertFalse((pathlib.Path(tmp) / 'work').exists())

    def test_tcp_port_inventory_ipv4_ipv6_host_and_socket(self):
        for listener in ('0.0.0.0:443', '[::]:443', '127.0.0.1:443'):
            for program in ('systemd', 'docker-host', 'nginx'):
                with self.subTest(listener=listener, program=program):
                    result = self.run_function(f'''ss() {{
                        [[ $1 == -H && $2 == -ltnp && $3 == '( sport = :443 )' ]] || exit 77;
                        echo 'LISTEN 0 128 {listener} *:* users:(("{program}",pid=123,fd=6))';
                    }}; require_free_port 443''')
                    self.assertNotEqual(result.returncode, 0)
                    self.assertNotEqual(result.returncode, 77)
                    self.assertIn(program, result.stderr)

    def test_mounts_under_install_paths_are_refused(self):
        with tempfile.TemporaryDirectory() as tmp:
            mountinfo = pathlib.Path(tmp) / 'mountinfo'
            for mount in ('/opt/mtp', '/opt/mtp/bin', '/var/log/mtp', '/etc/mtp/proxy-secret'):
                with self.subTest(mount=mount):
                    mountinfo.write_text(f'100 20 0:99 / {mount} rw - tmpfs tmpfs rw\n')
                    result = self.run_function(f'MOUNTINFO="{mountinfo}"; no_mounts')
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn('挂载', result.stderr)
            mountinfo.write_text('100 20 0:99 / /var/log rw - tmpfs tmpfs rw\n')
            result = self.run_function(f'MOUNTINFO="{mountinfo}"; no_mounts')
            self.assertEqual(result.returncode, 0, result.stderr)

    def test_self_test_requires_refresh_timer(self):
        with tempfile.TemporaryDirectory() as tmp:
            (pathlib.Path(tmp) / 'mtp.log').touch()
            result = self.run_function(f'''LOG="{tmp}";
                load_config() {{ PORT=8443; STATS_PORT=8888; }};
                owner_check() {{ :; }}; account_check() {{ :; }}; runtime_permissions() {{ :; }};
                no_unrelated_files() {{ :; }}; logrotate() {{ :; }};
                systemctl() {{ if [[ "${{@: -1}}" == mtp-refresh.timer ]]; then return 1;
                    elif [[ $1 == show ]]; then echo 123; fi; }};
                port_lines() {{ echo "LISTEN 0 128 127.0.0.1:$1 *:* users:((proxy,pid=123,fd=6))"; }};
                self_test''')
            self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn('定时器', result.stdout)

    def test_self_test_rejects_stats_bound_to_public_addresses(self):
        addresses = ('198.51.100.5:8888', '[2001:db8::5]:8888',
                     '127.0.0.1:8888 *:* users:((proxy,pid=123,fd=6))\nLISTEN 0 128 198.51.100.5:8888')
        for address in addresses:
            with self.subTest(address=address), tempfile.TemporaryDirectory() as tmp:
                (pathlib.Path(tmp) / 'mtp.log').touch()
                result = self.run_function(f'''LOG="{tmp}";
                    load_config() {{ PORT=8443; STATS_PORT=8888; }};
                    owner_check() {{ :; }}; account_check() {{ :; }}; runtime_permissions() {{ :; }};
                    no_unrelated_files() {{ :; }}; logrotate() {{ :; }};
                    systemctl() {{ if [[ $1 == show ]]; then echo 123; fi; }};
                    port_lines() {{ if [[ $1 == 8888 ]]; then printf '%s\\n' 'LISTEN 0 128 {address} *:* users:((proxy,pid=123,fd=6))';
                        else echo 'LISTEN 0 128 127.0.0.1:8443 *:* users:((proxy,pid=123,fd=6))'; fi; }};
                    self_test''')
                self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertIn('公网绑定', result.stdout)

    def test_uninstall_partial_install_preserves_all_files(self):
        with tempfile.TemporaryDirectory() as tmp:
            base = pathlib.Path(tmp)
            (base / 'app').mkdir()
            (base / 'app' / '.owner').write_text('mtp-owned-v1\n')
            result = self.run_function(f'''APP="{tmp}/app"; CONFIG="{tmp}/config"; LOG="{tmp}/log";
                root_only() {{ :; }}; lock() {{ :; }};
                systemctl() {{ echo MUTATED; }}; uninstall_proxy''', input='YES\n')
            self.assertNotEqual(result.returncode, 0)
            self.assertNotIn('MUTATED', result.stdout)
            self.assertEqual((base / 'app' / '.owner').read_text(), 'mtp-owned-v1\n')

    def test_systemd_configuration_from_completed_install(self):
        for port, capabilities in ((443, 'CAP_NET_BIND_SERVICE'), (9443, '')):
            with self.subTest(port=port), tempfile.TemporaryDirectory() as tmp:
                result = self.run_function(install_mocks(tmp) + f'install_proxy --server example.com --port {port}')
                self.assertEqual(result.returncode, 0, result.stderr)
                service = configparser.ConfigParser(interpolation=None)
                service.read(pathlib.Path(tmp) / 'unit')
                self.assertEqual(service['Service']['User'], 'mtp')
                self.assertEqual(service['Service']['Group'], 'mtp')
                self.assertEqual(service['Service']['Restart'], 'always')
                self.assertEqual(service['Service']['RestartSec'], '5s')
                self.assertEqual(service['Service']['ProtectSystem'], 'strict')
                self.assertEqual(service['Service']['ReadWritePaths'], '/var/log/mtp')
                self.assertEqual(service['Service']['AmbientCapabilities'], capabilities)
                self.assertEqual(service['Service']['CapabilityBoundingSet'], capabilities)
                self.assertEqual(service['Unit']['StartLimitIntervalSec'], '0')
                self.assertEqual(service['Install']['WantedBy'], 'multi-user.target')
                timer = configparser.ConfigParser(interpolation=None)
                timer.read(pathlib.Path(tmp) / 'timer')
                self.assertEqual(timer['Timer']['Persistent'], 'true')
                self.assertEqual(timer['Timer']['Unit'], 'mtp-refresh.service')
                self.assertTrue((pathlib.Path(tmp) / 'config' / 'manifest').is_file())
                self.assertEqual((pathlib.Path(tmp) / 'config' / 'account').read_text(), '991 991\n')
                self.assertIn(f'port={port}&secret=ee', result.stdout)
                self.assertIn('su root root', (pathlib.Path(tmp) / 'rotate').read_text())

    def test_lock_rejects_symlink_without_truncating_target(self):
        with tempfile.TemporaryDirectory() as tmp:
            base = pathlib.Path(tmp)
            (base / 'external').write_text('keep')
            (base / 'lock').symlink_to(base / 'external')
            result = self.run_function(f'''LOCK="{base}/lock"; {PORTABLE_TOOLS}
                flock() {{ :; }}; lock''')
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('锁文件', result.stderr)
            self.assertEqual((base / 'external').read_text(), 'keep')

    def test_uninstall_reload_failure_does_not_leave_directories(self):
        with tempfile.TemporaryDirectory() as tmp:
            base = pathlib.Path(tmp)
            for name in ('app', 'config', 'log'):
                (base / name).mkdir()
            (base / 'config' / 'mtp.conf').write_text(VALID_CONFIG)
            result = self.run_function(f'''APP="{base}/app"; CONFIG="{base}/config"; LOG="{base}/log";
                UNIT="{base}/unit"; TIMER="{base}/timer"; REFRESH="{base}/refresh"; ROTATE="{base}/rotate";
                {PORTABLE_TOOLS}
                root_only() {{ :; }}; lock() {{ :; }}; owner_check() {{ :; }}; account_check() {{ :; }};
                getent() {{ return 2; }};
                systemctl() {{ if [[ $1 == daemon-reload ]]; then return 1; fi; }};
                uninstall_proxy''', input='YES\n')
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('重新加载', result.stderr)
            for name in ('app', 'config', 'log'):
                self.assertFalse((base / name).exists())

    def test_private_stats_only_accepts_loopback_and_own_pid(self):
        for address in ('127.0.0.1:8888', '127.0.0.2:8888', '[::1]:8888', '::1:8888'):
            with self.subTest(address=address):
                result = self.run_function(f'''STATS_PORT=8888;
                    private_stats_listener 'LISTEN 0 128 {address} *:* users:((proxy,pid=123,fd=6))' 123''')
                self.assertEqual(result.returncode, 0, result.stderr)
        result = self.run_function('''STATS_PORT=8888;
            private_stats_listener 'LISTEN 0 128 127.0.0.1:8888 *:* users:((proxy,pid=124,fd=6))' 123''')
        self.assertNotEqual(result.returncode, 0)

    def test_refresh_rename_failure_keeps_old_config_without_restart(self):
        with tempfile.TemporaryDirectory() as tmp:
            result = self.refresh_fixture(tmp, 'proxy_for 3 149.154.175.100:8888;\n',
                extra='mv() { return 1; };')
            self.assertNotEqual(result.returncode, 0)
            self.assertFalse((pathlib.Path(tmp) / 'calls').exists())
            self.assertEqual((pathlib.Path(tmp) / 'proxy-multi.conf').read_text(),
                             'proxy_for 2 149.154.167.51:8888;\n')
            self.assertEqual([p.name for p in pathlib.Path(tmp).iterdir()], ['proxy-multi.conf'])

    def test_refresh_respects_stop_during_download(self):
        with tempfile.TemporaryDirectory() as tmp:
            result = self.refresh_fixture(tmp, 'proxy_for 3 149.154.175.100:8888;\n', extra='''
                fetch() { echo 'proxy_for 3 149.154.175.100:8888;' > "$2"; touch "$CONFIG/stopped"; };
                systemctl() { if [[ $1 == is-active && -e $CONFIG/stopped ]]; then return 1;
                    elif [[ $1 == restart ]]; then echo restarted > "$CONFIG/calls"; fi; };
            ''')
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertFalse((pathlib.Path(tmp) / 'calls').exists())
            self.assertEqual((pathlib.Path(tmp) / 'proxy-multi.conf').read_text(),
                             'proxy_for 2 149.154.167.51:8888;\n')

    def test_install_rollback_refuses_group_shared_after_creation(self):
        with tempfile.TemporaryDirectory() as tmp:
            result = self.run_function(install_mocks(tmp) + '''
                wait_running() {
                    getent() { if [[ $1 == group ]]; then echo 'mtp:x:991:other';
                        elif [[ $# == 1 ]]; then return 0; else return 2; fi; }; return 1;
                }; install_proxy --server example.com''')
            self.assertNotEqual(result.returncode, 0)
            self.assertTrue((pathlib.Path(tmp) / 'config' / 'account').exists())
            self.assertIn('拒绝删除', result.stderr)

    def test_privileged_port_start_failure_rolls_back_after_unit_generation(self):
        with tempfile.TemporaryDirectory() as tmp:
            result = self.run_function(install_mocks(tmp) + '''
                sed() { if [[ $1 == -i ]]; then command sed "$2" "$3" > "$3.tmp"; mv "$3.tmp" "$3";
                    else command sed "$@"; fi; };
                wait_running() { return 1; }; install_proxy --server example.com --port 443''')
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('服务启动失败', result.stderr)
            for path in ('app', 'config', 'log', 'unit', 'timer', 'refresh', 'rotate', 'work'):
                self.assertFalse((pathlib.Path(tmp) / path).exists(), result.stdout + result.stderr)

    def test_install_refuses_failed_dropin_query_before_creating_resources(self):
        with tempfile.TemporaryDirectory() as tmp:
            result = self.run_function(install_mocks(tmp) + '''
                systemctl() { if [[ ${3:-} == DropInPaths ]]; then return 1;
                    else mock_systemctl "$@"; fi; };
                install_proxy --server example.com''')
            self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn('额外配置', result.stderr)
            for path in ('work', 'app', 'config', 'log', 'unit'):
                self.assertFalse((pathlib.Path(tmp) / path).exists())

    def test_account_query_errors_are_not_treated_as_missing_accounts(self):
        for database, status in (('passwd', 1), ('group', 1), ('passwd', 3), ('group', 0)):
            with self.subTest(database=database, status=status), tempfile.TemporaryDirectory() as tmp:
                (pathlib.Path(tmp) / 'account').write_text('991 991\n')
                (pathlib.Path(tmp) / 'account').chmod(0o600)
                result = self.run_function(f'''CONFIG="{tmp}"; {PORTABLE_TOOLS}
                    getent() {{
                        if [[ $1 == {database} && $# == 2 ]]; then return {status}; fi
                        if [[ $1 == passwd ]]; then echo 'mtp:x:991:991::/nonexistent:/usr/sbin/nologin';
                        else echo 'mtp:x:991:'; fi;
                    }}; account_check''')
                self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_install_refuses_failed_account_query_before_network(self):
        for database in ('passwd', 'group'):
            with self.subTest(database=database), tempfile.TemporaryDirectory() as tmp:
                result = self.run_function(install_mocks(tmp) + f'''
                    getent() {{ if [[ $1 == {database} ]]; then return 1; else return 2; fi; }};
                    install_proxy --server example.com''')
                self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertFalse((pathlib.Path(tmp) / 'work').exists())
                self.assertFalse((pathlib.Path(tmp) / 'app').exists())

    def test_uninstall_preserves_files_on_late_account_query_failure(self):
        for database in ('passwd', 'group'):
            with self.subTest(database=database), tempfile.TemporaryDirectory() as tmp:
                base = pathlib.Path(tmp)
                for name in ('app', 'config', 'log'):
                    (base / name).mkdir()
                (base / 'config' / 'mtp.conf').write_text(VALID_CONFIG)
                result = self.run_function(f'''APP="{base}/app"; CONFIG="{base}/config"; LOG="{base}/log";
                    UNIT="{base}/unit"; TIMER="{base}/timer"; REFRESH="{base}/refresh"; ROTATE="{base}/rotate";
                    {PORTABLE_TOOLS}
                    root_only() {{ :; }}; lock() {{ :; }}; owner_check() {{ :; }}; account_check() {{ :; }};
                    systemctl() {{ if [[ ${{3:-}} == LoadState ]]; then echo not-found; fi; }};
                    getent() {{ if [[ $1 == {database} ]]; then return 1;
                        else echo 'mtp:x:991:991::/nonexistent:/usr/sbin/nologin'; fi; }};
                    port_lines() {{ :; }};
                    userdel() {{ echo DELETED; }}; groupdel() {{ echo DELETED; }};
                    uninstall_proxy''', input='YES\n')
                self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertNotIn('DELETED', result.stdout)
                self.assertTrue((base / 'config' / 'mtp.conf').exists())


if __name__ == '__main__':
    unittest.main()
