#!/usr/bin/env bash
# One-command control for the whole poker stack.
#   ./scripts/poker.sh up        — start AWS instance, wait, start local demo
#   ./scripts/poker.sh stop      — stop AWS instance + kill local demo
#   ./scripts/poker.sh status    — health of everything
#   ./scripts/poker.sh logs      — tail demo + ssh into solver logs
#
# Requires:
#   - AWS CLI authenticated (`aws login` if expired)
#   - ~/.ssh/poker-solver.pem
#   - uv at ~/.local/bin/uv
#   - bd (the API key is in beads memory: `bd memories api-key`)

set -euo pipefail

INSTANCE_ID="i-03d26fefc88fbe756"
EIP="34.233.162.151"
DEMO_DIR="$(cd "$(dirname "$0")/.." && pwd)/demo"
DEMO_LOG="/tmp/demo-server.log"
SSH_KEY="$HOME/.ssh/poker-solver.pem"

api_key() {
  bd memories api-key 2>/dev/null | grep -oE '[A-Za-z0-9_-]{30,}' | head -1
}

start_aws() {
  echo "→ starting EC2 $INSTANCE_ID"
  aws ec2 start-instances --instance-ids "$INSTANCE_ID" >/dev/null
  aws ec2 wait instance-running --instance-ids "$INSTANCE_ID"
  echo "→ instance running. waiting for solver (≈90s — loads 35GB into RAM)"
  until curl -sf --max-time 3 "http://$EIP:8000/v1/health" >/dev/null 2>&1; do
    printf '.'
    sleep 8
  done
  echo
  curl -s "http://$EIP:8000/v1/health"; echo
}

start_demo() {
  pkill -9 -f "uvicorn server:app" 2>/dev/null || true
  sleep 1
  local key
  key="$(api_key)" || true
  [[ -z "$key" ]] && echo "WARN: SOLVER_API_KEY not found in bd memory" >&2
  cd "$DEMO_DIR"
  CUDA_VISIBLE_DEVICES= \
    SOLVER_URL="http://$EIP:8000" \
    SOLVER_API_KEY="$key" \
    nohup "$HOME/.local/bin/uv" run uvicorn server:app --host 0.0.0.0 --port 8080 \
    > "$DEMO_LOG" 2>&1 &
  disown
  echo "→ demo starting on http://localhost:8080  (log: $DEMO_LOG)"
  until curl -sf --max-time 3 http://localhost:8080/api/config >/dev/null 2>&1; do
    printf '.'
    sleep 3
  done
  echo
  curl -s http://localhost:8080/api/health; echo
  echo "✓ ready — open http://localhost:8080"
}

stop_aws() {
  echo "→ stopping EC2 $INSTANCE_ID (volume + EIP preserved)"
  aws ec2 stop-instances --instance-ids "$INSTANCE_ID" >/dev/null
  aws ec2 describe-instances --instance-ids "$INSTANCE_ID" \
    --query 'Reservations[0].Instances[0].State.Name' --output text
}

stop_demo() {
  pkill -9 -f "uvicorn server:app" 2>/dev/null || true
  echo "→ local demo stopped"
}

status() {
  echo "=== EC2 ==="
  aws ec2 describe-instances --instance-ids "$INSTANCE_ID" \
    --query 'Reservations[0].Instances[0].[InstanceId,InstanceType,State.Name,PublicIpAddress]' \
    --output text 2>&1 || echo "  AWS CLI failed — run 'aws login'"
  echo
  echo "=== solver ==="
  curl -sf --max-time 5 "http://$EIP:8000/v1/health" 2>&1 && echo || echo "  unreachable"
  echo "=== demo ==="
  curl -sf --max-time 3 http://localhost:8080/api/config 2>&1 && echo || echo "  not running"
}

logs() {
  echo "=== demo (last 30 lines) ==="
  tail -n 30 "$DEMO_LOG" 2>/dev/null || echo "  no log"
  echo
  echo "=== solver (via ssh, last 30 lines) ==="
  ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no -o ConnectTimeout=5 ubuntu@"$EIP" \
    'tail -n 30 /home/ubuntu/server.log' 2>/dev/null || echo "  ssh unreachable"
}

case "${1:-status}" in
  up|start)    start_aws; start_demo ;;
  stop|down)   stop_demo; stop_aws ;;
  status|s)    status ;;
  logs|log)    logs ;;
  *) echo "usage: $0 [up|stop|status|logs]" >&2; exit 1 ;;
esac
