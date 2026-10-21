// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Saunakalja
import * as fs from 'fs';
export function cursor() {
	let data = json(fs.readfile(getenv('IB_FIXTURE'))).config;
	return {
		load: name => exists(data, name),
		foreach: (name, kind, callback) => {
			for (let section in data[name] || []) if (section['.type'] == kind) callback(section);
			return true;
		}
	};
};
