#!/usr/bin/env bash
# Behavioral test for the connector bootstrap retry loop.
# Usage: test-bootstrap-retry.sh <path-to-emitted-bootstrap.sh>
# Stubs curl/dpkg/systemctl/sleep on PATH so no network or root is needed.
set -u

BOOTSTRAP="${1:?usage: test-bootstrap-retry.sh <bootstrap.sh>}"

run_scenario() {
  local fail_until="$1" expected_exit="$2" expected_count="$3" name="$4"
  local tmp bin count
  tmp="$(mktemp -d)"
  bin="$tmp/bin"; mkdir -p "$bin"
  count="$tmp/count"; echo 0 > "$count"

  # curl stub: count each install attempt, satisfy the "-o <file>" write.
  cat > "$bin/curl" <<EOF
#!/usr/bin/env bash
c=\$(cat "$count"); c=\$((c + 1)); echo \$c > "$count"
out=""
while [ \$# -gt 0 ]; do [ "\$1" = "-o" ] && out="\$2"; shift; done
[ -n "\$out" ] && echo 'exit 0' > "\$out"
exit 0
EOF

  # dpkg stub: report "installed" only once attempts reach fail_until.
  cat > "$bin/dpkg" <<EOF
#!/usr/bin/env bash
c=\$(cat "$count")
[ "\$c" -ge "$fail_until" ] && exit 0 || exit 1
EOF

  printf '#!/usr/bin/env bash\nexit 0\n' > "$bin/systemctl"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$bin/sleep"
  chmod +x "$bin"/*

  PATH="$bin:$PATH" bash "$BOOTSTRAP" >/dev/null 2>&1
  local actual_exit=$?
  local actual_count; actual_count="$(cat "$count")"

  if [ "$actual_exit" -eq "$expected_exit" ] && [ "$actual_count" -eq "$expected_count" ]; then
    echo "PASS: $name (exit=$actual_exit attempts=$actual_count)"
    rm -rf "$tmp"; return 0
  fi
  echo "FAIL: $name (exit=$actual_exit want $expected_exit; attempts=$actual_count want $expected_count)"
  rm -rf "$tmp"; return 1
}

rc=0
run_scenario 3  0 3 "recovers on 3rd attempt"      || rc=1
run_scenario 99 1 5 "gives up after max attempts"  || rc=1
run_scenario 1  0 1 "succeeds on first attempt"    || rc=1
exit $rc
