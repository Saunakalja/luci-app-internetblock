// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Saunakalja
import * as fs from 'fs';

export function atomic(path, text, durable) {
	let temporary = path + '.tmp';
	let file = fs.open(temporary, 'w', 384);
	if (!file) die('Cannot create ' + temporary + ': ' + fs.error());
	let written = file.write(text);
	let closed = file.close();
	if (written != length(text) || !closed) {
		fs.unlink(temporary);
		die('Cannot write ' + path);
	}
	if (!fs.rename(temporary, path)) { fs.unlink(temporary); die('Cannot replace ' + path + ': ' + fs.error()); }
	// Explicit policy changes are rare. Sync before acknowledging persistence.
	if (durable && system('/bin/sync') != 0) die('Cannot sync saved policy');
};

export function read_json(path, fallback) {
	let text = fs.readfile(path);
	if (text == null) {
		if (fs.stat(path)) die('Cannot read ' + path);
		return fallback;
	}
	return json(text);
};

export function replace_memory(path, cache, text) {
	let before = fs.readfile(path), ram = fs.readfile(cache);
	if ((before == null && fs.stat(path)) || (ram == null && fs.stat(cache))) die('Cannot read device memory');
	// Invalidate RAM first: a crash after the durable rename must not allow an
	// older RAM snapshot to overwrite the acknowledged removal on the next scan.
	if (ram != null && !fs.unlink(cache)) die('Cannot invalidate device memory cache');
	try { atomic(path, text, true); }
	catch (e) {
		try {
			if (before != null && fs.readfile(path) != before) atomic(path, before, true);
			else if (before == null && fs.stat(path)) {
				if (!fs.unlink(path) || system('/bin/sync') != 0) die('Cannot restore absent device memory');
			}
			if (ram != null) atomic(cache, ram, false);
		}
		catch (rollback) { die('Removal failed: ' + e + '; memory rollback failed: ' + rollback); }
		die('Removal failed; previous memory restored: ' + e);
	}
};
