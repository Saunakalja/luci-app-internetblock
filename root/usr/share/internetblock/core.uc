// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Saunakalja
// Pure policy/discovery functions, shared by the backend and local tests.
export function mac(value) {
	if (type(value) != 'string') return null;
	let m = lc(trim(value));
	return match(m, /^[0-9a-f][02468ace](:[0-9a-f]{2}){5}$/) &&
		m != '00:00:00:00:00:00' ? m : null;
};

export function ipnum(value) {
	if (type(value) != 'string' || !match(value, /^\d{1,3}(\.\d{1,3}){3}$/)) return null;
	let n = 0;
	for (let octet in split(value, '.')) {
		let v = int(octet);
		if (v < 0 || v > 255) return null;
		n = n * 256 + v;
	}
	return n;
};

export function host_ip(value, context) {
	let n = ipnum(value);
	if (n == null || index(context.router_ips, value) >= 0) return false;
	for (let subnet in context.subnets) {
		let mask = (0xffffffff << (32 - subnet.mask)) & 0xffffffff;
		let net = ipnum(subnet.address) & mask;
		if ((n & mask) == net && n != net && n != (net | (0xffffffff ^ mask)))
			return true;
	}
	return false;
};

export function safe_mac(value, context) {
	let m = mac(value);
	return m && index(context.router_macs, m) < 0 ? m : null;
};

export function merge(data, context) {
	let rows = {}, forgotten = {};
	function add(record, source, priority, online) {
		let m = safe_mac(record.mac, context);
		// A router MAC must never be offered as a client, even in stale data.
		if (mac(record.mac) && !m) return;
		if (!m && source != 'static') return;
		let key = m || ('static:' + record.id);
		let row = rows[key];
		if (!row) {
			row = { mac: m, name: '', ip: '', online: false, blocked: false,
				name_priority: 0, ip_priority: 0, sources: [], bad_ip: false };
			rows[key] = row;
		}
		if (index(row.sources, source) < 0) push(row.sources, source);
		if (record.name && record.name != '*' && priority > row.name_priority) {
			row.name = substr(replace(record.name, /[[:cntrl:]]/g, ''), 0, 64);
			row.name_priority = priority;
		}
		if (record.ip) {
			if (host_ip(record.ip, context)) {
				let ip_priority = source == 'dhcp' ? 50 : source == 'neighbor' ? (online ? 60 : 20) : priority;
				if (ip_priority > row.ip_priority) { row.ip = record.ip; row.ip_priority = ip_priority; }
				row.bad_ip = false;
			}
			else if (!row.ip_priority) {
				row.bad_ip = true;
				if (ipnum(record.ip) != null) row.ip = record.ip;
			}
		}
		row.online = row.online || !!online;
	}
	for (let r in data.seen || []) {
		if (r.forgotten) { let m = mac(r.mac); if (m) forgotten[m] = true; }
		else add(r, 'seen', 10, false);
	}
	for (let r in data.static || []) add(r, 'static', 40, false);
	for (let r in data.leases || []) add(r, 'dhcp', 30, false);
	for (let r in data.neighbors || []) add(r, 'neighbor', 50, r.online);
	for (let r in data.stations || []) add(r, 'wifi', 20, true);
	for (let m in data.blocked || []) add({ mac: m }, 'policy', 1, false);
	let result = [];
	for (let key, r in rows) {
		r.blocked = index(data.blocked || [], r.mac) >= 0;
		r.blockable = !!r.mac && !r.bad_ip;
		r.removable = !!r.mac && !r.online && !r.blocked && index(r.sources, 'static') < 0;
		if (forgotten[r.mac] && r.removable) continue;
		delete r.name_priority; delete r.ip_priority; delete r.bad_ip;
		push(result, r);
	}
	return sort(result, (a, b) => lc(a.name || a.mac || a.ip) < lc(b.name || b.mac || b.ip) ? -1 : 1);
};

export function seen(rows, previous) {
	let result = map(filter(rows, r => !!r.mac), r => ({ mac: r.mac, ip: r.ip, name: r.name }));
	let kept = map(result, r => r.mac);
	for (let r in previous || []) {
		let m = mac(r.mac);
		if (r.forgotten && m && index(kept, m) < 0) {
			push(result, { mac: m, forgotten: true }); push(kept, m);
		}
	}
	return sort(result, (a, b) => a.mac < b.mac ? -1 : 1);
};

export function forget(target, rows, previous) {
	let m = mac(target);
	if (!m) die('Missing or invalid unicast MAC');
	let device = filter(rows, r => r.mac == m)[0];
	if (!device || !device.removable)
		die('Only verified offline, allowed devices without a static DHCP reservation can be removed');
	let result = filter(seen(filter(rows, r => r.mac != m), previous), r => r.mac != m);
	push(result, { mac: m, forgotten: true });
	return sort(result, (a, b) => a.mac < b.mac ? -1 : 1);
};

export function normalize_policy(values) {
	if (type(values) != 'array') die('Invalid saved block list');
	let result = [];
	for (let v in values) {
		let m = mac(v);
		if (!m) die('Invalid MAC in saved block list');
		if (index(result, m) < 0) push(result, m);
	}
	return sort(result);
};

export function fragment(values) {
	let policy = normalize_policy(values);
	return '# internetblock-v1 ' + sprintf('%J', policy) + '\n' +
		'set internetblock_blocked {\n\ttype ether_addr;\n' +
		(length(policy) ? '\telements = { ' + join(', ', policy) + ' };\n' : '') +
		'}\nset internetblock_lan { type ifname; elements = $lan_devices; }\n' +
		'set internetblock_wan { type ifname; elements = $wan_devices; }\n' +
		'chain internetblock_forward {\n' +
		'\ttype filter hook forward priority -1; policy accept;\n' +
		'\tmeta nfproto ipv4 iifname @internetblock_lan oifname @internetblock_wan ' +
		'ether saddr @internetblock_blocked counter drop comment "internetblock: LAN to WAN"\n}\n';
};

