#!/bin/bash

PIDFILE="/tmp/openvpn.pid"
LOGFILE="/tmp/openvpn.log"

if [ -f "$PIDFILE" ] || sudo test -f "$PIDFILE" 2>/dev/null; then
    PID=$(sudo cat "$PIDFILE" 2>/dev/null || cat "$PIDFILE")
    if sudo kill -0 "$PID" 2>/dev/null; then
        echo "Відключення VPN (PID $PID)..."
        sudo kill "$PID"
        for _ in $(seq 1 10); do
            sleep 1
            sudo kill -0 "$PID" 2>/dev/null || break
        done
        sudo rm -f "$PIDFILE"
        echo "VPN відключено."
    else
        echo "Процес $PID вже не існує."
        sudo rm -f "$PIDFILE"
    fi
else
    # Fallback — шукаємо по імені
    if pgrep -x openvpn > /dev/null; then
        echo "PID-файл не знайдено, але openvpn запущено. Зупиняю..."
        sudo pkill -x openvpn
        echo "VPN відключено."
    else
        echo "VPN не запущено."
    fi
fi

# Очистити логи
sudo rm -f "$LOGFILE"
