// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Saunakalja
import * as fs from 'fs';
import { cursor } from 'uci';
import { connect } from 'ubus';
import * as core from './core.uc';
import * as storage from './storage.uc';

const BASE = '/etc/internetblock';
const POLICY = BASE + '/fw4/policy.nft';
const CACHE = '/tmp/internetblock/seen.json';

function secure_directory(path) {
	fs.mkdir(path, 448);
	let info = fs.lstat(path);
	if (!info || info.type != 'directory' || info.uid != 0 || (info.mode & 18))
		die('Unsafe internetblock directory: ' + path);
}

function quote(s) { return "'" + replace(s, /'/g, "'\\''") + "'"; }
function run(command) {
	let p = fs.popen(command + ' 2>/dev/null', 'r');
	if (!p) die('Cannot execute command');
	let text = p.read('all');
	return { text: text, code: p.close() };
}
function nft(script) {
	let p = fs.popen('/usr/sbin/nft -f - 2>/tmp/internetblock/nft.error', 'w');
	if (!p) die('Cannot start nft');
	p.write(script);
	if (p.close() != 0) die('nft: ' + (fs.readfile('/tmp/internetblock/nft.error') || 'operation failed'));
}
function list(v) { return type(v) == 'array' ? v : (v ? split(v, /\s+/) : []); }
function push_unique(a, v) { if (v && index(a, v) < 0) push(a, v); }

function context(config, bus) {
	let ctx = { lan_devices: [], wan_devices: [], router_ips: [], router_macs: [], subnets: [], ports: [] };
	let zones = {};
	config.foreach('firewall', 'zone', z => { if (z.name == 'lan' || z.name == 'wan') zones[z.name] = z; });
	if (!zones.lan || !zones.wan) die('V1 requires firewall zones named lan and wan');
	for (let zone in ['lan', 'wan']) {
		if (length(list(zones[zone].device))) die('Direct zone device overrides are not supported by v1');
		for (let network in list(zones[zone].network)) {
			let info = bus.call('network.interface.' + network, 'status', {});
			if (!info || !info.up || !info.l3_device) continue;
			let dev = info.l3_device;
			if (!match(dev, /^[a-zA-Z0-9_.:@-]{1,15}$/)) die('Invalid interface name');
			push_unique(ctx[zone + '_devices'], dev);
			for (let addr in info['ipv4-address'] || []) {
				push_unique(ctx.router_ips, addr.address);
				if (zone == 'lan' && addr.mask > 0 && addr.mask <= 30) push(ctx.subnets, addr);
			}
			if (zone == 'lan') {
				push_unique(ctx.ports, dev);
				for (let port in fs.lsdir('/sys/class/net/' + dev + '/brif') || []) push_unique(ctx.ports, port);
			}
		}
	}
	for (let dev in fs.lsdir('/sys/class/net') || []) {
		push_unique(ctx.router_macs, core.mac(trim(fs.readfile('/sys/class/net/' + dev + '/address') || '')));
		// Protect every local IPv4 identity, including loopback and other interfaces.
	}
	let addresses = run('/sbin/ip -4 -o addr show');
	if (addresses.code != 0) die('Cannot read router IPv4 addresses');
	for (let line in split(addresses.text, '\n')) {
		let m = match(line, /\binet ([0-9.]+)\//);
		if (m) push_unique(ctx.router_ips, m[1]);
	}
	if (!length(ctx.lan_devices) || !length(ctx.subnets)) die('LAN is unavailable or unsupported');
	return ctx;
}

function kernel() {
	let result = run('/usr/sbin/nft -j list ruleset');
	if (result.code != 0) die('Cannot read nftables ruleset');
	return core.read_kernel(json(result.text));
}

function discover(config, ctx, blocked, warnings, memory) {
	let data = { static: [], leases: [], neighbors: [], stations: [], blocked: blocked,
		seen: memory };
	config.foreach('dhcp', 'host', h => {
		let macs = list(h.mac);
		if (!length(macs)) macs = [null];
		for (let m in macs) push(data.static, { id: h['.name'], mac: m, name: h.name, ip: h.ip });
	});
	let leases = fs.readfile('/tmp/dhcp.leases');
	if (leases == null) push(warnings, 'DHCP lease data is unavailable');
	for (let line in split(leases || '', '\n')) {
		let f = split(trim(line), /\s+/);
		if (length(f) >= 4) push(data.leases, { mac: f[1], ip: f[2], name: f[3] });
	}
	let neighbors = run('/sbin/ip -4 neigh show');
	if (neighbors.code != 0) push(warnings, 'Neighbor data is unavailable');
	for (let line in split(neighbors.text || '', '\n')) {
		let m = match(line, /^([0-9.]+) dev (\S+) .*lladdr ([0-9a-fA-F:]+)\s+(\S+)/);
		if (m && index(ctx.ports, m[2]) >= 0)
			push(data.neighbors, { ip: m[1], mac: m[3], online: m[4] == 'REACHABLE' });
	}
	let iw = run('/usr/sbin/iw dev');
	if (iw.code != 0) push(warnings, 'Wi-Fi interface data is unavailable');
	for (let line in split(iw.text || '', '\n')) {
		let m = match(line, /\bInterface (\S+)/);
		if (!m || index(ctx.ports, m[1]) < 0) continue;
		let stations = run('/usr/sbin/iw dev ' + quote(m[1]) + ' station dump');
		if (stations.code != 0) { push(warnings, 'Wi-Fi station data is unavailable for ' + m[1]); continue; }
		for (let station in split(stations.text || '', '\n')) {
			let s = match(station, /^Station ([0-9a-fA-F:]+)/);
			if (s) push(data.stations, { mac: s[1] });
		}
	}
	return core.merge(data, ctx);
}

function cache(rows, flush, previous) {
	let data = core.seen(rows, previous), text = sprintf('%J\n', data);
	if (fs.readfile(CACHE) != text) storage.atomic(CACHE, text, false);
	let last = int(fs.readfile('/tmp/internetblock/last-flush') || '0');
	if (flush || time() - last >= 3600) {
		if (fs.readfile(BASE + '/seen.json') != text) storage.atomic(BASE + '/seen.json', text, true);
		storage.atomic('/tmp/internetblock/last-flush', '' + time(), false);
	}
}

function cleanup() {
	let state = kernel();
	let set = run('/usr/sbin/nft list set inet fw4 internetblock_blocked');
	let lan = run('/usr/sbin/nft list set inet fw4 internetblock_lan');
	let wan = run('/usr/sbin/nft list set inet fw4 internetblock_wan');
	let script = core.cleanup(!!state.chain, set.code == 0, lan.code == 0, wan.code == 0);
	if (script) nft(script);
	let after = kernel();
	if (after.chain || run('/usr/sbin/nft list set inet fw4 internetblock_blocked').code == 0 ||
		run('/usr/sbin/nft list set inet fw4 internetblock_lan').code == 0 ||
		run('/usr/sbin/nft list set inet fw4 internetblock_wan').code == 0)
		die('Failed to remove internetblock runtime objects');
	for (let name in ['seen.json', 'last-flush', 'nft.error', 'seen.json.tmp', 'last-flush.tmp'])
		fs.unlink('/tmp/internetblock/' + name);
	fs.rmdir('/tmp/internetblock');
}

let result;
try {
	secure_directory('/tmp/internetblock');
	let lock = fs.open('/var/lock/internetblock.lock', 'a+', 384);
	if (!lock || !lock.lock('xn')) die('Internet Access is busy; try again');
	let command = ARGV[0] || 'status';
	if (command == 'cleanup') { cleanup(); result = { ok: true }; }
	else {
		secure_directory(BASE); secure_directory(BASE + '/fw4');
		if (command == 'init' && !fs.stat(POLICY)) storage.atomic(POLICY, core.fragment([]), true);
		if (command == 'init') result = { ok: true };
		else if (command == 'reset') {
			storage.atomic(POLICY, core.fragment([]), true);
			cleanup();
			result = { ok: true };
		}
		else {
			let config = cursor(), bus = connect();
			if (!config || !bus || !config.load('dhcp') || !config.load('firewall')) die('Cannot load router configuration');
			let ctx = context(config, bus), blocked = core.parse_policy(fs.readfile(POLICY));
			let warnings = [], state = kernel();
			let offload = false;
			config.foreach('firewall', 'defaults', d => { offload = d.flow_offloading == '1' || d.flow_offloading_hw == '1'; });
			offload = offload || state.flowtable;
			let memory = storage.read_json(CACHE, storage.read_json(BASE + '/seen.json', []));
			let rows = discover(config, ctx, blocked, warnings, memory);
			for (let row in rows)
				row.removable = row.removable && !length(warnings) && index(state.blocked, row.mac) < 0;
			cache(rows, command == 'flush', memory);
			function apply(values) {
				// Rebuild only our chain when interfaces change. Unblock still works
				// with a down WAN by updating the existing set transactionally.
				if (!length(ctx.wan_devices) && state.chain) {
					nft('flush set inet fw4 internetblock_blocked\n' +
						(length(values) ? 'add element inet fw4 internetblock_blocked { ' + join(', ', values) + ' }\n' : ''));
				}
				else nft(core.runtime(values, ctx));
			}
			if (command == 'scan' && !offload && length(ctx.wan_devices) && !core.kernel_matches(blocked, state, ctx)) {
				for (let m in blocked) if (!core.safe_mac(m, ctx)) die('Saved policy contains a router identity');
				apply(blocked);
				state = kernel();
			}
			if (command == 'remove') {
				let request = json(fs.readfile('/dev/stdin'));
				if (type(request) != 'object') die('Expected a device MAC');
				let desired = core.forget(request.mac, rows, memory);
				storage.replace_memory(BASE + '/seen.json', CACHE, sprintf('%J\n', desired));
				result = { ok: true };
			}
			else if (command == 'set') {
				let request = json(fs.readfile('/dev/stdin'));
				if (type(request) != 'object' || type(request.blocked) != 'bool') die('Expected a MAC and boolean blocked');
				let target = core.mac(request.mac);
				if (!target) die('Missing or invalid unicast MAC');
				if (request.blocked) {
					if (offload) die('Flow offloading is unsupported by v1; router settings were not changed');
					let device = filter(rows, r => r.mac == target && r.blockable);
					if (!length(device) || !core.safe_mac(target, ctx)) die('Target is unknown, invalid or belongs to the router');
					if (!length(ctx.wan_devices)) die('WAN is unavailable');
				}
				let desired = filter(blocked, m => m != target);
				if (request.blocked) push(desired, target);
				desired = core.normalize_policy(desired);
				core.change(blocked, desired, {
					save: text => storage.atomic(POLICY, text, true), apply: apply,
					matches: values => {
						let s = kernel();
						return !request.blocked && !length(ctx.wan_devices) ?
							sprintf('%J', values) == sprintf('%J', s.blocked) : core.kernel_matches(values, s, ctx);
					}
				});
				result = { ok: true };
			}
			else if (command == 'apply') {
				for (let m in blocked) if (!core.safe_mac(m, ctx)) die('Saved policy contains a router identity');
				if (offload && length(blocked)) die('Flow offloading is unsupported by v1');
				apply(blocked);
				if (!core.kernel_matches(blocked, kernel(), ctx)) die('Firewall verification failed');
				result = { ok: true };
			}
			else if (command == 'status' || command == 'scan' || command == 'flush') {
				if (offload) push(warnings, 'Flow offloading is enabled: v1 cannot guarantee enforcement');
				let healthy = core.kernel_matches(blocked, state, ctx) && !offload;
				if (!healthy) push(warnings, 'Firewall state is not verified; saved access decisions may not be enforced');
				result = { ok: true, devices: rows, warnings: warnings, firewall_ok: !!healthy };
			}
			else die('Unknown command');
		}
	}
}
catch (e) { result = { ok: false, error: '' + e }; }
printf('%J\n', result);
exit(result.ok ? 0 : 1);