export function parse_policy(text) {
	if (type(text) != 'string' || index(text, '# internetblock-v1 ') != 0)
		die('Missing or damaged internetblock policy');
	let end = index(text, '\n');
	let policy = normalize_policy(json(substr(text, 19, end - 19)));
	if (text != fragment(policy)) die('Saved policy was edited or damaged; restore a valid policy file');
	return policy;
};

function interfaces(devices) {
	for (let d in devices)
		if (!match(d, /^[a-zA-Z0-9_.:@-]{1,15}$/)) die('Invalid network device name');
	return '{ ' + join(', ', map(devices, d => '"' + d + '"')) + ' }';
};

export function runtime(values, context) {
	let policy = normalize_policy(values);
	let lan = interfaces(context.lan_devices), wan = interfaces(context.wan_devices);
	let rule = 'meta nfproto ipv4 iifname @internetblock_lan oifname @internetblock_wan' +
		' ether saddr @internetblock_blocked counter drop comment "internetblock: LAN to WAN"';
	return 'add set inet fw4 internetblock_blocked { type ether_addr; }\n' +
		'flush set inet fw4 internetblock_blocked\n' +
		(length(policy) ? 'add element inet fw4 internetblock_blocked { ' + join(', ', policy) + ' }\n' : '') +
		'add set inet fw4 internetblock_lan { type ifname; }\nflush set inet fw4 internetblock_lan\n' +
		(length(context.lan_devices) ? 'add element inet fw4 internetblock_lan ' + lan + '\n' : '') +
		'add set inet fw4 internetblock_wan { type ifname; }\nflush set inet fw4 internetblock_wan\n' +
		(length(context.wan_devices) ? 'add element inet fw4 internetblock_wan ' + wan + '\n' : '') +
		'add chain inet fw4 internetblock_forward { type filter hook forward priority -1; policy accept; }\n' +
		'flush chain inet fw4 internetblock_forward\n' +
		'add rule inet fw4 internetblock_forward ' + rule + '\n';
};

export function cleanup(chain, set, lan, wan) {
	return (chain ? 'delete chain inet fw4 internetblock_forward\n' : '') +
		(set ? 'delete set inet fw4 internetblock_blocked\n' : '') +
		(lan ? 'delete set inet fw4 internetblock_lan\n' : '') +
		(wan ? 'delete set inet fw4 internetblock_wan\n' : '');
};

export function read_kernel(document) {
	let state = { blocked: [], lan_devices: [], wan_devices: [], chain: null, rules: [], flowtable: false };
	for (let entry in document.nftables || []) {
		if (entry.flowtable) state.flowtable = true;
		let s = entry.set;
		if (s && s.family == 'inet' && s.table == 'fw4' && s.name == 'internetblock_blocked')
			state.blocked = normalize_policy(s.elem || []);
		if (s && s.family == 'inet' && s.table == 'fw4' && s.name == 'internetblock_lan') state.lan_devices = s.elem || [];
		if (s && s.family == 'inet' && s.table == 'fw4' && s.name == 'internetblock_wan') state.wan_devices = s.elem || [];
		let c = entry.chain;
		if (c && c.family == 'inet' && c.table == 'fw4' && c.name == 'internetblock_forward') state.chain = c;
		let r = entry.rule;
		if (r && r.family == 'inet' && r.table == 'fw4' && r.chain == 'internetblock_forward') push(state.rules, r);
	}
	return state;
};

export function kernel_matches(values, state, context) {
	let chain = state.chain;
	if (!chain || chain.type != 'filter' || chain.hook != 'forward' || chain.prio != -1 ||
		chain.policy != 'accept' || length(state.rules) != 1 ||
		sprintf('%J', normalize_policy(values)) != sprintf('%J', state.blocked)) return false;
	let rule = state.rules[0], found = {};
	if (length(rule.expr) != 6) return false;
	for (let expr in rule.expr) {
		if (expr.counter) { found.counter = true; continue; }
		if (exists(expr, 'drop')) { found.drop = true; continue; }
		let m = expr.match;
		if (!m || m.op != '==') return false;
		let key = m.left.meta?.key, p = m.left.payload;
		if (key == 'nfproto' && m.right == 'ipv4') found.ipv4 = true;
		else if ((key == 'iifname' || key == 'oifname')) {
			let side = key == 'iifname' ? 'lan' : 'wan';
			if (m.right != '@internetblock_' + side) return false;
			let devices = state[side + '_devices'], expected = context[side + '_devices'];
			if (sprintf('%J', sort([...devices])) != sprintf('%J', sort([...expected]))) return false;
			found[key] = true;
		}
		else if (p?.protocol == 'ether' && p.field == 'saddr' && m.right == '@internetblock_blocked') found.mac = true;
		else return false;
	}
	return !!(found.ipv4 && found.iifname && found.oifname && found.mac && found.drop && found.counter);
};

// Persist first: any crash restores the acknowledged policy at firewall reload.
// A failed live apply rolls persistence and runtime back; never claim success.
export function change(old, desired, ops) {
	let before = fragment(old), after = fragment(desired);
	if (before == after && ops.matches(desired)) return;
	try {
		ops.save(after);
		ops.apply(desired);
		if (!ops.matches(desired)) die('Runtime verification failed');
	}
	catch (e) {
		let failure = '' + e;
		try { ops.save(before); ops.apply(old); }
		catch (rollback) { die(failure + '; rollback failed: ' + rollback + '; inspect policy and runtime'); }
		die(failure + '; previous policy restored');
	}
};
