// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Saunakalja
// Behavioral tests for the LuCI view without a browser or router.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const source = fs.readFileSync(path.join(__dirname, '../htdocs/luci-static/resources/view/internetblock/devices.js'), 'utf8');

class Element {
    constructor(tag, attributes = {}, children = []) {
        this.tag = tag;
        this.attributes = attributes;
        // LuCI E() uses setAttribute for every non-null value, including false.
        // HTML boolean attributes depend on presence, not their string value.
        this.disabled = attributes.disabled != null;
        this.children = [];
        this.replaceChildren(children);
    }
    appendChild(child) { this.children.push(child); return child; }
    replaceChildren(...children) { this.children = children.flat().filter(v => v != null); }
    querySelectorAll(tag) {
        return this.children.flatMap(child => child instanceof Element ?
            [ ...(child.tag === tag ? [child] : []), ...child.querySelectorAll(tag) ] : []);
    }
}
const E = (tag, attrs, children) => new Element(tag, attrs, children);
const notifications = [];
let writable = true;
let calls = [];
let failSet = false;
let failRemove = false;
let sample = {
    ok: true, firewall_ok: true, warnings: [], devices: [
        { name: '<script>example</script>', mac: '02:00:00:00:00:10', ip: '192.0.2.10', online: true, blocked: false, blockable: true },
        { name: 'Sleeping', mac: '02:00:00:00:00:20', ip: '192.0.2.20', online: false, blocked: true, blockable: true },
        { name: 'No MAC', mac: null, ip: '192.0.2.30', online: false, blocked: false, blockable: false }
    ]
};
const rpc = { declare: spec => async (...args) => {
    calls.push({ method: spec.method, args });
    if (spec.method === 'set') {
        if (failSet) return { ok: false, error: 'injected failure' };
        sample.devices.find(d => d.mac === args[0]).blocked = args[1];
        return { ok: true };
    }
    if (spec.method === 'remove') {
        if (failRemove) return { ok: false, error: 'removal refused' };
        sample.devices = sample.devices.filter(d => d.mac !== args[0]);
        return { ok: true };
    }
    return structuredClone(sample);
} };
const poll = { add(fn) { this.callback = fn; } };
const L = { bind: (fn, self) => fn.bind(self), hasViewPermission: () => writable,
    resource: path => '/luci-static/resources/' + path };
const document = { createTextNode: text => ({ textContent: text }) };
const view = new Function('rpc', 'view', 'poll', 'ui', 'L', 'E', '_', 'document', source)(
    rpc, { extend: value => value }, poll,
    { addNotification: (...args) => notifications.push(args) }, L, E, text => text, document
);

