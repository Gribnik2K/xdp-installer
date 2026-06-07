#!/usr/bin/env bash
# solana-status.sh
# Снэпшот состояния валидатора: сервис, XDP, голосование, ресурсы, сеть.
# Использование:
#   solana-status.sh              # один прогон
#   solana-status.sh watch        # обновляется каждые 30 сек
#   solana-status.sh watch 10     # обновляется каждые 10 сек

set -u

# ---------- config -----------------------------------------------------------
SERVICE_NAME="jito"
LEDGER_DIR="/root/solana/validator-ledger"
VOTE_ACCOUNT="/root/solana/vote-account-keypair.json"
IDENTITY="/root/solana/validator-keypair.json"
RPC_URL="https://api.testnet.solana.com"
XDP_CPU=16     # ядро XDP-воркера (из --experimental-retransmit-xdp-cpu-cores)
POH_CPU=0      # ядро PoH (из --experimental-poh-pinned-cpu-core)

# ---------- colors -----------------------------------------------------------
if [ -t 1 ]; then
    G=$'\033[32m'; R=$'\033[31m'; Y=$'\033[33m'; B=$'\033[34m'
    M=$'\033[35m'; C=$'\033[36m'; W=$'\033[37m'; D=$'\033[2m'; N=$'\033[0m'; BO=$'\033[1m'
else
    G=""; R=""; Y=""; B=""; M=""; C=""; W=""; D=""; N=""; BO=""
fi

# ---------- helpers ----------------------------------------------------------
hr()    { printf "${D}%s${N}\n" "────────────────────────────────────────────────────────────────────────"; }
hdr()   { echo; printf "${BO}${C}▌ %s${N}\n" "$1"; hr; }
kv()    { printf "  ${D}%-22s${N} %s\n" "$1" "$2"; }
ok()    { printf "${G}✔${N} %s\n" "$1"; }
warn()  { printf "${Y}⚠${N} %s\n" "$1"; }
bad()   { printf "${R}✘${N} %s\n" "$1"; }
info()  { printf "${B}ℹ${N} %s\n" "$1"; }

# Возвращает 0 если число $1 положительное (для bash-арифметики)
is_pos() { [[ "${1:-0}" =~ ^[0-9]+$ ]] && [ "${1:-0}" -gt 0 ]; }

# Безопасный sudo (если уже root — без sudo)
SUDO=""
[ "$EUID" -ne 0 ] && SUDO="sudo"

