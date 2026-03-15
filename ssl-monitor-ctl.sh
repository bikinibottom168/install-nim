#!/bin/bash
### ===============================
### SSL Monitor Control
### Usage: ssl-monitor-ctl {status|logs|stop|start|restart|domains}
### ===============================

SERVICE_NAME="ssl-monitor.service"
INSTALLED_DOMAINS_FILE="/etc/ssl-monitor/installed-domains.txt"
LOCK_FILE="/var/run/ssl-monitor.lock"

case "${1:-help}" in
  status)
    echo "=== SSL Monitor Status ==="
    if systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
      echo "✅ Service: RUNNING"
      PID="$(cat "$LOCK_FILE" 2>/dev/null || echo "N/A")"
      echo "   PID: $PID"
      UPTIME="$(systemctl show "$SERVICE_NAME" --property=ActiveEnterTimestamp 2>/dev/null | cut -d= -f2)"
      echo "   Started: $UPTIME"
    else
      echo "❌ Service: STOPPED"
    fi

    echo ""
    echo "=== Installed Domains ==="
    if [ -f "$INSTALLED_DOMAINS_FILE" ]; then
      COUNT="$(wc -l < "$INSTALLED_DOMAINS_FILE")"
      echo "   Total: $COUNT domain(s)"
      while IFS= read -r d; do
        echo "   • $d"
      done < "$INSTALLED_DOMAINS_FILE"
    else
      echo "   No domains installed yet"
    fi
    ;;

  logs)
    LINES="${2:-50}"
    echo "=== SSL Monitor Logs (last $LINES lines) ==="
    journalctl -u "$SERVICE_NAME" -n "$LINES" --no-pager
    ;;

  logs-follow)
    echo "=== SSL Monitor Logs (following) ==="
    journalctl -u "$SERVICE_NAME" -f
    ;;

  stop)
    echo "Stopping SSL Monitor..."
    systemctl stop "$SERVICE_NAME"
    echo "✅ Stopped"
    ;;

  start)
    echo "Starting SSL Monitor..."
    systemctl start "$SERVICE_NAME"
    echo "✅ Started"
    ;;

  restart)
    echo "Restarting SSL Monitor..."
    systemctl restart "$SERVICE_NAME"
    echo "✅ Restarted"
    ;;

  domains)
    if [ -f "$INSTALLED_DOMAINS_FILE" ]; then
      cat "$INSTALLED_DOMAINS_FILE"
    else
      echo "No domains installed yet"
    fi
    ;;

  help|*)
    echo "SSL Monitor Control"
    echo ""
    echo "Usage: ssl-monitor-ctl <command>"
    echo ""
    echo "Commands:"
    echo "  status      - Show service status and installed domains"
    echo "  logs [N]    - Show last N log lines (default: 50)"
    echo "  logs-follow - Follow logs in real-time"
    echo "  start       - Start the monitor service"
    echo "  stop        - Stop the monitor service"
    echo "  restart     - Restart the monitor service"
    echo "  domains     - List installed domains"
    echo "  help        - Show this help"
    ;;
esac
