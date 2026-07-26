#!/usr/bin/env bash
# Measure how reliable a cold start actually is, and whether a warmup fixes it.
# Usage: ops/coldstart_probe.sh [N]
set -u
N="${1:-3}"
cd "$(dirname "$0")/.."
pass=0; recovered=0; failed=0

for i in $(seq 1 "$N"); do
  pkill -f "jac start" 2>/dev/null; sleep 2
  jac clean --all --force >/dev/null 2>&1; rm -rf .jac/data
  nohup jac start main.jac --no-client -p 8000 < /dev/null > "/tmp/coldstart-$i.log" 2>&1 &
  for _ in $(seq 1 60); do
    curl -s -m 2 -o /dev/null http://127.0.0.1:8000/healthz 2>/dev/null && break
    sleep 1
  done

  first=$(curl -s -m 10 -o /dev/null -w "%{http_code}" -X POST \
    http://127.0.0.1:8000/function/get_run_state -H 'Content-Type: application/json' -d '{}')

  # retry a few times to see whether it is transient or terminal
  after="$first"
  for _ in 1 2 3 4 5; do
    [ "$after" = "200" ] && break
    sleep 1
    after=$(curl -s -m 10 -o /dev/null -w "%{http_code}" -X POST \
      http://127.0.0.1:8000/function/get_run_state -H 'Content-Type: application/json' -d '{}')
  done

  if [ "$first" = "200" ]; then
    echo "run $i: first=$first                 -> CLEAN"; pass=$((pass+1))
  elif [ "$after" = "200" ]; then
    echo "run $i: first=$first after-retry=$after -> RECOVERED"; recovered=$((recovered+1))
  else
    echo "run $i: first=$first after-retry=$after -> TERMINAL (server bricked)"; failed=$((failed+1))
  fi
done

echo "----"
echo "clean=$pass recovered=$recovered terminal=$failed  of $N cold starts"