# ---------- show one snapshot ------------------------------------------------
snapshot() {
clear
printf "${BO}${M}═══════════════════════════════════════════════════════════════════════${N}\n"
printf "${BO}${M}  SOLANA VALIDATOR STATUS — $(hostname) — $(date '+%Y-%m-%d %H:%M:%S %Z')${N}\n"
printf "${BO}${M}═══════════════════════════════════════════════════════════════════════${N}\n"

# ============================================================ SERVICE
hdr "SERVICE"
if systemctl is-active --quiet "$SERVICE_NAME"; then
    ok "$SERVICE_NAME is ${G}active${N}"
    UPTIME=$(systemctl show -p ActiveEnterTimestamp --value "$SERVICE_NAME" 2>/dev/null)
    [ -n "$UPTIME" ] && kv "Started" "$UPTIME"
    PID=$(systemctl show -p MainPID --value "$SERVICE_NAME" 2>/dev/null)
    kv "Main PID" "$PID"
    RESTARTS=$(systemctl show -p NRestarts --value "$SERVICE_NAME" 2>/dev/null)
    if is_pos "$RESTARTS"; then
        warn "Restarts since boot: ${Y}${RESTARTS}${N}"
    else
        kv "Restarts" "0"
    fi
else
    bad "$SERVICE_NAME is NOT active"
    return
fi

# ============================================================ XDP
hdr "XDP"
if [ -n "${PID:-}" ] && [ -d "/proc/$PID" ]; then
    # Capabilities главного процесса
    CAP_EFF=$(grep -i "^CapEff:" /proc/$PID/status 2>/dev/null | awk '{print $2}')
    CAP_BND=$(grep -i "^CapBnd:" /proc/$PID/status 2>/dev/null | awk '{print $2}')
    USER_RUN=$(ps -o user= -p $PID 2>/dev/null | tr -d ' ')
    kv "Run as" "$USER_RUN"
    kv "CapEff" "$CAP_EFF"
    kv "CapBnd" "$CAP_BND"
    if [ "$USER_RUN" = "root" ]; then
        info "User=root: caps выглядят пустыми, но root имеет все права неявно"
    fi
fi

# Активность XDP в логах за последние 5 минут
XDP_EVENTS=$(journalctl -u "$SERVICE_NAME" --since "5 minutes ago" 2>/dev/null \
    | grep -c "agave_xdp")
# ВАЖНО: исключаем строки где error/fail встречается только как часть "error_events=0" и т.п.
# Реальная ошибка XDP — это уровень логов ERROR/WARN, или ненулевой счётчик error_events
XDP_ERRORS=$(journalctl -u "$SERVICE_NAME" --since "5 minutes ago" 2>/dev/null \
    | grep -i "agave_xdp" \
    | grep -vE "error_events=0" \
    | grep -ciE "^[^]]*ERROR|^[^]]*WARN|error_events=[1-9]|panic|failed")

if is_pos "$XDP_EVENTS"; then
    ok "XDP active: $XDP_EVENTS events in last 5 min"
else
    warn "No XDP events in last 5 min (might be normal if quiet period)"
fi

if is_pos "$XDP_ERRORS"; then
    bad "XDP errors detected: $XDP_ERRORS in last 5 min"
    journalctl -u "$SERVICE_NAME" --since "5 minutes ago" 2>/dev/null \
        | grep -i "agave_xdp" | grep -vE "error_events=0" \
        | grep -iE "ERROR|WARN|error_events=[1-9]|panic|failed" | tail -3 \
        | sed "s/^/    ${R}│${N} /"
else
    ok "No XDP errors in last 5 min"
fi

# ============================================================ CPU
hdr "CPU LOAD (XDP=core${XDP_CPU}, PoH=core${POH_CPU})"
if command -v mpstat &>/dev/null; then
    # одна секунда замера — быстро
    mpstat -P "$POH_CPU,$XDP_CPU" 1 1 2>/dev/null | awk -v poh="$POH_CPU" -v xdp="$XDP_CPU" '
        /^Average/ && $2 ~ /^[0-9]+$/ {
            core=$2; user=$3; sys=$5; idle=$NF
            busy=100-idle
            label = (core==poh) ? "PoH" : (core==xdp) ? "XDP" : "  "
            printf "  %-4s core %-3s  usr=%5.1f%% sys=%5.1f%% idle=%5.1f%%  busy=%5.1f%%\n",
                   label, core, user, sys, idle, busy
        }'
else
    warn "mpstat not installed (apt install sysstat)"
fi

# Общая нагрузка
LOAD=$(awk '{print $1, $2, $3}' /proc/loadavg)
NCPU=$(nproc)
kv "Load avg (1/5/15m)" "$LOAD  ${D}(${NCPU} cores)${N}"

# ============================================================ MEMORY
hdr "MEMORY"
free -h | awk 'NR==2 {printf "  %-22s used=%s / total=%s (avail=%s)\n", "RAM", $3, $2, $7}'
free -h | awk 'NR==3 {printf "  %-22s used=%s / total=%s\n", "Swap", $3, $2}'

# /dev/shm — у тебя там accounts + snapshots
if df -h /dev/shm &>/dev/null; then
    SHM=$(df -h /dev/shm | awk 'NR==2 {printf "used=%s / total=%s (%s)", $3, $2, $5}')
    SHM_PCT=$(df /dev/shm | awk 'NR==2 {print $5}' | tr -d '%')
    if [ "${SHM_PCT:-0}" -ge 90 ]; then
        bad "/dev/shm: $SHM"
    elif [ "${SHM_PCT:-0}" -ge 75 ]; then
        warn "/dev/shm: $SHM"
    else
        kv "/dev/shm" "$SHM"
    fi
fi

# ============================================================ DISK
hdr "DISK (ledger)"
if [ -d "$LEDGER_DIR" ]; then
    LDISK=$(df -h "$LEDGER_DIR" | awk 'NR==2 {printf "used=%s / total=%s (%s)", $3, $2, $5}')
    kv "Ledger volume" "$LDISK"
    LSIZE=$(du -sh "$LEDGER_DIR" 2>/dev/null | awk '{print $1}')
    kv "Ledger size" "$LSIZE"
fi

# ============================================================ NETWORK
hdr "NETWORK"
# Главный uplink — берём дефолтный интерфейс
DEFIFACE=$(ip route show default 2>/dev/null | awk '/default/ {print $5; exit}')
if [ -n "$DEFIFACE" ]; then
    kv "Default iface" "$DEFIFACE"
    # текущие байтовые счётчики и pps приблизительно
    RX1=$(cat /sys/class/net/$DEFIFACE/statistics/rx_bytes)
    TX1=$(cat /sys/class/net/$DEFIFACE/statistics/tx_bytes)
    RXP1=$(cat /sys/class/net/$DEFIFACE/statistics/rx_packets)
    TXP1=$(cat /sys/class/net/$DEFIFACE/statistics/tx_packets)
    sleep 1
    RX2=$(cat /sys/class/net/$DEFIFACE/statistics/rx_bytes)
    TX2=$(cat /sys/class/net/$DEFIFACE/statistics/tx_bytes)
    RXP2=$(cat /sys/class/net/$DEFIFACE/statistics/rx_packets)
    TXP2=$(cat /sys/class/net/$DEFIFACE/statistics/tx_packets)
    RX_MBPS=$(awk "BEGIN {printf \"%.1f\", ($RX2-$RX1)*8/1000000}")
    TX_MBPS=$(awk "BEGIN {printf \"%.1f\", ($TX2-$TX1)*8/1000000}")
    RX_PPS=$((RXP2-RXP1))
    TX_PPS=$((TXP2-TXP1))
    printf "  %-22s ${G}↓${N} %6s Mbps  %6s pps\n" "RX" "$RX_MBPS" "$RX_PPS"
    printf "  %-22s ${R}↑${N} %6s Mbps  %6s pps\n" "TX" "$TX_MBPS" "$TX_PPS"
    DROP_RX=$(cat /sys/class/net/$DEFIFACE/statistics/rx_dropped)
    DROP_TX=$(cat /sys/class/net/$DEFIFACE/statistics/tx_dropped)
    ERR_RX=$(cat /sys/class/net/$DEFIFACE/statistics/rx_errors)
    ERR_TX=$(cat /sys/class/net/$DEFIFACE/statistics/tx_errors)
    if is_pos "$DROP_RX" || is_pos "$DROP_TX" || is_pos "$ERR_RX" || is_pos "$ERR_TX"; then
        warn "drops/errors: rx_drop=$DROP_RX tx_drop=$DROP_TX rx_err=$ERR_RX tx_err=$ERR_TX"
    else
        ok "no drops or errors"
    fi
fi

# ============================================================ VALIDATOR (RPC)
hdr "VALIDATOR (via local RPC)"
if command -v agave-validator &>/dev/null; then
    # contact-info — лёгкий запрос
    CINFO=$(timeout 5 agave-validator --ledger "$LEDGER_DIR" contact-info 2>/dev/null \
        | awk -F':' '{
            if ($1 ~ /Identity/)        ident=$2;
            if ($1 ~ /^Version/)        ver=$2;
            if ($1 ~ /Shred Version/)   shred=$2;
            if ($1 ~ /Gossip/)          gossip=$2":"$3;
        }
        END { printf "%s|%s|%s|%s", ident, ver, shred, gossip }')
    IFS='|' read -r IDENT VER SHRED GOSSIP <<<"$CINFO"
    [ -n "$IDENT" ]  && kv "Identity" "$(echo $IDENT | tr -d ' ')"
    [ -n "$VER" ]    && kv "Version"  "$(echo $VER | tr -d ' ')"
    [ -n "$SHRED" ]  && kv "Shred ver" "$(echo $SHRED | tr -d ' ')"
fi

# ============================================================ VOTING
hdr "VOTING (via $RPC_URL — public RPC, may lag)"
if command -v solana &>/dev/null && [ -f "$VOTE_ACCOUNT" ]; then
    VOTE_PUB=$(solana-keygen pubkey "$VOTE_ACCOUNT" 2>/dev/null)
    if [ -n "$VOTE_PUB" ]; then
        kv "Vote account" "$VOTE_PUB"
        # vote-account показывает credits и последний голос
        VA=$(timeout 10 solana --url "$RPC_URL" vote-account "$VOTE_PUB" 2>/dev/null)
        if [ -n "$VA" ]; then
            COMM=$(echo "$VA" | grep -i "Commission:" | head -1 | awk '{print $2}')
            ROOT=$(echo "$VA" | grep -i "Root Slot:" | head -1 | awk '{print $3}')
            CRED=$(echo "$VA" | grep -i "Credits:" | head -1 | awk '{print $2}')
            ACT=$(echo "$VA" | grep -i "Active Stake:" | head -1 | awk '{print $3, $4}')
            [ -n "$COMM" ] && kv "Commission" "$COMM"
            [ -n "$ACT" ]  && kv "Active Stake" "$ACT"
            [ -n "$ROOT" ] && kv "Root Slot" "$ROOT"
            [ -n "$CRED" ] && kv "Credits (cur)" "$CRED"

            # Последние 3 эпохи credits — на просадку посмотреть
            echo "  ${D}Last epochs (credits earned / max possible):${N}"
            echo "$VA" | awk '/Epoch Voting History/,/^$/' | grep -E "^\s+[0-9]+:" | tail -4 \
                | sed "s/^/    /"
        else
            warn "public RPC timeout or error"
        fi
    fi
fi

# Delinquent check
if command -v solana &>/dev/null && [ -n "${IDENT:-}" ]; then
    IDENT_CLEAN=$(echo "$IDENT" | tr -d ' ')
    # solana validators в обычном выводе ставит '⚠' напротив delinquent
    # Берём только нашу строку (по identity), проверяем есть ли там маркер delinquent
    DLQ_LINE=$(timeout 10 solana --url "$RPC_URL" validators 2>/dev/null \
        | grep "$IDENT_CLEAN" | head -1)
    if [ -z "$DLQ_LINE" ]; then
        warn "Identity $IDENT_CLEAN не найден в выводе 'solana validators' (новая нода?)"
    elif echo "$DLQ_LINE" | grep -qE "^\s*⚠|delinquent"; then
        bad "${BO}WE ARE DELINQUENT${N}"
        echo "    ${R}│${N} $DLQ_LINE"
    else
        ok "We are NOT delinquent"
    fi
fi

# ============================================================ BAM / RELAYER
hdr "JITO BAM & RELAYER"
# Challenge expired — главный симптом высокой латентности до BAM-ноды
BAM_EXPIRED=$(journalctl -u "$SERVICE_NAME" --since "10 minutes ago" 2>/dev/null \
    | grep -c "Challenge expired")
# Извлекаем последнюю задержку для понимания насколько плохо
BAM_LAST_LAT=$(journalctl -u "$SERVICE_NAME" --since "10 minutes ago" 2>/dev/null \
    | grep "Challenge expired" | tail -1 \
    | grep -oE "elapsed since creation: [0-9.]+(ns|µs|ms|s)" | tail -1)
RELAYER_ERR=$(journalctl -u "$SERVICE_NAME" --since "10 minutes ago" 2>/dev/null \
    | grep -c "relayer_stage-proxy_error")
BLOCK_ENGINE_ERR=$(journalctl -u "$SERVICE_NAME" --since "10 minutes ago" 2>/dev/null \
    | grep -ciE "block_engine.*error|bam_connection.*ERROR")

if is_pos "$BAM_EXPIRED"; then
    bad "BAM: $BAM_EXPIRED 'Challenge expired' events in 10 min — высокая latency до BAM-ноды"
    [ -n "$BAM_LAST_LAT" ] && info "  Last delay: $BAM_LAST_LAT (limit: 30ms)"
    info "  → Проверь сетевую близость до ny.testnet.bam.jito.wtf"
    info "  → ping ny.testnet.bam.jito.wtf; mtr -rwn ny.testnet.bam.jito.wtf"
else
    ok "BAM: no challenge-expired events"
fi

if is_pos "$RELAYER_ERR"; then
    warn "Relayer: $RELAYER_ERR proxy errors in 10 min"
fi
if is_pos "$BLOCK_ENGINE_ERR"; then
    warn "Block Engine: $BLOCK_ENGINE_ERR connection errors in 10 min"
fi

# ============================================================ RECENT LOGS
hdr "RECENT ERRORS (last 10 min)"
# Считаем по УРОВНЯМ ЛОГА (ERROR/WARN/PANIC/FATAL — слова в квадратных скобках логгера),
# а не по любому вхождению слова "error" — иначе ловим строки вида "error_events=0"
RECENT_ERR=$(journalctl -u "$SERVICE_NAME" --since "10 minutes ago" 2>/dev/null \
    | grep -cE "\b(ERROR|PANIC|FATAL)\b" )
RECENT_WARN=$(journalctl -u "$SERVICE_NAME" --since "10 minutes ago" 2>/dev/null \
    | grep -cE "\bWARN\b" )
kv "Errors (ERROR/PANIC/FATAL)" "$RECENT_ERR"
kv "Warnings (WARN)" "$RECENT_WARN"
if is_pos "$RECENT_ERR"; then
    echo "  ${D}Last 3 errors (ERROR-level only):${N}"
    journalctl -u "$SERVICE_NAME" --since "10 minutes ago" 2>/dev/null \
        | grep -E "\b(ERROR|PANIC|FATAL)\b" | tail -3 \
        | cut -c1-200 \
        | sed "s/^/    ${R}│${N} /"
fi

echo
}

# ---------- main -------------------------------------------------------------
MODE="${1:-once}"
INTERVAL="${2:-30}"

case "$MODE" in
    watch)
        while true; do
            snapshot
            printf "${D}Refreshing every ${INTERVAL}s — Ctrl-C to exit${N}\n"
            sleep "$INTERVAL"
        done
        ;;
    once|"")
        snapshot
        ;;
    *)
        echo "Usage: $0 [once|watch] [interval_sec]"
        exit 1
        ;;
esac
