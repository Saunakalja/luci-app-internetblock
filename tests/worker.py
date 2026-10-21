#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 Saunakalja
"""Exercise collector termination with a real sleeping child in Linux/WSL."""
import os
from pathlib import Path
import signal
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix="internetblock-worker-") as directory:
    directory = Path(directory)
    marker = directory / "sleeper.pid"
    sleeper = directory / "sleep"
    sleeper.write_text(f'#!/bin/sh\necho $$ > "{marker}"\nexec /bin/sleep 60\n')
    sleeper.chmod(0o755)
    env = dict(os.environ, PATH=f'{directory}:{os.environ["PATH"]}')
    worker = subprocess.Popen(
        ["sh", str(ROOT / "root/usr/libexec/internetblock-worker")],
        env=env, start_new_session=True,
    )
    try:
        deadline = time.monotonic() + 3
        while not marker.exists() and worker.poll() is None and time.monotonic() < deadline:
            time.sleep(0.01)
        assert marker.exists(), "worker must reach its periodic wait"
        child = int(marker.read_text())
        worker.terminate()
        assert worker.wait(timeout=2) == 0, "TERM must stop the worker without SIGKILL"
        try:
            os.kill(child, 0)
        except ProcessLookupError:
            pass
        else:
            raise AssertionError("worker must reap its sleeping child")
        print("PASS: 3 worker lifecycle assertions")
    finally:
        try:
            os.killpg(worker.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        worker.wait()
