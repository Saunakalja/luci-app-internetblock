#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 Saunakalja
"""Real packet tests in disposable Linux network namespaces; never uses the LAN."""
import json
import os
from pathlib import Path
import runpy
import subprocess
import sys
from backend_harness import Backend

ROOT = Path(__file__).resolve().parents[1]
UCODE = os.environ.get("UCODE", "ucode")
MODULES = os.environ.get("UCODE_MODULES")


def run(*args, input=None, check=True):
    return subprocess.run(args, input=input, text=True, capture_output=True, check=check)


def render(mode, blocked=False, input=None):
    args = [UCODE]
    if MODULES:
        args += ["-L", MODULES]
    args += [str(ROOT / "tests/render.uc"), mode, "blocked" if blocked else "allowed"]
    return run(*args, input=input).stdout


def main():
    if os.geteuid() != 0:
        sys.exit("Run as root in an isolated Linux/WSL development environment")
    prefix = f"ibtest-{os.getpid()}"
    spaces = {s: f"{prefix}-{s}" for s in ("r", "c", "l", "w")}
    created = []
    backend = None
    server = None
    passed = 0

    def ns(which, *command, **kwargs):
        return run("ip", "netns", "exec", spaces[which], *command, **kwargs)

    def check(condition, message):
        nonlocal passed
        if not condition:
            raise AssertionError(message)
        passed += 1

    def pair(client, router_name, suffix):
        a, b = f"ib{os.getpid()}{suffix}a", f"ib{os.getpid()}{suffix}b"
        run("ip", "link", "add", a, "type", "veth", "peer", "name", b)
        run("ip", "link", "set", a, "netns", spaces[client])
        run("ip", "link", "set", b, "netns", spaces["r"])
        ns(client, "ip", "link", "set", a, "name", "eth0")
        ns("r", "ip", "link", "set", b, "name", router_name)
        ns(client, "ip", "link", "set", "eth0", "up")
        ns("r", "ip", "link", "set", router_name, "up")

    def ping(which, address):
        return ns(which, "ping", "-n", "-c", "1", "-W", "1", address, check=False).returncode == 0

    def nft(text):
        ns("r", "nft", "-f", "-", input=text)

    def firewall_structure():
        def strip_counters(value):
            if isinstance(value, dict):
                return {key: {} if key == "counter" else strip_counters(item) for key, item in value.items()}
            if isinstance(value, list):
                return [strip_counters(item) for item in value if "metainfo" not in item]
            return value
        return strip_counters(json.loads(ns("r", "nft", "-j", "list", "table", "inet", "fw4").stdout))

    def reload_fw4(blocked):
        # Same macro expansion and table lifecycle as fw4, entirely in test ns.
        nft('define lan_devices = { "ib-lan" }\ndefine wan_devices = { "ib-wan" }\n'
            'table inet fw4\nflush table inet fw4\ntable inet fw4 {\n'
            'chain forward { type filter hook forward priority 0; policy accept; '
            'ct state established,related accept comment "foreign-established"; '
            'counter comment "foreign-sentinel"; }\n' + render("fragment", blocked) + '}\n')

    try:
        for space in spaces.values():
            run("ip", "netns", "add", space)
            created.append(space)
            run("ip", "netns", "exec", space, "ip", "link", "set", "lo", "up")
        pair("c", "lan-c", "c")
        pair("l", "lan-l", "l")
        pair("w", "ib-wan", "w")
        ns("r", "ip", "link", "add", "ib-lan", "type", "bridge")
        for port in ("lan-c", "lan-l"):
            ns("r", "ip", "link", "set", port, "master", "ib-lan")
        ns("r", "ip", "link", "set", "ib-lan", "up")
        ns("r", "ip", "addr", "add", "192.0.2.1/24", "dev", "ib-lan")
        ns("r", "ip", "addr", "add", "198.18.0.1/24", "dev", "ib-wan")
        ns("r", "sysctl", "-qw", "net.ipv4.ip_forward=1")
        for who, address in (("c", "192.0.2.10/24"), ("l", "192.0.2.20/24"), ("w", "198.18.0.2/24")):
            ns(who, "ip", "addr", "add", address, "dev", "eth0")
        ns("c", "ip", "link", "set", "eth0", "address", "02:00:00:00:00:10")
        for who in ("c", "l"):
            ns(who, "ip", "route", "add", "default", "via", "192.0.2.1")
        ns("w", "ip", "route", "add", "192.0.2.0/24", "via", "198.18.0.1")
        reload_fw4(False)
        check(ping("c", "198.18.0.2"), "baseline WAN")
        check(ping("c", "192.0.2.20"), "baseline LAN peer")
        backend = Backend(ROOT, UCODE, MODULES, spaces["r"])
        initial = backend.call("init")
        check(initial["ok"], f"backend initializes persistent policy: {initial}")
        applied = backend.call("apply")
        check(applied["ok"], f"backend installs verified rules: {applied}")
        status = backend.call("status")
        check(status["ok"] and status["firewall_ok"], "backend status verifies real kernel expressions")
        check(len([d for d in status["devices"] if d["mac"] == "02:00:00:00:00:10"]) == 1, "backend static, lease, neighbor and Wi-Fi dedup")
        check(any(d["name"] == "Static offline" and not d["online"] for d in status["devices"]), "backend lists offline reservation")
        change = {"mac": "02:00:00:00:00:10", "blocked": True}
        check(backend.call("set", change)["ok"], "backend block transaction succeeds")
        ruleset = ns("r", "nft", "-j", "list", "ruleset").stdout
        render("check", True, input=ruleset)
        check(not ping("c", "198.18.0.2"), "block existing ICMP conntrack flow")
        check(ping("c", "192.0.2.20"), "blocked client retains LAN peer access")
        check(ping("c", "192.0.2.1"), "blocked client retains router services path")
        server = subprocess.Popen([
            "ip", "netns", "exec", spaces["r"], "python3", "-u", "-c",
            "import socket; s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM); "
            "s.bind(('192.0.2.1',53)); print('ready',flush=True); "
            "data,addr=s.recvfrom(512); s.sendto(data,addr); s.close()"
        ], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        check(server.stdout.readline().strip() == "ready", "test DNS-port listener starts")
        ns("c", "python3", "-c", "import socket; s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM); "
           "s.settimeout(2); s.sendto(b'local-dns-test',('192.0.2.1',53)); "
           "assert s.recvfrom(512)[0]==b'local-dns-test'")
        server.wait(timeout=3)
        check(server.returncode == 0, "blocked client retains bidirectional UDP access to router DNS port")
        check(ping("l", "198.18.0.2"), "unblocked LAN client unaffected")
        check(ping("r", "198.18.0.2"), "router output unaffected")
        ns("c", "ip", "addr", "del", "192.0.2.10/24", "dev", "eth0")
        ns("c", "ip", "addr", "add", "192.0.2.11/24", "dev", "eth0")
        ns("c", "ip", "route", "replace", "default", "via", "192.0.2.1")
        check(not ping("c", "198.18.0.2"), "IP change does not evade MAC block")
        check(ping("c", "192.0.2.20"), "LAN remains available after IP change")
        nft('define lan_devices = { "ib-lan" }\ndefine wan_devices = { "ib-wan" }\n'
            'flush table inet fw4\ntable inet fw4 {\n'
            'chain forward { type filter hook forward priority 0; policy accept; '
            'ct state established,related accept comment "foreign-established"; '
            'counter comment "foreign-sentinel"; }\n'
            f'include "{backend.data}/fw4/*.nft"\n' + '}\n')
        render("check", True, input=ns("r", "nft", "-j", "list", "ruleset").stdout)
        check(not ping("c", "198.18.0.2"), "saved block restored on firewall reload")
        check(backend.call("set", {**change, "blocked": False})["ok"], "backend unblock transaction succeeds")
        render("check", False, input=ns("r", "nft", "-j", "list", "ruleset").stdout)
        check(ping("c", "198.18.0.2"), "unblock removes actual restriction")
        nft('add rule inet fw4 internetblock_forward counter accept comment "bad-extra"\n')
        check(not backend.call("status")["firewall_ok"], "malformed runtime state is visibly unverified")
        check(backend.call("scan")["firewall_ok"], "collector repairs only owned runtime state")
        before = (backend.data / "fw4/policy.nft").read_text()
        (backend.base / "fail-nft").touch()
        failed = backend.call("set", change)
        check(not failed["ok"] and "previous policy restored" in failed["error"], "real nft failure is reported and rolled back")
        check((backend.data / "fw4/policy.nft").read_text() == before and ping("c", "198.18.0.2"), "failed block preserves disk and actual connectivity")
        check(not backend.call("set", {"mac": "02:00:00:00:00:01", "blocked": True})["ok"], "backend rejects router MAC")
        check(not backend.call("set", {"mac": "ff:ff:ff:ff:ff:ff", "blocked": True})["ok"], "backend rejects broadcast")
        check(not backend.call("set", {"mac": "02:00:00:00:00:99", "blocked": True})["ok"], "backend rejects unknown device")
        check(backend.call("flush")["ok"], "backend flushes seen data")
        # Forgetting must survive a new backend process and RAM loss without
        # touching firewall policy, and must not revive from an old lease.
        forgotten_mac = "02:00:00:00:00:70"
        request = {"mac": forgotten_mac}
        lease = backend.base / "tmp/dhcp.leases"
        lease.write_text(lease.read_text() + f"0 {forgotten_mac} 192.0.2.70 Old-device *\n")
        ns("r", "ip", "neigh", "replace", "192.0.2.70", "lladdr", forgotten_mac, "nud", "stale", "dev", "ib-lan")
        check(any(d["mac"] == forgotten_mac and d["removable"] for d in backend.call("status")["devices"]), "offline lease plus stale neighbor is removable")
        policy_before = (backend.data / "fw4/policy.nft").read_text()
        nft_before = firewall_structure()
        check(backend.call("remove", request)["ok"], "real backend persists removal")
        marker = next(d for d in json.loads((backend.data / "seen.json").read_text()) if d["mac"] == forgotten_mac)
        check(marker == {"mac": forgotten_mac, "forgotten": True}, "removed name and IP are discarded")
        cache = backend.base / "tmp/internetblock/seen.json"
        check(not cache.exists(), "acknowledged removal invalidates stale RAM snapshot")
        check(all(d["mac"] != forgotten_mac for d in backend.call("status")["devices"]), "old lease and stale neighbor remain hidden after new process")
        cache.unlink()
        check(all(d["mac"] != forgotten_mac for d in backend.call("status")["devices"]), "forgotten state survives RAM loss")
        check(backend.call("flush")["ok"] and marker in json.loads((backend.data / "seen.json").read_text()), "collector preserves persistent marker")
        check((backend.data / "fw4/policy.nft").read_text() == policy_before and
              firewall_structure() == nft_before, "Remove leaves saved and live firewall unchanged (excluding packet counters)")
        wifi_before = backend.wifi.read_text()
        backend.wifi.write_text(wifi_before.replace("02:00:00:00:00:10", forgotten_mac))
        check(any(d["mac"] == forgotten_mac and d["online"] and not d["removable"] for d in backend.call("status")["devices"]), "active Wi-Fi sighting restores removed row")
        check(not backend.call("remove", request)["ok"], "backend rejects active device despite stale browser state")
        check(backend.call("flush")["ok"], "reactivated identity can be flushed")
        backend.wifi.write_text(wifi_before)
        cache.unlink()
        check(any(d["mac"] == forgotten_mac and d["removable"] for d in backend.call("status")["devices"]), "reactivated identity stays remembered after going offline and losing RAM")
        disk_before = (backend.data / "seen.json").read_text()
        failure_path = backend.data / "seen.json.tmp"
        failure_path.mkdir()
        failure = backend.call("remove", request)
        check(not failure["ok"] and "previous memory restored" in failure["error"], "failed memory write reaches caller with rollback result")
        check((backend.data / "seen.json").read_text() == disk_before and cache.exists() and
              any(d["mac"] == forgotten_mac for d in backend.call("status")["devices"]), "failed removal preserves disk, RAM and visible device")
        failure_path.rmdir()
        check(backend.call("set", {**request, "blocked": True})["ok"], "offline dynamic device can still be blocked")
        check(not backend.call("remove", request)["ok"], "Remove cannot erase a saved or live block")
        check(backend.call("set", {**request, "blocked": False})["ok"], "offline dynamic block can be removed normally")
        check(not backend.call("remove", {"mac": "02:00:00:00:00:30"})["ok"], "offline static reservation cannot be forgotten")
        check(not backend.call("remove", {"mac": "02:00:00:00:00:01"})["ok"] and
              not backend.call("remove", {"mac": "ff:ff:ff:ff:ff:ff"})["ok"], "Remove rejects router and broadcast identities")
        backend.wifi.write_text("#!/bin/sh\nexit 1\n")
        check(not backend.call("remove", request)["ok"], "incomplete discovery refuses removal")
        backend.wifi.write_text(wifi_before)
        check(backend.call("remove", request)["ok"], "eligible offline device can be forgotten again")
        backend.config["config"]["dhcp"] = []
        backend.save_config()
        (backend.base / "tmp/internetblock/seen.json").unlink(missing_ok=True)
        check(any(d["name"] == "Static offline" for d in backend.call("status")["devices"]), "seen device persists after RAM loss and reservation removal")
        backend.config["config"]["firewall"][0]["flow_offloading"] = "1"
        backend.save_config()
        check(not backend.call("set", change)["ok"], "offload refuses block without modifying router settings")
        backend.config["config"]["firewall"][0]["flow_offloading"] = "0"
        backend.save_config()
        check(backend.call("set", change)["ok"], "block again before cleanup")
        backend.config["networks"]["network.interface.wan"]["up"] = False
        backend.save_config()
        check(backend.call("set", {**change, "blocked": False})["ok"], "unblock works when WAN status is down")
        check(ping("c", "198.18.0.2"), "WAN-down unblock removes the real restriction")
        backend.config["networks"]["network.interface.wan"]["up"] = True
        backend.save_config()
        check(backend.call("set", change)["ok"], "restored WAN permits another block")
        saved_policy = (backend.data / "fw4/policy.nft").read_text()
        (backend.data / "fw4/policy.nft").write_text("damaged")
        check(not backend.call("status")["ok"], "damaged policy is visible as an error")
        check(backend.call("cleanup")["ok"], "cleanup works even with a damaged policy")
        check(backend.call("cleanup")["ok"], "cleanup is idempotent")
        (backend.data / "fw4/policy.nft").write_text(saved_policy)
        after = ns("r", "nft", "-j", "list", "ruleset").stdout
        check("internetblock" not in after, "uninstall deletes all owned runtime objects")
        check("foreign-sentinel" in after and "foreign-established" in after, "uninstall preserves foreign firewall rules")
        check(ping("c", "198.18.0.2"), "WAN access restored after cleanup")
        check((backend.data / "fw4/policy.nft").exists(), "cleanup retains saved application data")
        backend.config["config"]["firewall"] = []
        backend.save_config()
        (backend.data / "fw4/policy.nft").write_text("damaged")
        check(backend.call("reset")["ok"], "manual reset works with damaged policy and unavailable firewall configuration")
        header = (backend.data / "fw4/policy.nft").read_text().splitlines()[0]
        check(json.loads(header.removeprefix("# internetblock-v1 ")) == [], "reset clears saved blocks")
        check((backend.data / "seen.json").exists(), "reset retains device discovery data")
        unsafe = backend.base / "tmp/internetblock"
        unsafe.mkdir(exist_ok=True)
        unsafe.chmod(0o777)
        check(not backend.call("init")["ok"], "backend refuses a writable runtime directory")
        unsafe.chmod(0o700)
        unsafe.rmdir()
        outside = backend.base / "outside"
        outside.mkdir()
        (outside / "sentinel").write_text("untouched")
        unsafe.symlink_to(outside, target_is_directory=True)
        check(not backend.call("init")["ok"], "backend refuses a symlink runtime directory")
        check(list(outside.iterdir()) == [outside / "sentinel"], "unsafe directory cannot redirect root writes")
        unsafe.unlink()
        if os.environ.get("IB_APK") and os.environ.get("IB_APK_TOOL"):
            dump = run(os.environ["IB_APK_TOOL"], "adbdump", os.environ["IB_APK"]).stdout
            scripts = runpy.run_path(str(ROOT / "tools/verify-apk.py"))["scripts_from_dump"](dump)
            rpcd = backend.base / "rpcd"
            rpcd.write_text("#!/bin/sh\nexit 0\n")
            rpcd.chmod(0o755)
            script = scripts["post-deinstall"].replace("/etc/init.d/rpcd", str(rpcd))
            script = script.replace("/tmp/luci-indexcache", str(backend.base / "tmp/cache"))
            script = script.replace("/tmp/internetblock", str(backend.base / "tmp/internetblock"))
            script = script.replace("/var/lock/internetblock.lock", str(backend.base / "lock/internetblock.lock"))
            nft(render("runtime", True))
            ram = backend.base / "tmp/internetblock"
            ram.mkdir(exist_ok=True)
            (ram / "seen.json").write_text("[]")
            ns("r", "env", "-u", "IPKG_INSTROOT", "sh", "-s", input=script)
            after_hook = ns("r", "nft", "-j", "list", "ruleset").stdout
            check("internetblock" not in after_hook, "real APK post-remove hook cleans orphaned runtime objects")
            check("foreign-sentinel" in after_hook, "APK remove hook preserves other rules")
            check(not ram.exists(), "APK remove hook clears owned RAM files")
            check((backend.data / "fw4/policy.nft").exists(), "APK remove hook retains saved policy")
        nft('define lan_devices = {}\ndefine wan_devices = {}\nflush table inet fw4\n'
            'table inet fw4 {\n' + render("fragment", True) + '}\n')
        check(True, "empty zone interface sets do not break a firewall reload")
        print(f"PASS: {passed} network assertions, real nftables packets in isolated namespaces")
    finally:
        if server and server.poll() is None:
            server.terminate()
            server.wait(timeout=3)
        if backend:
            backend.close()
        for space in reversed(created):
            run("ip", "netns", "del", space, check=False)


if __name__ == "__main__":
    main()
