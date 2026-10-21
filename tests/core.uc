// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Saunakalja
import * as core from '../root/usr/share/internetblock/core.uc';
import * as fs from 'fs';
import * as storage from '../root/usr/share/internetblock/storage.uc';

let count = 0;
function assert(condition, message) {
	if (!condition) die('FAIL: ' + message);
	count++;
}
function throws(fn, message) {
	let failed = false;
	try { fn(); } catch (e) { failed = true; }
	assert(failed, message);
}
let ctx = { router_ips: ['192.0.2.1'], router_macs: ['02:00:00:00:00:01'],
	subnets: [{ address: '192.0.2.1', mask: 24 }], lan_devices: ['ib-lan'], wan_devices: ['ib-wan'] };
let a = '02:00:00:00:00:10', b = '02:00:00:00:00:20', c = '02:00:00:00:00:30';
assert(core.mac('02:AA:BB:CC:DD:EE') == '02:aa:bb:cc:dd:ee', 'MAC normalization');
for (let invalid in ['', null, 'ff:ff:ff:ff:ff:ff', '01:00:5e:00:00:01', '00:00:00:00:00:00', a + ';flush ruleset'])
	assert(core.mac(invalid) == null, 'reject invalid/group MAC');
for (let ip in ['192.0.2.0', '192.0.2.255', '192.0.2.1', '255.255.255.255', '198.51.100.10', '999.1.1.1'])
	assert(!core.host_ip(ip, ctx), 'exclude router, network, broadcast and foreign subnet');
assert(core.host_ip('192.0.2.10', ctx), 'ordinary LAN host');
assert(!core.safe_mac(ctx.router_macs[0], ctx), 'router MAC protected');

let rows = core.merge({
	static: [{ id: 'one', mac: a, ip: '192.0.2.10', name: 'Fixed plug' },
		{ id: 'offline', mac: b, ip: '192.0.2.20', name: 'Sleeping sensor' },
		{ id: 'missing', name: 'No MAC', ip: '192.0.2.40' },
		{ id: 'broadcast', mac: '02:00:00:00:00:50', ip: '192.0.2.255' },
		{ id: 'router', mac: ctx.router_macs[0], ip: '192.0.2.1' }],
	leases: [{ mac: a, ip: '192.0.2.11', name: 'DHCP name' }],
	neighbors: [{ mac: a, ip: '192.0.2.12', online: true }],
	stations: [{ mac: a }], seen: [{ mac: c, ip: '192.0.2.30', name: 'Seen last week' }], blocked: [b]
}, ctx);
assert(length(rows) == 5, 'merge/dedup and router omission');
let plug = filter(rows, r => r.mac == a)[0];
assert(plug.name == 'Fixed plug' && plug.ip == '192.0.2.12' && plug.online, 'static name, current neighbor IP, live status');
let sleeping = filter(rows, r => r.mac == b)[0];
assert(!sleeping.online && sleeping.blocked, 'static offline block survives');
assert(!filter(rows, r => r.mac == c)[0].online, 'seen-only device stays offline');
assert(!filter(rows, r => r.name == 'No MAC')[0].blockable, 'missing MAC cannot be blocked');
assert(!filter(rows, r => r.mac == '02:00:00:00:00:50')[0].blockable, 'broadcast target cannot be blocked');
let dynamic = core.merge({ leases: [{ mac: a, ip: '192.0.2.10' }] }, ctx);
assert(!dynamic[0].online, 'lease does not prove online');
let reboot = core.merge({ seen: core.seen(rows), blocked: [b] }, ctx);
assert(length(reboot) == 4 && !filter(reboot, r => r.online).length, 'seen persistence survives without live sources');
assert(dynamic[0].removable, 'offline dynamic device can be forgotten');
assert(!plug.removable && !sleeping.removable, 'online and blocked reservations cannot be forgotten');
assert(!filter(rows, r => r.name == 'No MAC')[0].removable, 'missing MAC cannot be forgotten');
let forgotten = core.forget(a, dynamic, []);
assert(sprintf('%J', forgotten) == sprintf('%J', [{ mac: a, forgotten: true }]), 'forget saves only a MAC marker');
let old = { seen: forgotten, leases: [{ mac: a, ip: '192.0.2.10', name: 'Old lease' }],
	neighbors: [{ mac: a, ip: '192.0.2.10', online: false }] };
