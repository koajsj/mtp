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
                               'test', str(SCRIPT)], capture_output=True, text=True)

    def test_ports(self):
        for value in ['443', '8443', '65535', '1']:
            with self.subTest(value=value):
                self.assertEqual(self.run_function(f'valid_port {value}').returncode, 0)
        for value in ['0', '65536', '-1', '08', 'abc', '1;echo bad']:
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

    def test_unknown_command_no_install(self):
        result = subprocess.run(['bash', str(SCRIPT), 'typo'], capture_output=True, text=True)
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
                 'test', str(SCRIPT), str(base)], capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertTrue((base / 'app' / 'user-data').exists())

    def test_uninstall_requires_exact_yes(self):
        with tempfile.TemporaryDirectory() as tmp:
            base = pathlib.Path(tmp)
            for name in ('app', 'config', 'log'):
                (base / name).mkdir()
            code = '''source "$1"; APP=$2/app; CONFIG=$2/config; LOG=$2/log;
                root_only() { :; }; lock() { :; }; owner_check() { :; }; no_unrelated_files() { :; };
                uninstall_proxy'''
            result = subprocess.run(['bash', '-c', code, 'test', str(SCRIPT), str(base)],
                                    input='yes\n', capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertTrue((base / 'app').exists())

    def test_uninstall_removes_only_owned_fixture(self):
        with tempfile.TemporaryDirectory() as tmp:
            base = pathlib.Path(tmp)
            for name in ('app', 'config', 'log'):
                (base / name).mkdir()
                (base / name / '.owner').write_text('mtp-owned-v1\n')
            (base / 'app' / 'mtp').write_text('# manager\n')
            (base / 'config' / 'mtp.conf').write_text('PORT=8443\n')
            (base / 'unit').write_text('Description=MTProto Proxy (mtp-owned)\n')
            for name in ('timer', 'refresh', 'rotate'):
                (base / name).write_text('# mtp-owned-v1\n')
            code = '''source "$1"; APP=$2/app; CONFIG=$2/config; LOG=$2/log;
                UNIT=$2/unit; TIMER=$2/timer; REFRESH=$2/refresh; ROTATE=$2/rotate;
                root_only() { :; }; lock() { :; }; userdel() { :; }; groupdel() { :; };
                systemctl() { if [[ $1 == show ]]; then echo not-found; fi; };
                port_lines() { :; }; uninstall_proxy'''
            result = subprocess.run(['bash', '-c', code, 'test', str(SCRIPT), str(base)],
                                    input='YES\n', capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertFalse((base / 'app').exists())
            self.assertFalse((base / 'config').exists())
            self.assertFalse((base / 'log').exists())
            self.assertFalse((base / 'unit').exists())

if __name__ == '__main__':
    unittest.main()
