// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Saunakalja
import * as core from '../root/usr/share/internetblock/core.uc';
import * as fs from 'fs';
let policy = ARGV[1] == 'blocked' ? ['02:00:00:00:00:10'] : [];
let context = { lan_devices: ['ib-lan'], wan_devices: ['ib-wan'] };
if (ARGV[0] == 'fragment') print(core.fragment(policy));
else if (ARGV[0] == 'cleanup') print(core.cleanup(true, true, true, true));
else if (ARGV[0] == 'check') {
	let state = core.read_kernel(json(fs.readfile('/dev/stdin')));
	if (!core.kernel_matches(policy, state, context)) die('Kernel state does not match policy');
	print('verified\n');
}
else print(core.runtime(policy, context));
