# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 Saunakalja
"""Redirect only platform inputs/paths for backend tests; nftables stays real."""
import json
from pathlib import Path
import tempfile


class Backend:
    def __init__(self, repo, ucode, modules, namespace):
        self.repo, self.ucode, self.modules, self.namespace = repo, ucode, modules, namespace
        self.temp = tempfile.TemporaryDirectory(prefix="ib-backend-")
        self.base = Path(self.temp.name)
        self.data = self.base / "etc/internetblock"
        self.data.mkdir(parents=True)
        (self.base / "tmp").mkdir()
        (self.base / "lock").mkdir()
        sysnet = self.base / "sys/class/net"
        (sysnet / "ib-lan/brif/phy0-ap0").mkdir(parents=True)
        (sysnet / "ib-lan/address").write_text("02:00:00:00:00:01\n")
        self.fixture = self.base / "fixture.json"
        self.config = {
            "config": {
                "firewall": [
                    {".type": "defaults", "flow_offloading": "0"},
                    {".type": "zone", "name": "lan", "network": ["lan"]},
                    {".type": "zone", "name": "wan", "network": ["wan"]},
                ],
                "dhcp": [
                    {".type": "host", ".name": "plug", "name": "Fixed plug", "mac": "02:00:00:00:00:10", "ip": "192.0.2.10"},
                    {".type": "host", ".name": "sensor", "name": "Static offline", "mac": "02:00:00:00:00:30", "ip": "192.0.2.30"},
                ],
            },
            "networks": {
                "network.interface.lan": {"up": True, "l3_device": "ib-lan", "ipv4-address": [{"address": "192.0.2.1", "mask": 24}]},
                "network.interface.wan": {"up": True, "l3_device": "ib-wan", "ipv4-address": [{"address": "198.18.0.1", "mask": 24}]},
            },
        }
        self.save_config()
        (self.base / "tmp/dhcp.leases").write_text("0 02:00:00:00:00:10 192.0.2.10 lease-name *\n")
        self.wifi = self.base / "iw"
        self.wifi.write_text("#!/bin/sh\ncase \"$*\" in\n dev) echo 'Interface phy0-ap0';;\n *) echo 'Station 02:00:00:00:00:10 (on phy0-ap0)';;\nesac\n")
        self.wifi.chmod(0o755)
        self.nft = self.base / "nft"
        self.nft.write_text(
            "#!/usr/bin/python3\nimport os, pathlib, sys\n"
            f"flag = pathlib.Path({str(self.base / 'fail-nft')!r})\n"
            "if '-f' in sys.argv and flag.exists():\n flag.unlink()\n sys.stderr.write('injected nft failure\\n')\n sys.exit(1)\n"
            "os.execv('/usr/sbin/nft', ['/usr/sbin/nft'] + sys.argv[1:])\n"
        )
        self.nft.chmod(0o755)
        source = (repo / "root/usr/share/internetblock/backend.uc").read_text()
        source = source.replace("'/etc/internetblock'", repr(str(self.data)))
        source = source.replace("/tmp/internetblock", str(self.base / "tmp/internetblock"))
        source = source.replace("/tmp/dhcp.leases", str(self.base / "tmp/dhcp.leases"))
        source = source.replace("/var/lock/internetblock.lock", str(self.base / "lock/internetblock.lock"))
        source = source.replace("/sys/class/net", str(sysnet))
        source = source.replace("/usr/sbin/iw", str(self.wifi)).replace("/usr/sbin/nft", str(self.nft))
        for name in ("core.uc", "storage.uc"):
            code = (repo / "root/usr/share/internetblock" / name).read_text()
            # Tests do not sync the WSL host's entire filesystem per operation.
            if name == "storage.uc":
                code = code.replace("system('/bin/sync')", "system('/bin/true')")
            (self.base / name).write_text(code)
        self.backend = self.base / "backend.uc"
        self.backend.write_text(source)

    def save_config(self):
        self.fixture.write_text(json.dumps(self.config))

    def call(self, command, request=None):
        import subprocess
        args = ["ip", "netns", "exec", self.namespace, "env", f"IB_FIXTURE={self.fixture}", self.ucode]
        if self.modules:
            args += ["-L", self.modules]
        args += ["-L", str(self.repo / "tests/stubs"), str(self.backend), command]
        result = subprocess.run(args, input=json.dumps(request) if request is not None else "", text=True, capture_output=True)
        try:
            response = json.loads(result.stdout)
        except json.JSONDecodeError:
            raise AssertionError(f"backend {command}: {result.stderr}\n{result.stdout}")
        if result.returncode not in (0, 1):
            raise AssertionError(result.stderr)
        return response

    def close(self):
        self.temp.cleanup()
