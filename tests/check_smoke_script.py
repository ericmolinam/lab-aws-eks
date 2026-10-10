"""Exercise command sequencing and error propagation with a fake kubectl."""
import os
import pathlib
import subprocess
import tempfile

root = pathlib.Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory() as d:
    tmp = pathlib.Path(d)
    stub = tmp / 'kubectl'
    stub.write_text('#!/bin/sh\nprintf "%s\\n" "$*" >> "$COMMAND_LOG"\nif [ "${FAIL_WAIT:-}" = 1 ] && [ "$1" = wait ]; then exit 1; fi\n')
    stub.chmod(0o755)
    log = tmp / 'commands'
    env = dict(os.environ, PATH=d + ':' + os.environ['PATH'], COMMAND_LOG=str(log))
    script = str(root / 'scripts/karpenter-smoke.sh')
    subprocess.run([script, 'up'], env=env, check=True)
    commands = log.read_text().splitlines()
    assert commands[0].startswith('wait --for=condition=Ready')
    assert '--replicas=2' in commands[2]
    assert '--timeout=600s' in commands[3]
    subprocess.run([script, 'down'], env=env, check=True)
    assert log.read_text().splitlines()[-1] == 'delete namespace karpenter-smoke --ignore-not-found --wait=true --timeout=180s'
    log.write_text('')
    result = subprocess.run([script, 'up'], env=dict(env, FAIL_WAIT='1'))
    assert result.returncode == 1
    assert len(log.read_text().splitlines()) == 1  # no apply after failed readiness
    result = subprocess.run([script, 'invalid'], env=env, capture_output=True)
    assert result.returncode == 2
print('PASS: smoke up/down sequencing, bounded replicas/timeouts, readiness failure aborts before mutations (mock only)')