(async () => {
    const initial = await view.load();
    const page = view.render(initial);
    assert.equal(page.querySelectorAll('button').length, 6);
    const tables = () => view.tables.querySelectorAll('table');
    const rowsIn = table => table.children.filter(row => row.attributes.class === 'tr' && row.children.length === 7);
    const deviceRows = () => tables().flatMap(rowsIn);
    const actionButtons = () => deviceRows().map(row => row.children[4].children[0]);
    const removeButtons = () => deviceRows().map(row => row.children[6].children[0]);
    const headerIn = table => table.children.find(row => row.attributes.class === 'tr table-titles');
    assert.equal(tables().length, 1, 'one address group needs only one table');
    assert.equal(view.tables.querySelectorAll('button')[0].disabled, false, 'valid block button is clickable');
    assert.equal(actionButtons()[2].disabled, true);
    assert.equal(removeButtons().every(button => button.disabled), true, 'ineligible devices cannot be removed');
    assert.equal(deviceRows()[0].children[0].attributes['data-title'], 'Device name');
    assert.equal(deviceRows()[0].children[4].attributes['data-title'], 'Action');
    assert.deepEqual(headerIn(tables()[0]).children.map(cell => cell.children[0].textContent),
        ['Device name', 'IPv4 address', 'MAC address', 'Internet access', 'Action', 'Status', 'Remove']);
    const online = deviceRows()[0].children[5].children[0];
    assert.deepEqual([online.tag, online.attributes.class, online.children[0].textContent],
        ['strong', 'internetblock-online', 'Online']);
    const offline = deviceRows()[1].children[5].children[0];
    assert.deepEqual([offline.tag, offline.attributes.class, offline.children[0].textContent],
        ['strong', 'internetblock-offline', 'Offline']);
    assert.equal(deviceRows()[0].children[4].children[0].tag, 'button');
    assert.equal(page.querySelectorAll('link')[0].attributes.href,
        '/luci-static/resources/view/internetblock/devices.css?v=0.1.0-r7');
    const firstName = deviceRows()[0].children[0].children[0];
    assert.deepEqual(firstName, { textContent: '<script>example</script>' });
    assert.equal(view.tables.querySelectorAll('script').length, 0);
    await view.toggle(sample.devices[0]);
    assert.deepEqual(calls.find(c => c.method === 'set').args, ['02:00:00:00:00:10', true]);
    assert.equal(view.busy, false);
    failSet = true;
    await view.toggle(sample.devices[0]);
    assert.equal(notifications.length, 1);
    assert.match(notifications[0][1].children[0].textContent, /injected failure/);
    assert.equal(sample.devices[0].blocked, true);
    sample.firewall_ok = false;
    sample.devices[0].blocked = false;
    view.update(sample);
    assert.equal(view.tables.querySelectorAll('button')[0].disabled, true);
    assert.equal(actionButtons()[1].disabled, false, 'unblock remains available');
    writable = false;
    view.update(sample);
    assert.equal(view.tables.querySelectorAll('button').every(b => b.disabled), true);
    view.update({ ok: false, error: 'backend unavailable' });
    assert.equal(view.messages.children[0].children[0].textContent, 'backend unavailable');

    // Arrival order and names must not override numeric IPv4 ordering. Keep
    // guest addresses after the LAN and put unusable/missing addresses last.
    const inputIps = ['203.0.113.100', '192.0.2.10', null, '203.0.113.2',
        '192.0.2.2', '198.51.100.1', '192.0.2.300'];
    sample = { ok: true, firewall_ok: true, warnings: [], devices: inputIps.map((ip, i) => ({
        name: 'Device ' + i, mac: '02:00:00:00:00:' + (16 + i).toString(16),
        ip, online: i % 2 === 0, blocked: false, blockable: !!ip, removable: i % 2 !== 0
    })) };
    writable = true;
    view.update(sample);
    const displayedIps = () => deviceRows().map(row => row.children[1].children[0].textContent);
    const expectedIps = ['192.0.2.2', '192.0.2.10', '198.51.100.1',
        '203.0.113.2', '203.0.113.100', '—', '192.0.2.300'];
    assert.deepEqual(displayedIps(), expectedIps);
    assert.equal(tables().length, 4, 'three IPv4 groups and unknown addresses get separate tables');
    assert.deepEqual(sample.devices.map(device => device.ip), inputIps, 'rendering must not reorder RPC data');
    failSet = false;
    await deviceRows()[0].children[4].children[0].attributes.click();
    assert.deepEqual(calls.filter(call => call.method === 'set').at(-1).args,
        ['02:00:00:00:00:14', true], 'sorted row must still toggle its own device');
    sample.devices.reverse();
    await poll.callback();
    assert.deepEqual(displayedIps(), expectedIps, 'polling preserves the selected sort order');

    const allDevices = sample.devices;
    sample.devices = allDevices.filter(device => device.ip && /^(192\.0\.2|203\.0\.113)\./.test(device.ip) && !device.ip.endsWith('.300'));
    view.update(sample);
    assert.equal(tables().length, 2, 'LAN and guest addresses have independent table boxes');
    assert.deepEqual(tables().map(table => rowsIn(table).map(row => row.children[1].children[0].textContent)),
        [['192.0.2.2', '192.0.2.10'], ['203.0.113.2', '203.0.113.100']]);
    assert.equal(tables().every(table => table.children.filter(row => row.tag === 'tr').every(row => row.children.length === 7)),
        true, 'no blank or colspan spacer rows inside either table');
    assert.deepEqual(headerIn(tables()[0]).children, headerIn(tables()[1]).children, 'repeat headings in each table');
    assert.deepEqual(tables()[0].querySelectorAll('col').map(col => col.attributes.style),
        tables()[1].querySelectorAll('col').map(col => col.attributes.style), 'both tables share column widths');
    const change = deviceRows().find(row => row.children[1].children[0].textContent === '203.0.113.2').children[4].children[0].attributes.click();
    assert.equal(view.tables.querySelectorAll('button').every(button => button.disabled), true, 'disable every group during a change');
    await change;
    assert.deepEqual(calls.filter(call => call.method === 'set').at(-1).args,
        ['02:00:00:00:00:13', true], 'second table must still toggle the selected device');
    const removable = sample.devices.find(device => device.ip === '203.0.113.2');
    removable.blocked = false;
    view.update(sample);
    assert.equal(removeButtons()[2].disabled, false, 'eligible offline guest can be forgotten');
    writable = false;
    view.update(sample);
    assert.equal(removeButtons().every(button => button.disabled), true, 'read-only view cannot remove devices');
    writable = true;
    view.update(sample);
    failRemove = true;
    await removeButtons()[2].attributes.click();
    assert.equal(notifications.at(-1)[1].children[0].textContent, 'Device removal failed: removal refused');
    assert.equal(deviceRows().length, 4, 'failed removal preserves displayed row');
    failRemove = false;
    const removal = removeButtons()[2].attributes.click();
    assert.equal(view.tables.querySelectorAll('button').every(button => button.disabled), true, 'removal locks every group');
    await removal;
    assert.deepEqual(calls.filter(call => call.method === 'remove').at(-1).args,
        ['02:00:00:00:00:13'], 'Remove targets its own sorted row');
    assert.equal(deviceRows().length, 3, 'successful removal refreshes list');
    assert.equal(view.busy, false, 'removal releases action lock');
    for (const prefix of ['192.0.2.', '203.0.113.']) {
        sample.devices = allDevices.filter(device => device.ip && device.ip.startsWith(prefix) && !device.ip.endsWith('.300'));
        view.update(sample);
        assert.equal(tables().length, 1, 'a group alone must have no empty table before or after it');
    }
    sample.devices = allDevices.filter(device => !device.ip || device.ip.endsWith('.300'));
    view.update(sample);
    assert.equal(tables().length, 1, 'unknown addresses stay together');
    sample.devices = [];
    view.update(sample);
    assert.deepEqual([tables().length, view.tables.querySelectorAll('button').length], [1, 0]);
    console.log('PASS: 47 frontend assertions');
})().catch(error => { console.error(error); process.exitCode = 1; });
