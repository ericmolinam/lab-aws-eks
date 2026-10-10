"""Exercise command sequencing and error propagation with a fake kubectl."""
import os
import pathlib
import subprocess
import tempfile
import shutil
import time

root = pathlib.Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory() as d:
    tmp = pathlib.Path(d)
    stub = tmp / 'kubectl'
    stub.write_text('#!/bin/sh\nprintf "%s\\n" "$*" >> "$COMMAND_LOG"\nshift\nif [ "${FAIL_WAIT:-}" = 1 ] && [ "$1" = wait ]; then exit 1; fi\nif [ "${STALL:-}" = 1 ]; then exec sleep 10; fi\n')
    stub.chmod(0o755)
    timeout = tmp / 'timeout'
    real_timeout = shutil.which('timeout')
    assert real_timeout, 'GNU timeout is required'
    timeout.write_text('#!/bin/sh\nprintf "%s\\n" "$*" >> "$TIMEOUT_LOG"\n'
                       'kill=$1; duration=$2; shift 2\n'
                       'if [ "${STALL:-}" = 1 ]; then duration=0.1s; fi\n'
                       'exec "$REAL_TIMEOUT" "$kill" "$duration" "$@"\n')
    timeout.chmod(0o755)
    log = tmp / 'commands'
    timeout_log = tmp / 'timeouts'
    env = dict(os.environ, PATH=d + ':' + os.environ['PATH'], COMMAND_LOG=str(log),
               TIMEOUT_LOG=str(timeout_log), REAL_TIMEOUT=real_timeout)
    script = str(root / 'scripts/karpenter-smoke.sh')
    subprocess.run([script, 'up'], env=env, check=True)
    commands = log.read_text().splitlines()
    assert commands[0].startswith('--request-timeout=30s wait --for=condition=Ready')
    assert all(c.startswith('--request-timeout=30s ') for c in commands)
    assert '--replicas=2' in commands[2]
    assert '--timeout=600s' in commands[3]
    subprocess.run([script, 'down'], env=env, check=True)
    assert log.read_text().splitlines()[-1] == '--request-timeout=30s delete namespace karpenter-smoke --ignore-not-found --wait=true --timeout=180s'
    durations = [int(c.split()[1][:-1]) for c in timeout_log.read_text().splitlines()]
    assert durations == [210, 60, 60, 630, 60, 60, 60, 210]
    assert sum(durations[:-1]) + 5 * 7 < 1200
    log.write_text('')
    result = subprocess.run([script, 'up'], env=dict(env, FAIL_WAIT='1'))
    assert result.returncode == 1
    assert len(log.read_text().splitlines()) == 1  # no apply after failed readiness
    log.write_text('')
    start = time.monotonic()
    result = subprocess.run([script, 'up'], env=dict(env, STALL='1'), timeout=3)
    assert result.returncode == 124
    assert time.monotonic() - start < 3
    assert len(log.read_text().splitlines()) == 1  # hung readiness also aborts
    result = subprocess.run([script, 'invalid'], env=env, capture_output=True)
    assert result.returncode == 2
print('PASS: smoke up/down sequencing, bounded replicas/timeouts, readiness failure aborts before mutations (mock only)')
