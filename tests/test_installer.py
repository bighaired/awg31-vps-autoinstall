#!/usr/bin/env python3
"""Static contract tests; do not execute the root installer in CI."""
from pathlib import Path
import re
import unittest

SCRIPT = Path(__file__).resolve().parents[1].joinpath("install.sh").read_text()

class InstallerContract(unittest.TestCase):
    def test_pinned_upstream(self):
        self.assertRegex(SCRIPT, r"(?m)^UPSTREAM_COMMIT=[0-9a-f]{40}$")
        self.assertIn('git -C "$UPSTREAM_DIR" rev-parse HEAD', SCRIPT)
        self.assertNotIn("raw.githubusercontent.com/wiresock/awg-server-tools/main/", SCRIPT)

    def test_fresh_os_and_root_guard(self):
        self.assertIn('[[ $EUID == 0 ]]', SCRIPT)
        self.assertIn('$VERSION_ID == 24.04', SCRIPT)
        self.assertIn("Existing AWG installation detected", SCRIPT)

    def test_resume_and_secrets(self):
        self.assertIn('ExecStart=/usr/local/sbin/awg31-autosetup --resume', SCRIPT)
        self.assertIn('chmod 600 "$CONFIG"', SCRIPT)
        self.assertIn("PasswordHasher().hash", SCRIPT)
        self.assertIn('rm -f "$CONFIG"', SCRIPT)

    def test_panel_localhost_and_tls(self):
        self.assertIn('--host 127.0.0.1 --port 8080', SCRIPT)
        self.assertIn('AUTH_SECURE_COOKIE=true', SCRIPT)
        self.assertIn('--ip-address "$PUBLIC_IP"', SCRIPT)
        self.assertIn('proxy_pass http://127.0.0.1:8080;', SCRIPT)

    def test_interrupted_fetch_recovery(self):
        self.assertIn("Fetching pinned upstream commit (safe to retry)", SCRIPT)
        self.assertIn('git -C "$UPSTREAM_DIR" fetch --depth 1', SCRIPT)
        self.assertIn('Unexpected upstream origin URL', SCRIPT)

    def test_listener_socket_checks(self):
        self.assertIn('ss -H -lun | awk -v port="$AWG_PORT"', SCRIPT)
        self.assertIn('ss -H -lnt | awk', SCRIPT)
        self.assertIn('AWG UDP listening socket not found', SCRIPT)

    def test_protocol_configuration(self):
        self.assertIn('--enable-awg31', SCRIPT)
        self.assertIn('S_VALUE=$(sed -nE', SCRIPT)
        self.assertIn('SERVER_AWG_S${i}=$S_VALUE', SCRIPT)
        self.assertIn('preserving MTU budget', SCRIPT)
        self.assertNotIn('SERVER_AWG_S${i}=54', SCRIPT)
        self.assertIn('systemctl is-active --quiet awg-quick@awg0', SCRIPT)

if __name__ == "__main__":
    unittest.main()
