// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Saunakalja
'use strict';
'require view';
'require rpc';
'require poll';
'require ui';

var callStatus = rpc.declare({ object: 'luci.internetblock', method: 'status' });
var callSet = rpc.declare({ object: 'luci.internetblock', method: 'set', params: [ 'mac', 'blocked' ] });
var callRemove = rpc.declare({ object: 'luci.internetblock', method: 'remove', params: [ 'mac' ] });

function ipv4Order(address) {
	var parts = typeof address === 'string' ? address.split('.') : [];
	if (parts.length !== 4 || parts.some(function(part) { return !/^\d{1,3}$/.test(part) || +part > 255; }))
		return Infinity;
	return parts.reduce(function(value, part) { return value * 256 + +part; }, 0);
}

return view.extend({
	load: function() { return callStatus(); },

	render: function(initial) {
		this.busy = false;
		this.messages = E('div', { 'aria-live': 'polite' });
		this.tables = E('div', { 'id': 'internetblock-devices' });
		var page = E('div', {}, [
			E('link', { 'rel': 'stylesheet', 'href': L.resource('view/internetblock/devices.css') + '?v=0.1.0-r7' }),
			E('h2', {}, _('Internet Access')),
			E('p', {}, _('Control IPv4 internet access for LAN devices. Local connections and router services remain available. Allowed removes only this application’s restriction.')),
			this.messages, this.tables
		]);
		this.update(initial);
		poll.add(L.bind(function() {
			if (this.busy) return;
			return callStatus().then(L.bind(this.update, this)).catch(L.bind(function(error) {
				this.showMessages([ _('Refresh failed; the displayed device states may be outdated.') + ' ' + error.message ]);
			}, this));
		}, this), 15);
		return page;
	},

	showMessages: function(messages) {
		this.messages.replaceChildren();
		messages.forEach(L.bind(function(message) {
			this.messages.appendChild(E('div', { 'class': 'alert-message warning' }, document.createTextNode(message)));
		}, this));
	},

	update: function(data) {
		if (!data || !data.ok) {
			this.showMessages([ data && data.error || _('Cannot read Internet Access state.') ]);
			return;
		}
		this.showMessages(data.warnings || []);
		var labels = [ _('Device name'), _('IPv4 address'), _('MAC address'), _('Internet access'), _('Action'), _('Status'), _('Remove') ];
		function createTable() {
			return E('table', { 'class': 'table cbi-section-table' }, [
				E('colgroup', {}, [ 26, 15, 17, 13, 10, 8, 11 ].map(function(width) {
					return E('col', { 'style': 'width: ' + width + '%' });
				})),
				E('tr', { 'class': 'tr table-titles' }, labels.map(function(label) {
					return E('th', { 'class': 'th', 'scope': 'col' }, document.createTextNode(label));
				}))
			]);
		}
		var tables = [], table = null, previousPrefix = null;
		(data.devices || []).slice().sort(function(a, b) {
			var first = ipv4Order(a.ip), second = ipv4Order(b.ip);
			return first === second ? String(a.mac || a.name || '').localeCompare(String(b.mac || b.name || '')) : first - second;
		}).forEach(L.bind(function(device) {
			var prefix = ipv4Order(device.ip) !== Infinity ? device.ip.split('.').slice(0, 3).join('.') : null;
			if (!table || prefix !== previousPrefix) {
				table = createTable();
				tables.push(table);
			}
			previousPrefix = prefix;
			var button = E('button', {
				'class': 'cbi-button ' + (device.blocked ? 'cbi-button-positive' : 'cbi-button-negative'),
				'disabled': (!L.hasViewPermission() || (!device.blocked && (!device.blockable || !data.firewall_ok))) || null,
				'title': !device.blockable && !device.blocked ? _('A valid client MAC and a safe LAN address are required.') : '',
				'click': L.bind(function() { return this.toggle(device); }, this),
				'aria-label': (device.blocked ? _('Allow internet access for ') : _('Block internet access for ')) + (device.name || device.mac)
			}, device.blocked ? _('Allow') : _('Block'));
			var state = device.blocked ? _('Blocked') : _('Allowed');
			var remove = E('button', {
				'class': 'cbi-button cbi-button-remove',
				'disabled': (!L.hasViewPermission() || !device.removable) || null,
				'title': _('Forget an offline, allowed device without a static DHCP reservation. An active sighting will show it again.'),
				'click': L.bind(function() { return this.remove(device); }, this),
				'aria-label': _('Remove remembered device ') + (device.name || device.mac)
			}, _('Remove'));
			if (!data.firewall_ok) state += ' (' + _('saved; unverified') + ')';
			var status = E('strong', { 'class': device.online ? 'internetblock-online' : 'internetblock-offline' },
				document.createTextNode(device.online ? _('Online') : _('Offline')));
			var cells = [ device.name || '—', device.ip || '—', device.mac || '—',
				state, button, status, remove ];
			table.appendChild(E('tr', { 'class': 'tr' }, cells.map(function(value, i) {
				return E('td', { 'class': 'td', 'data-title': labels[i] }, typeof value === 'string' ? document.createTextNode(value) : value);
			})));
		}, this));
		if (!tables.length) {
			table = createTable();
			table.appendChild(E('tr', { 'class': 'tr' }, E('td', { 'class': 'td', 'colspan': 7 }, _('No known LAN devices yet.'))));
			tables.push(table);
		}
		this.tables.replaceChildren(...tables);
	},

	toggle: function(device) {
		return this.change(function() { return callSet(device.mac, !device.blocked); }, _('Access change failed: '));
	},

	remove: function(device) {
		return this.change(function() { return callRemove(device.mac); }, _('Device removal failed: '));
	},

	change: function(action, failureMessage) {
		if (this.busy) return;
		this.busy = true;
		this.tables.querySelectorAll('button').forEach(function(button) { button.disabled = true; });
		return action().then(function(result) {
			if (!result || !result.ok) throw new Error(result && result.error || _('Operation failed.'));
		}).catch(function(error) {
			ui.addNotification(null, E('p', {}, document.createTextNode(failureMessage + error.message)), 'error');
		}).then(L.bind(function() {
			return callStatus().then(L.bind(this.update, this));
		}, this)).catch(L.bind(function(error) {
			this.showMessages([ _('Cannot verify the resulting state: ') + error.message ]);
		}, this)).finally(L.bind(function() { this.busy = false; }, this));
	},

	handleSave: null,
	handleSaveApply: null,
	handleReset: null
});