assert(!length(core.merge(old, ctx)), 'old lease and stale neighbor cannot resurrect forgotten device');
assert(sprintf('%J', core.seen([], forgotten)) == sprintf('%J', forgotten), 'absent marker survives collection');
old.stations = [{ mac: a }];
let returned = core.merge(old, ctx);
assert(length(returned) == 1 && returned[0].online && !returned[0].removable, 'active station restores visibility');
let remembered = core.seen(returned, forgotten);
assert(!remembered[0].forgotten && remembered[0].ip == '192.0.2.10', 'active sighting replaces marker with identity');
delete old.stations;
old.neighbors[0].online = true;
assert(core.merge(old, ctx)[0].online, 'reachable neighbor restores visibility');
old.neighbors[0].online = false;
old.static = [{ id: 'new', mac: a, ip: '192.0.2.10' }];
assert(!core.merge(old, ctx)[0].removable, 'reservation always overrides marker');
delete old.static;
old.blocked = [a];
assert(core.merge(old, ctx)[0].blocked && !core.merge(old, ctx)[0].removable, 'policy always overrides marker');
for (let target in [b, null, 'ff:ff:ff:ff:ff:ff', ctx.router_macs[0]])
	throws(() => core.forget(target, dynamic, []), 'unknown, invalid and router removals refused');
for (let source in [{ static: [{ id: 's', mac: a }] }, { stations: [{ mac: a }] }, { blocked: [a] }])
	throws(() => core.forget(a, core.merge(source, ctx), []), 'static, online and blocked removals refused');

let policy = core.fragment([b, a, b]);
assert(sprintf('%J', core.parse_policy(policy)) == sprintf('%J', [a, b]), 'policy persistence round trip and dedup');
throws(() => core.parse_policy(policy + 'flush ruleset\n'), 'reject damaged policy instead of silently overwriting');
let rules = core.runtime([a], ctx);
assert(index(rules, 'priority -1') >= 0, 'block before established acceptance');
assert(index(rules, 'meta nfproto ipv4 iifname @internetblock_lan oifname @internetblock_wan') >= 0 &&
	index(rules, 'add element inet fw4 internetblock_lan { "ib-lan" }') >= 0 &&
	index(rules, 'add element inet fw4 internetblock_wan { "ib-wan" }') >= 0, 'IPv4 LAN to WAN only');
assert(index(rules, 'ether saddr @internetblock_blocked') >= 0, 'MAC match independent of IP');
assert(index(rules, 'hook input') < 0 && index(rules, 'hook output') < 0 && index(rules, 'flush table') < 0, 'no router services or foreign rules modified');
assert(index(core.runtime([], ctx), 'add element inet fw4 internetblock_blocked') < 0, 'unblock clears set without residual elements');
throws(() => core.runtime([a], { lan_devices: ['x";flush ruleset'], wan_devices: ['ib-wan'] }), 'interface injection refused');

let saved = core.fragment([]), live = [], fails = false;
let ops = {
	save: text => { saved = text; },
	apply: values => { if (fails && length(values)) die('injected nft failure'); live = values; },
	matches: values => sprintf('%J', values) == sprintf('%J', live)
};
core.change([], [a], ops);
assert(saved == core.fragment([a]) && live[0] == a, 'block saved and applied');
core.change([a], [], ops);
assert(saved == core.fragment([]) && !length(live), 'unblock saved and applied');
fails = true;
throws(() => core.change([], [a], ops), 'nft failure reaches caller');
assert(saved == core.fragment([]) && !length(live), 'nft failure rolls back persisted decision and runtime');
throws(() => core.change([], [a], { save: text => { die('disk full'); }, apply: v => { live = v; }, matches: v => false }), 'disk failure reported');
assert(!length(live), 'failed save cannot create a live block');
let path = '/tmp/internetblock-storage-' + time();
storage.atomic(path, policy, false);
assert(core.parse_policy(fs.readfile(path))[0] == a, 'real filesystem persistence');
storage.atomic(path, core.fragment([]), false);
assert(!length(core.parse_policy(fs.readfile(path))), 'real filesystem unblock persists');
fs.unlink(path);
let cache = path + '.cache';
storage.atomic(path, 'old', false);
storage.atomic(cache, 'cached', false);
fs.mkdir(path + '.tmp', 448);
throws(() => storage.replace_memory(path, cache, 'new'), 'failed durable removal reaches caller');
assert(fs.readfile(path) == 'old' && fs.readfile(cache) == 'cached', 'failed removal restores prior disk and RAM');
fs.rmdir(path + '.tmp');
storage.replace_memory(path, cache, sprintf('%J', forgotten));
assert(!fs.stat(cache) && storage.read_json(path, [])[0].forgotten, 'durable marker replaces disk and invalidates old RAM');
fs.unlink(path);
printf('PASS: %d core assertions\n', count);
