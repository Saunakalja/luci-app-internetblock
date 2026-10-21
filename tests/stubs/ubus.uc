// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Saunakalja
import * as fs from 'fs';
export function connect() {
	let networks = json(fs.readfile(getenv('IB_FIXTURE'))).networks;
	return { call: (object, method, args) => networks[object] };
};
