#!/bin/bash
set -uo pipefail

VM_IP="192.168.56.120"
PORT="8181"
PIDFILE="/tmp/gitlab_port_forward.pid"
LOGFILE="/tmp/gitlab_port_forward.log"

is_running() {
  [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null
}

print_url() {
  local url="http://${VM_IP}:${PORT}"
  printf '\e]8;;%s\e\\%s\e]8;;\e\\\n' "$url" "$url"
}

pause() {
  read -r -p $'\nPress Enter to continue...' _
}

activate() {
  if is_running; then
    echo "Port forwarding already active (PID $(cat "$PIDFILE"))."
    print_url
    pause
    return
  fi
  nohup vagrant ssh -c "kubectl -n gitlab port-forward --address 0.0.0.0 svc/gitlab-webservice-default ${PORT}:${PORT}" \
    > "$LOGFILE" 2>&1 &
  echo $! > "$PIDFILE"
  sleep 2
  if is_running; then
    echo "Port forwarding started."
    print_url
  else
    echo "Failed to start, check $LOGFILE"
    rm -f "$PIDFILE"
  fi
  pause
}

deactivate() {
  if is_running; then
    kill "$(cat "$PIDFILE")" 2>/dev/null
    rm -f "$PIDFILE"
    echo "Port forwarding stopped."
  else
    echo "Port forwarding is not running."
  fi
  pause
}

status() {
  if is_running; then
    echo "Active (PID $(cat "$PIDFILE"))."
    print_url
  else
    echo "Not running."
  fi
  pause
}

password() {
  vagrant ssh -c "kubectl get secret gitlab-gitlab-initial-root-password -n gitlab -o jsonpath='{.data.password}' | base64 -d"
  echo
  pause
}

show_url() {
  print_url
  pause
}

show_help() {
  cat <<EOF
Available commands (type the name or the number):
  1) activate    - start port forwarding in the background
  2) deactivate  - stop port forwarding
  3) status      - show whether port forwarding is running
  4) password    - print the GitLab root password
  5) url         - print the GitLab URL
  6) help        - show this help
  0) exit/quit   - quit this shell (port forwarding keeps running in the background)
EOF
  pause
}

show_menu() {
  clear
  echo "=== GitLab control shell ==="
  echo "1) activate    2) deactivate    3) status"
  echo "4) password    5) url           6) help"
  echo "0) exit"
  echo
}

while true; do
  show_menu
  read -r -p "gitlab> " cmd || { echo; echo "Bye."; break; }
  clear
  case "$cmd" in
    activate|1)     activate ;;
    deactivate|2)   deactivate ;;
    status|3)       status ;;
    password|4)     password ;;
    url|5)          show_url ;;
    help|6|"")      show_help ;;
    exit|quit|0)    echo "Bye."; break ;;
    *)              echo "Unknown command: $cmd (type 'help')"; pause ;;
  esac
done
clear