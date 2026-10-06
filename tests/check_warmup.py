"""Run with python3 tests/check_warmup.py; no AI requests or real credentials."""
import os
from pathlib import Path
import subprocess
import tempfile
import shlex
from datetime import datetime, timezone, timedelta

repo = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory() as directory:
    root = Path(directory)
    settings = root / "settings.env"
    marker = root / "should-not-exist"
    settings.write_text(f'''FIRST="spaces = #literal"
SECOND='single quoted value'
THIRD=$(touch {marker})
EMPTY=
LAST=without newline''')
    result = subprocess.run(
        ["bash", "-c", 'source "$1"; load_config "$2"; printf "%s\\0" "$FIRST" "$SECOND" "$THIRD" "$EMPTY" "$LAST"',
         "check", str(repo / "bin/config.sh"), str(settings)], capture_output=True, check=True,
    )
    assert result.stdout.split(b"\0")[:-1] == [b"spaces = #literal", b"single quoted value",
                                               f"$(touch {marker})".encode(), b"", b"without newline"]
    assert not marker.exists()
    profiles = root / "accounts"
    profiles.mkdir(mode=0o700)
    calls = root / "calls"
    failure = root / "fail"
    failure.touch()
    entry = root / "custom-entry"
    entry.write_text('''#!/usr/bin/env bash
set -euo pipefail
[[ "$1" == exec && "$TEST_VALUE" == sample-profile-value ]]
[[ "$TEST_LABEL" == "$WARMUP_ACCOUNT" ]]
if [[ -n "${TEST_ARGS_CAPTURE:-}" ]]; then printf '%s\\0' "$@" > "$TEST_ARGS_CAPTURE"; fi
printf '%s\\n' "$WARMUP_ACCOUNT" >> "$TEST_CALLS"
[[ "$WARMUP_ACCOUNT" != user-b || ! -f "$TEST_FAILURE" ]]
''')
    entry.chmod(0o700)
    for account in ("user-a", "user-b"):
        variables = profiles / (account + ".vars")
        variables.write_text(f"TEST_LABEL={account}\nTEST_VALUE=sample-profile-value\n")
        (profiles / (account + ".env")).write_text(f"CODEX_ENV_FILE={variables}\n")
    config = root / "config.env"
    config.write_text((repo / "config/default.env").read_text() + f'''
WARMUP_ACCOUNTS=user-a,user-b
WARMUP_ACCOUNT_CONFIG_DIR={profiles}
WARMUP_LOCAL_CONFIG_PATH={root}/no-local.env
WARMUP_LOG_PATH={root}/warmup.log
WARMUP_STATE_PATH={root}/warmup.state
CODEX_PATH={entry}
CODEX_CREDENTIAL_PATH=
''')
    environment = dict(os.environ, TEST_CALLS=str(calls), TEST_FAILURE=str(failure))

    def run(hour, minute=0, day=1):
        # Hong Kong 08:00 = UTC 00:00.
        epoch = int(datetime(2030, 1, day, hour - 8, minute,
                             tzinfo=timezone.utc).timestamp())
        result = subprocess.run(
            ["bash", str(repo / "bin/daily-warmup.sh"), str(config)],
            env=dict(environment, WARMUP_NOW_EPOCH=str(epoch)),
            capture_output=True, text=True,
        )
        return result.returncode

    assert run(8) == 1
    assert calls.read_text().splitlines() == ["user-a", "user-b"]
    assert (root / "warmup.state.user-a").exists()
    assert not (root / "warmup.state.user-b").exists()
    failure.unlink()
    assert run(8, 10) == 0
    assert calls.read_text().splitlines() == ["user-a", "user-b", "user-b"]
    assert run(8, 20) == 0
    assert run(13) == 0  # 300 minutes is still inside the 302-minute interval.
    assert len(calls.read_text().splitlines()) == 3
    assert run(13, 2) == 0
    assert calls.read_text().splitlines()[-1] == "user-a"
    assert run(13, 12) == 0
    assert calls.read_text().splitlines()[-1] == "user-b"

    (profiles / "user-b.env").unlink()
    assert run(18, 30) == 1
    with config.open("a") as handle:
        handle.write("WARMUP_ACCOUNTS=../invalid\n")
    assert run(18, 40) == 1
    with config.open("a") as handle:
        handle.write("WARMUP_ACCOUNTS=user-a\nCODEX_PATH=/missing-command\n")
    previous_state = (root / "warmup.state.user-a").read_text()
    assert run(8, day=2) == 1
    assert (root / "warmup.state.user-a").read_text() == previous_state
    with config.open("a") as handle:
        handle.write(f"CODEX_PATH={entry}\nCODEX_ENV_FILE=/missing-env\n")
    with (profiles / "user-a.env").open("a") as handle:
        handle.write("CODEX_ENV_FILE=/missing-env\n")
    assert run(8, day=2) == 1
    assert (root / "warmup.state.user-a").read_text() == previous_state
    with (profiles / "user-a.env").open("a") as handle:
        handle.write(f"CODEX_ENV_FILE={profiles}/user-a.vars\n")
    with (profiles / "user-a.env").open("a") as handle:
        handle.write("WARMUP_HOURS=9,15,21\n")
    previous_calls = calls.read_text()
    assert run(8, day=3) == 0
    assert calls.read_text() == previous_calls
    assert run(9, day=3) == 0
    assert calls.read_text().splitlines()[-1] == "user-a"

    with config.open("a") as handle:
        handle.write("CODEX_ARGS=exec *\n")
    environment["TEST_ARGS_CAPTURE"] = str(root / "arguments")
    assert run(9, day=4) == 0
    assert (root / "arguments").read_bytes().split(b"\0")[:-1] == [
        b"exec", b"*", b"Warmup. Don't think, just reply: OK"]

    # Run the real schedule/state functions for two days, replacing only AI calls.
    for account, hours in [("user-a", "8,13,18,23"), ("user-b", "10,15,20")]:
        (profiles / (account + ".env")).write_text(f"WARMUP_HOURS={hours}\n")
    with config.open("a") as handle:
        handle.write(f"WARMUP_ACCOUNTS=user-a,user-b\nWARMUP_STATE_PATH={root}/simulation.state\n")
    start = int(datetime(2030, 1, 1, tzinfo=timezone(timedelta(hours=8))).timestamp())
    source = "source " + shlex.quote(str(repo / "bin/daily-warmup.sh")) + "\n"
    simulation = source + f'''
append_warmup_log() {{ :; }}
run_codex() {{ printf '%s %s\\n' "$WARMUP_ACCOUNT" "$WARMUP_NOW_EPOCH" >> "{root}/simulation.calls"; }}
for ((tick=0; tick<288; tick++)); do
  WARMUP_NOW_EPOCH=$(({start} + tick * 600))
  run_accounts || exit 1
done
'''
    result = subprocess.run(["bash", "-c", simulation, "check", str(config)],
                            env=environment, capture_output=True, text=True)
    assert result.returncode == 0, result.stderr
    observed = [(account, datetime.fromtimestamp(int(epoch), timezone(timedelta(hours=8))).strftime("%d %H:%M"))
                for account, epoch in (line.split() for line in (root / "simulation.calls").read_text().splitlines())]
    expected = [(account, f"{day:02} {clock}") for day in (1, 2) for account, clock in [
        ("user-a", "08:00"), ("user-b", "10:00"), ("user-a", "13:10"),
        ("user-b", "15:10"), ("user-a", "18:20"), ("user-b", "20:20"), ("user-a", "23:30")]]
    assert observed == expected, observed

    checks = source + f'''
WARMUP_HOURS=23
WARMUP_NOW_EPOCH=$(({start} + 23 * 3600 + 59 * 60))
[[ "$(current_schedule_slot)" == 2030-01-01-23 ]] || exit 1
WARMUP_NOW_EPOCH=$(({start} + 24 * 3600))
! current_schedule_slot || exit 1
WARMUP_SLOT_CATCHUP_MINUTES=120
[[ "$(current_schedule_slot)" == 2030-01-01-23 ]] || exit 1
WARMUP_HOURS=08,13
validate_schedule || exit 1
WARMUP_MIN_WINDOW_MINUTES='302 # invalid inline comment'
! validate_schedule || exit 1
WARMUP_MIN_WINDOW_MINUTES=302
WARMUP_HOURS=25
! validate_schedule || exit 1
WARMUP_HOURS=8
WARMUP_STATE_PATH=/dev/null/state
! record_schedule_trigger 2030-01-01-08 || exit 1
WARMUP_STATE_PATH='{root}/late.state'
WARMUP_HOURS=8,13,18,23
WARMUP_SLOT_CATCHUP_MINUTES=60
WARMUP_NOW_EPOCH=$(({start} + 8 * 3600 + 50 * 60))
record_schedule_trigger 2030-01-01-08 || exit 1
WARMUP_NOW_EPOCH=$(({start} + 13 * 3600 + 50 * 60))
! schedule_matches && [[ "$SCHEDULE_SKIP_REASON" == previous_window ]] || exit 1
WARMUP_NOW_EPOCH=$(({start} + 14 * 3600))
! schedule_matches && [[ "$SCHEDULE_SKIP_REASON" == outside_schedule ]] || exit 1
'''
    result = subprocess.run(["bash", "-c", checks, "check", str(config)],
                            env=environment, capture_output=True, text=True)
    assert result.returncode == 0, result.stderr
    print("Two-day simulation:", observed[:7])

    # Install into a temporary home with a fake systemctl; exercise local overrides.
    install_repo = root / "install"
    for folder in ("bin", "config", "local", "fake-bin", "home"):
        (install_repo / folder).mkdir(parents=True)
    for filename in ("config.sh", "install-scheduler.sh"):
        (install_repo / "bin" / filename).write_text((repo / "bin" / filename).read_text())
    (install_repo / "bin/daily-warmup.sh").touch()
    (install_repo / "config/default.env").write_text("WARMUP_SCHEDULER_INTERVAL_MINUTES=10\n")
    (install_repo / "local/local.env").write_text("WARMUP_SCHEDULER_INTERVAL_MINUTES=20\n")
    stubs = {
        "getent": f"printf 'test:x:1000:1000::%s:/bin/bash\\n' '{install_repo}/home'",
        "systemctl": "exit 0",
        "uname": "echo Linux",
    }
    for name, command in stubs.items():
        stub = install_repo / "fake-bin" / name
        stub.write_text("#!/bin/sh\n" + command + "\n")
        stub.chmod(0o700)
    install_env = dict(os.environ, PATH=str(install_repo / "fake-bin") + ":" + os.environ["PATH"])
    install_env.pop("WARMUP_LOCAL_CONFIG_PATH", None)
    install_env.pop("TASK_NAME", None)
    result = subprocess.run(["bash", str(install_repo / "bin/install-scheduler.sh")],
                            env=install_env, capture_output=True, text=True)
    assert result.returncode == 0, result.stderr
    timer = install_repo / "home/.config/systemd/user/ai-daily-warmup.timer"
    assert "OnCalendar=*:0/20" in timer.read_text()
print("OK: account isolation, retries, 302-minute interval, custom entry, environment isolation, validation")
