#!/usr/bin/env python3
"""Static contract tests; do not execute the root installer in CI."""
from pathlib import Path
import re
import subprocess
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

    def test_partial_panel_install_recovery(self):
        self.assertIn('Installing or repairing incomplete web panel', SCRIPT)
        self.assertIn('! -x /usr/local/bin/amneziawg-web', SCRIPT)
        self.assertIn('! -f /etc/systemd/system/amneziawg-web.service', SCRIPT)
        self.assertIn('Web panel installation incomplete.', SCRIPT)
        self.assertIn('AWG_WEB_LISTEN=127.0.0.1:8080', SCRIPT)
        self.assertIn('AUTH_PASSWORD_HASH=$ADMIN_HASH', SCRIPT)
        self.assertIn('AUTH_ENABLED=true', SCRIPT)

    def test_panel_localhost_and_tls(self):
        self.assertIn('--host 127.0.0.1 --port 8080', SCRIPT)
        self.assertIn('AUTH_SECURE_COOKIE=true', SCRIPT)
        self.assertIn('--ip-address "$PUBLIC_IP"', SCRIPT)
        self.assertIn('proxy_pass http://127.0.0.1:8080;', SCRIPT)

    def test_interrupted_fetch_recovery(self):
        self.assertIn("Fetching pinned upstream commit (safe to retry)", SCRIPT)
        self.assertIn('git -C "$UPSTREAM_DIR" fetch --depth 1', SCRIPT)
        self.assertIn('Unexpected upstream origin URL', SCRIPT)
        self.assertIn('remote add origin "$REPO"', SCRIPT)
        self.assertIn('if ! git -C "$UPSTREAM_DIR" remote get-url origin', SCRIPT)

    def test_listener_socket_checks(self):
        self.assertIn('ss -H -lun | awk -v port="$AWG_PORT"', SCRIPT)
        self.assertIn('ss -H -lnt | awk', SCRIPT)
        self.assertIn('AWG UDP listening socket not found', SCRIPT)

    def test_padding_extraction_samples(self):
        # Execute the same sed parser on representative generated configs.
        pattern = r"s/^[[:space:]]*S4[[:space:]]*=[[:space:]]*([0-9]+)[[:space:]]*$/\\1/p"
        for value in (15, 54, 128):
            config = f"[Interface]\\nS1 = 55\\nS4 = {value}\\n"
            out = subprocess.run(["sed", "-nE", pattern], input=config, text=True,
                                 capture_output=True, check=True)
            self.assertEqual(out.stdout.strip(), str(value))

    def test_socket_parser_samples(self):
        # ss -H emits State, Recv-Q, Send-Q, Local Address:Port, Peer Address:Port.
        cmd = ["awk", "-v", "port=585", '$4 ~ (":" port "$") { found=1 } END { exit !found }']
        good = "UNCONN 0 0 0.0.0.0:585 0.0.0.0:*\\n"
        bad = "UNCONN 0 0 0.0.0.0:1585 0.0.0.0:*\\n"
        self.assertEqual(subprocess.run(cmd, input=good, text=True).returncode, 0)
        self.assertNotEqual(subprocess.run(cmd, input=bad, text=True).returncode, 0)

    def test_protocol_configuration(self):
        self.assertIn('--enable-awg31', SCRIPT)
        self.assertIn('S_VALUE=$(sed -nE', SCRIPT)
        self.assertIn('SERVER_AWG_S${i}=$S_VALUE', SCRIPT)
        self.assertIn('preserving MTU budget', SCRIPT)
        self.assertNotIn('SERVER_AWG_S${i}=54', SCRIPT)
        self.assertIn('systemctl is-active --quiet awg-quick@awg0', SCRIPT)

if __name__ == "__main__":
    unittest.main()
