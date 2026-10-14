"""Portable tests: no root, host mutations or external downloads."""
import pathlib
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
SCRIPT = ROOT / 'MTP一键部署.sh'

class SafetyTests(unittest.TestCase):
    def run_function(self, code):
        # Source library mode: main must not execute merely on source.
        return subprocess.run(['bash', '-c', 'source "$1"; ' + code,
                               'test', str(SCRIPT)], capture_output=True, text=True, errors='replace')

    def test_ports(self):
        for value in ['443', '8443', '65535', '1']:
            with self.subTest(value=value):
                self.assertEqual(self.run_function(f'valid_port {value}').returncode, 0)
        for value in ['0', '65536', '-1', '08', 'abc', '1;echo bad', '18446744073709551617', '999999999999999999999999']:
            with self.subTest(value=value):
                self.assertNotEqual(self.run_function(f'valid_port "{value}"').returncode, 0)

    def test_conflict_never_kills(self):
        result = self.run_function('ss() { echo \'LISTEN 0 128 *:443 *:* users:(("nginx",pid=123,fd=6))\'; }; require_free_port 443')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('nginx', result.stderr)
        self.assertIn('123', result.stderr)
        self.assertNotIn('kill -', SCRIPT.read_text())

    def test_docker_published_port_conflict(self):
        result = self.run_function('''ss() { :; }; docker() {
            if [[ $1 == info ]]; then return 0; fi
            printf 'web 0.0.0.0:443->443/tcp\\n'
        }; require_free_port 443''')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('web', result.stderr)

    def test_config_is_data(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = pathlib.Path(tmp) / 'mtp.conf'
            marker = pathlib.Path(tmp) / 'executed'
            path.write_text(f'PORT=$(touch {marker})\n')
            result = self.run_function(f'CONFIG="{tmp}"; load_config')
            self.assertNotEqual(result.returncode, 0)
            self.assertFalse(marker.exists())

    def test_link_uses_selected_port_and_tls_secret(self):
        result = self.run_function('PORT=9443; SERVER=proxy.example.com; SECRET=0123456789abcdef0123456789abcdef; DOMAIN=example.com; show_link')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('port=9443&secret=ee0123456789abcdef0123456789abcdef6578616d706c652e636f6d', result.stdout)

    def test_unknown_management_arguments(self):
        result = subprocess.run(['bash', str(SCRIPT), 'stop', '--unexpected'],
                                capture_output=True, text=True, errors='replace')
        self.assertIn('不接受参数', result.stderr)

    def test_refresh_failure_cleans_temporary_files(self):
        with tempfile.TemporaryDirectory() as tmp:
            result = self.run_function(f'''CONFIG="{tmp}";
                root_only() {{ :; }}; lock() {{ :; }}; owner_check() {{ :; }}; runtime_permissions() {{ :; }};
                systemctl() {{ return 0; }}; load_config() {{ PORT=8443; }};
                fetch() {{ echo FETCH_FAILED >&2; return 1; }};
                refresh_proxy''')
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('FETCH_FAILED', result.stderr)
            self.assertEqual(list(pathlib.Path(tmp).iterdir()), [])

    def test_refresh_preserves_stopped_service(self):
        with tempfile.TemporaryDirectory() as tmp:
            marker = pathlib.Path(tmp) / 'called'
            result = self.run_function(f'''CONFIG="{tmp}";
                root_only() {{ :; }}; lock() {{ :; }}; owner_check() {{ :; }}; runtime_permissions() {{ :; }};
                systemctl() {{ return 1; }};
                fetch() {{ touch "{marker}"; return 1; }};
                refresh_proxy''')
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertFalse(marker.exists())

    def test_uninstall_rejects_symlink(self):
        with tempfile.TemporaryDirectory() as tmp:
            base = pathlib.Path(tmp)
            for name in ('app', 'config', 'log'):
                (base / name).mkdir()
            (base / 'config' / 'proxy-secret').symlink_to('/etc/passwd')
            result = self.run_function(f'APP="{base}/app"; CONFIG="{base}/config"; LOG="{base}/log"; no_unrelated_files')
            self.assertNotEqual(result.returncode, 0)

    def test_log_filename_cannot_hide_user_data(self):
        with tempfile.TemporaryDirectory() as tmp:
            base = pathlib.Path(tmp)
            for name in ('app', 'config', 'log'):
                (base / name).mkdir()
            (base / 'log' / 'mtp.log.1-user-data').write_text('keep')
            result = self.run_function(f'APP="{base}/app"; CONFIG="{base}/config"; LOG="{base}/log"; no_unrelated_files')
            self.assertNotEqual(result.returncode, 0)

    def test_self_test_reports_invalid_config_without_secret(self):
        with tempfile.TemporaryDirectory() as tmp:
            result = self.run_function(f'CONFIG="{tmp}"; self_test')
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('配置', result.stdout + result.stderr)

    def install_fixture(self, base, options='', extra=''):
        return self.run_function(f'''APP="{base}/app"; CONFIG="{base}/config";
            LOG="{base}/log"; UNIT="{base}/unit"; TIMER="{base}/timer";
            REFRESH="{base}/refresh"; ROTATE="{base}/rotate";
            root_only() {{ :; }}; preflight() {{ :; }}; lock() {{ :; }};
            systemctl() {{ if [[ $3 == LoadState ]]; then echo not-found; fi; }};
            getent() {{ return 2; }};
            fetch() {{ echo UNEXPECTED_FETCH >&2; return 1; }};
            {extra}
            install_proxy {options}''')

    def test_install_existing_directory(self):
        with tempfile.TemporaryDirectory() as tmp:
            (pathlib.Path(tmp) / 'app').mkdir()
            result = self.install_fixture(tmp)
            self.assertIn('拒绝覆盖', result.stderr)
            self.assertNotIn('UNEXPECTED_FETCH', result.stderr)

    def test_install_existing_vendor_service(self):
        with tempfile.TemporaryDirectory() as tmp:
            result = self.install_fixture(tmp, extra='''
                systemctl() { echo /usr/lib/systemd/system/mtp.service; };
            ''')
            self.assertIn('systemd 中已存在', result.stderr)
            self.assertNotIn('UNEXPECTED_FETCH', result.stderr)

    def test_install_invalid_arguments_before_network(self):
        with tempfile.TemporaryDirectory() as tmp:
            for options in ('--port', '--wrong 3', '--port 65536', '--stats-port 80', '--port 8888'):
                with self.subTest(options=options):
                    result = self.install_fixture(tmp, options)
                    self.assertNotEqual(result.returncode, 0)
                    self.assertNotIn('UNEXPECTED_FETCH', result.stderr)

    def test_install_fetch_failure_cleans_temp(self):
        with tempfile.TemporaryDirectory() as tmp:
            result = self.install_fixture(tmp, '--server example.com',
                extra=f'''ss() {{ :; }}; docker() {{ return 1; }};
                mktemp() {{ mkdir "{tmp}/work"; echo "{tmp}/work"; }};
                systemctl() {{ if [[ ${{3:-}} == LoadState ]]; then echo not-found; fi; }};
                ''')
            self.assertIn('UNEXPECTED_FETCH', result.stderr)
            self.assertFalse((pathlib.Path(tmp) / 'work').exists())

    def test_refresh_restart_failure_restores_old_config(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = pathlib.Path(tmp) / 'proxy-multi.conf'
            path.write_text('old config\n')
            result = self.run_function(f'''CONFIG="{tmp}";
                root_only() {{ :; }}; lock() {{ :; }}; owner_check() {{ :; }};
                load_config() {{ PORT=8443; }}; runtime_permissions() {{ :; }};
                systemctl() {{ if [[ $1 == restart ]]; then return 1; fi; }};
                fetch() {{ printf 'proxy_for 2 149.154.167.51:8888;\n' > "$2"; }};
                refresh_proxy''')
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(path.read_text(), 'old config\n')
            self.assertEqual([f.name for f in pathlib.Path(tmp).iterdir()], ['proxy-multi.conf'])

    def test_account_reuse_refused(self):
        with tempfile.TemporaryDirectory() as tmp:
            (pathlib.Path(tmp) / 'account').write_text('991 991\n')
            result = self.run_function(f'''CONFIG="{tmp}";
                stat() {{ if [[ $2 == %u ]]; then echo 0; else echo 600; fi; }};
                getent() {{ echo 'mtp:x:992:992::/home/other:/bin/bash'; }};
                account_check''')
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('拒绝删除', result.stderr)

    def test_self_test_does_not_echo_secret(self):
        with tempfile.TemporaryDirectory() as tmp:
            secret = '0123456789abcdef0123456789abcdef'
            (pathlib.Path(tmp) / 'mtp.conf').write_text(
                f'PORT=8443\nSTATS_PORT=8888\nSECRET={secret}\nDOMAIN=example.com\nSERVER=example.com\nTAG=\n')
            result = self.run_function(f'''CONFIG="{tmp}";
                owner_check() {{ :; }}; account_check() {{ :; }}; runtime_permissions() {{ :; }};
                systemctl() {{ if [[ $1 == show ]]; then echo 123; fi; }};
                ss() {{ echo 'LISTEN 0 128 127.0.0.1:8888 *:* users:(("mtproto-proxy",pid=123,fd=4))'; }};
                self_test''')
            self.assertNotIn(secret, result.stdout + result.stderr)
            self.assertIn('Secret 格式：正常', result.stdout)

    def test_status_inactive_returns_failure(self):
        result = self.run_function('''load_config() { PORT=8443; STATS_PORT=8888; };
            systemctl() { if [[ $1 == show ]]; then echo 0; else return 3; fi; };
            ss() { :; }; tail() { :; }; status_proxy''')
        self.assertNotEqual(result.returncode, 0)

    def test_uninstall_account_failure_keeps_install(self):
        with tempfile.TemporaryDirectory() as tmp:
            base = pathlib.Path(tmp)
            (base / 'app').mkdir()
            result = subprocess.run(['bash', '-c', '''source "$1"; APP=$2/app;
                root_only() { :; }; lock() { :; }; owner_check() { :; };
                account_check() { die '用户归属不同'; }; uninstall_proxy''',
                'test', str(SCRIPT), str(base)], input='YES\n', capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertTrue((base / 'app').exists())

    def test_conflict_service_names(self):
        for name in ('nginx', 'caddy', 'BT-Panel', 'mtproto-proxy', 'apache2'):
            with self.subTest(name=name):
                result = self.run_function(f'''ss() {{ echo 'LISTEN 0 128 *:443 *:* users:(("{name}",pid=123,fd=6))'; }};
                    require_free_port 443''')
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(name, result.stderr)

    def test_wait_running_rejects_other_pid(self):
        result = self.run_function('''PORT=8443;
            systemctl() { if [[ $1 == show ]]; then echo 123; fi; };
            ss() { echo 'LISTEN 0 128 *:8443 *:* users:(("nginx",pid=124,fd=6))'; };
            sleep() { :; }; wait_running''')
        self.assertNotEqual(result.returncode, 0)

    def test_wait_running_accepts_service_pid(self):
        result = self.run_function('''PORT=443;
            systemctl() { if [[ $1 == show ]]; then echo 123; fi; };
            ss() { echo 'LISTEN 0 128 *:443 *:* users:(("mtproto-proxy",pid=123,fd=6))'; };
            sleep() { :; }; wait_running''')
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_install_creates_usable_service_and_logrotate(self):
        with tempfile.TemporaryDirectory() as tmp:
            extra = f'''ss() {{ :; }}; docker() {{ return 1; }};
                groupadd() {{ :; }}; useradd() {{ :; }}; chown() {{ :; }};
                stat() {{ python3 -c 'import os,sys; s=os.stat(sys.argv[-1]); print(str(s.st_dev)+":"+str(s.st_ino))' "$@"; }};
                userdel() {{ :; }}; groupdel() {{ :; }};
                id() {{ echo 991; }}; sha256sum() {{ cat >/dev/null; }};
                fetch() {{ case "$1" in *getProxySecret) printf '%064d' 0 > "$2";;
                    *getProxyConfig) echo 'proxy_for 2 149.154.167.51:8888;' > "$2";; *) echo archive > "$2";; esac; }};
                tar() {{ if [[ $1 == -tzf ]]; then echo engine/Makefile;
                    else touch "$4/Makefile"; fi; }};
                make() {{ mkdir -p "$2/objs/bin"; touch "$2/objs/bin/mtproto-proxy";
                    chmod 755 "$2/objs/bin/mtproto-proxy"; }};
                install() {{ local mode=$2; shift 2; if [[ $1 == -g ]]; then shift 2; fi;
                    cp "$1" "$2"; chmod "$mode" "$2"; }};
                wait_running() {{ :; }};
                sed() {{ if [[ $1 == -i ]]; then command sed "$2" "$3" > "$3.tmp"; mv "$3.tmp" "$3";
                    else command sed "$@"; fi; }};
                systemd-analyze() {{ :; }};
                systemctl() {{ if [[ ${{3:-}} == LoadState ]]; then echo not-found; fi; }};
            '''
            result = self.install_fixture(tmp, '--server example.com --port 443', extra=extra)
            self.assertEqual(result.returncode, 0, result.stderr)
            base = pathlib.Path(tmp)
            self.assertTrue((base / 'unit').exists(), result.stdout + result.stderr)
            unit = (base / 'unit').read_text()
            self.assertIn('ReadWritePaths=/var/log/mtp', unit)
            self.assertIn('StartLimitIntervalSec=0', unit)
            self.assertIn('AmbientCapabilities=CAP_NET_BIND_SERVICE', unit)
            self.assertIn('su root root', (base / 'rotate').read_text())
            self.assertEqual((base / 'config' / 'account').read_text(), '991 991\n')
            self.assertIn('port=443&secret=ee', result.stdout)

    def test_runtime_permissions_reject_root_only_config(self):
        result = self.run_function('''id() { echo 991; };
            stat() { if [[ $2 == %g || $2 == %u ]]; then echo 991; else echo 600; fi; };
            runtime_permissions''')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('mtp', result.stderr)

    def test_docker_range_is_conflict(self):
        result = self.run_function('''ss() { :; }; docker() {
            if [[ $1 == info ]]; then return 0; fi
            echo 'web 0.0.0.0:440-450->440-450/tcp';
        }; require_free_port 443''')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('web', result.stderr)

    def test_docker_udp_does_not_block_tcp(self):
        result = self.run_function('''ss() { :; }; docker() {
            if [[ $1 == info ]]; then return 0; fi
            echo 'dns 0.0.0.0:443->443/udp';
        }; require_free_port 443''')
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_newline_filename_cannot_hide_user_data(self):
        with tempfile.TemporaryDirectory() as tmp:
            base = pathlib.Path(tmp)
            for name in ('app', 'config', 'log'):
                (base / name).mkdir()
            (base / 'log' / 'mtp.log.1\n').write_text('keep')
            result = self.run_function(f'APP="{base}/app"; CONFIG="{base}/config"; LOG="{base}/log"; no_unrelated_files')
            self.assertNotEqual(result.returncode, 0)

    def test_self_test_healthy_fixture(self):
        with tempfile.TemporaryDirectory() as tmp:
            base = pathlib.Path(tmp)
            for name in ('app', 'config', 'log'):
                (base / name).mkdir()
                (base / name / '.owner').write_text('mtp-owned-v1\n')
            (base / 'app' / 'bin').mkdir()
            for name in ('app/mtp', 'app/bin/mtproto-proxy', 'log/mtp.log'):
                (base / name).touch()
            (base / 'config' / 'account').write_text('991 991\n')
            (base / 'config' / 'manifest').write_text('fixture')
            (base / 'config' / 'proxy-secret').write_text('a' * 128)
            (base / 'config' / 'proxy-multi.conf').write_text('proxy_for 2 149.154.167.51:8888;\n')
            (base / 'config' / 'mtp.conf').write_text(
                'PORT=8443\nSTATS_PORT=8888\nSECRET=0123456789abcdef0123456789abcdef\nDOMAIN=example.com\nSERVER=example.com\nTAG=\n')
            (base / 'unit').write_text('Description=MTProto Proxy (mtp-owned)\n')
            for name in ('timer', 'refresh', 'rotate'):
                (base / name).write_text('# mtp-owned-v1\n')
            result = self.run_function(f'''APP="{base}/app"; CONFIG="{base}/config"; LOG="{base}/log";
                UNIT="{base}/unit"; TIMER="{base}/timer"; REFRESH="{base}/refresh"; ROTATE="{base}/rotate";
                id() {{ echo 991; }}; logrotate() {{ :; }};
                no_mounts() {{ :; }};
                manifest_content() {{ printf fixture; }};
                getent() {{ if [[ $1 == passwd ]]; then echo 'mtp:x:991:991::/nonexistent:/usr/sbin/nologin';
                    else echo 'mtp:x:991:'; fi; }};
                stat() {{ case "$2" in
                    %h) echo 1;;
                    %u) if [[ $3 == "$LOG/mtp.log" ]]; then echo 991; else echo 0; fi;;
                    %g) echo 991;;
                    %a) case "$3" in "$CONFIG"|"$LOG") echo 750;; "$APP"|"$APP/bin"|"$APP/mtp"|"$APP/bin/mtproto-proxy") echo 755;;
                        */account|*/manifest) echo 600;; */mtp.conf|*/proxy-secret|*/mtp.log) echo 640;; *) echo 644;; esac;; esac; }};
                systemctl() {{ if [[ $1 == show ]]; then case "$3" in
                    FragmentPath) case "${{@: -1}}" in mtp.service) echo "$UNIT";; mtp-refresh.service) echo "$REFRESH";; *) echo "$TIMER";; esac;;
                    MainPID) echo 123;; esac; fi; }};
                ss() {{ if [[ $3 == *8888* ]]; then local port=8888; else local port=8443; fi;
                    echo "LISTEN 0 128 127.0.0.1:$port *:* users:((proxy,pid=123,fd=6))"; }};
                self_test''')
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn('日志与轮转', result.stdout)
            self.assertNotIn('0123456789abcdef0123456789abcdef', result.stdout)

    def test_shellcheck(self):
        import shutil
        checker = shutil.which('shellcheck')
        if checker is None:
            self.skipTest('ShellCheck 未安装；禁止下载，未执行 lint')
        result = subprocess.run([checker, '-S', 'warning', str(SCRIPT)],
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_unknown_command_no_install(self):
        result = subprocess.run(['bash', str(SCRIPT), 'typo'], capture_output=True, text=True, errors='replace')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('用法', result.stderr)

    def test_uninstall_refuses_unrelated_file(self):
        with tempfile.TemporaryDirectory() as tmp:
            base = pathlib.Path(tmp)
            for name in ('app', 'config', 'log'):
                (base / name).mkdir()
            (base / 'app' / 'user-data').write_text('keep')
            result = subprocess.run(
                ['bash', '-c', 'source "$1"; APP=$2/app; CONFIG=$2/config; LOG=$2/log; no_unrelated_files',
                 'test', str(SCRIPT), str(base)], capture_output=True, text=True, errors='replace')
            self.assertNotEqual(result.returncode, 0)
            self.assertTrue((base / 'app' / 'user-data').exists())

    def test_uninstall_requires_exact_yes(self):
        with tempfile.TemporaryDirectory() as tmp:
            base = pathlib.Path(tmp)
            for name in ('app', 'config', 'log'):
                (base / name).mkdir()
            code = '''source "$1"; APP=$2/app; CONFIG=$2/config; LOG=$2/log;
                root_only() { :; }; lock() { :; }; owner_check() { :; }; account_check() { :; }; no_unrelated_files() { :; };
                uninstall_proxy'''
            result = subprocess.run(['bash', '-c', code, 'test', str(SCRIPT), str(base)],
                                    input='yes\n', capture_output=True, text=True, errors='replace')
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('已取消', result.stderr)
            self.assertTrue((base / 'app').exists())

    def test_uninstall_removes_only_owned_fixture(self):
        with tempfile.TemporaryDirectory() as tmp:
            base = pathlib.Path(tmp)
            for name in ('app', 'config', 'log'):
                (base / name).mkdir()
                (base / name / '.owner').write_text('mtp-owned-v1\n')
            (base / 'app' / 'mtp').write_text('# manager\n')
            (base / 'config' / 'mtp.conf').write_text('PORT=8443\n')
            (base / 'config' / 'account').write_text('991 991\n')
            (base / 'config' / 'manifest').write_text('fixture')
            (base / 'unit').write_text('Description=MTProto Proxy (mtp-owned)\n')
            for name in ('timer', 'refresh', 'rotate'):
                (base / name).write_text('# mtp-owned-v1\n')
            code = '''source "$1"; APP=$2/app; CONFIG=$2/config; LOG=$2/log;
                UNIT=$2/unit; TIMER=$2/timer; REFRESH=$2/refresh; ROTATE=$2/rotate;
                root_only() { :; }; lock() { :; }; safe_layout() { :; };
                no_mounts() { :; };
                manifest_content() { printf fixture; };
                stat() { if [[ $2 == %h ]]; then echo 1; elif [[ $2 == %u ]]; then echo 0; elif [[ $3 == */account || $3 == */manifest ]]; then echo 600; else echo 644; fi; };
                getent() { if [[ $1 == passwd && ${2:-} == mtp ]]; then
                    echo 'mtp:x:991:991::/nonexistent:/usr/sbin/nologin';
                    elif [[ $1 == group ]]; then echo 'mtp:x:991:'; fi; };
                userdel() { :; }; groupdel() { :; };
                systemctl() { if [[ $1 == show && $3 == LoadState ]]; then echo not-found;
                    elif [[ $1 == show && $3 == FragmentPath ]]; then
                        case "${@: -1}" in mtp.service) echo "$UNIT";; mtp-refresh.service) echo "$REFRESH";; *) echo "$TIMER";; esac;
                    fi; };
                port_lines() { :; }; uninstall_proxy'''
            result = subprocess.run(['bash', '-c', code, 'test', str(SCRIPT), str(base)],
                                    input='YES\n', capture_output=True, text=True, errors='replace')
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertFalse((base / 'app').exists())
            self.assertFalse((base / 'config').exists())
            self.assertFalse((base / 'log').exists())
            self.assertFalse((base / 'unit').exists())

if __name__ == '__main__':
    unittest.main()
