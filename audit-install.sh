#!/usr/bin/env bash
# audit-install.sh
# Устанавливает solana-status и solana-audit в /usr/local/sbin/
# Запускать на каждой ноде один раз (или после обновлений этого скрипта).
#
# После установки доступны команды из любого места:
#   solana-status            — dashboard, один снэпшот
#   solana-status watch      — обновляется каждые 30 сек
#   solana-status watch 10   — каждые 10 сек
#   solana-audit             — полный аудит против Anza canon

set -u
G=$'\033[32m'; R=$'\033[31m'; C=$'\033[36m'; D=$'\033[2m'; N=$'\033[0m'; BO=$'\033[1m'

[ "$EUID" -eq 0 ] || { printf "${R}Запускай под root${N}\n"; exit 1; }

echo
echo "##########################################################################"
echo "########## OUTPUT BELOW — copy from here when pasting back ###############"
echo "##########################################################################"
echo

# ============================================================================
# solana-status
# ============================================================================
cat > /usr/local/sbin/solana-status <<'STATUSEOF'
#!/usr/bin/env bash
# solana-status — dashboard валидатора Jito-Solana
# Usage: solana-status [once|watch] [interval_sec]

set -u

UNIT=/etc/systemd/system/jito.service
LEDGER_DIR=$(grep -oE -- "--ledger [^ ]+" "$UNIT" 2>/dev/null | head -1 | awk '{print $2}')
[ -z "$LEDGER_DIR" ] && LEDGER_DIR="/root/solana/validator-ledger"
VOTE_ACCOUNT=$(grep -oE -- "--vote-account [^ ]+" "$UNIT" 2>/dev/null | head -1 | awk '{print $2}')

# Кластер: solana config → unit-файл → unknown
CLUSTER="unknown"
RPC_URL=""
if command -v solana &>/dev/null; then
    CFG_RPC=$(solana config get 2>/dev/null | awk -F': ' '/^RPC URL/ {print $2}' | tr -d ' \r\n')
    case "$CFG_RPC" in
        *testnet*)        CLUSTER="testnet";      RPC_URL="$CFG_RPC" ;;
        *mainnet-beta*)   CLUSTER="mainnet-beta"; RPC_URL="$CFG_RPC" ;;
        *devnet*)         CLUSTER="devnet";       RPC_URL="$CFG_RPC" ;;
    esac
fi
if [ "$CLUSTER" = "unknown" ]; then
    if   grep -q "entrypoint.testnet"      "$UNIT" 2>/dev/null; then CLUSTER="testnet";      RPC_URL="https://api.testnet.solana.com"
    elif grep -q "entrypoint.mainnet-beta" "$UNIT" 2>/dev/null; then CLUSTER="mainnet-beta"; RPC_URL="https://api.mainnet-beta.solana.com"
    elif grep -q "entrypoint.devnet"       "$UNIT" 2>/dev/null; then CLUSTER="devnet";       RPC_URL="https://api.devnet.solana.com"
    fi
fi

XDP_CPU=$(grep -oE -- "--experimental-retransmit-xdp-cpu-cores [0-9]+" "$UNIT" 2>/dev/null | awk '{print $2}')
POH_CPU=$(grep -oE -- "--experimental-poh-pinned-cpu-core [0-9]+" "$UNIT" 2>/dev/null | awk '{print $2}')
XDP_CPU=${XDP_CPU:-16}; POH_CPU=${POH_CPU:-0}

DEFIFACE=$(ip route show default 2>/dev/null | awk '{print $5; exit}')

if [ -t 1 ]; then
    G=$'\033[32m'; R=$'\033[31m'; Y=$'\033[33m'; B=$'\033[34m'
    M=$'\033[35m'; C=$'\033[36m'; D=$'\033[2m'; N=$'\033[0m'; BO=$'\033[1m'
else G=""; R=""; Y=""; B=""; M=""; C=""; D=""; N=""; BO=""; fi

hr()    { printf "${D}%s${N}\n" "────────────────────────────────────────────────────────────────────────"; }
hdr()   { echo; printf "${BO}${C}▌ %s${N}\n" "$1"; hr; }
kv()    { printf "  ${D}%-22s${N} %s\n" "$1" "$2"; }
ok()    { printf "${G}✔${N} %s\n" "$1"; }
warn()  { printf "${Y}⚠${N} %s\n" "$1"; }
bad()   { printf "${R}✘${N} %s\n" "$1"; }
info()  { printf "${B}ℹ${N} %s\n" "$1"; }
is_pos() { [[ "${1:-0}" =~ ^[0-9]+$ ]] && [ "${1:-0}" -gt 0 ]; }

snapshot() {
clear
printf "${BO}${M}═══════════════════════════════════════════════════════════════════════${N}\n"
printf "${BO}${M}  SOLANA VALIDATOR STATUS — $(hostname) [%s] — $(date '+%Y-%m-%d %H:%M:%S %Z')${N}\n" "$CLUSTER"
printf "${BO}${M}═══════════════════════════════════════════════════════════════════════${N}\n"

hdr "SERVICE"
if systemctl is-active --quiet jito; then
    ok "jito ${G}active${N}"
    UPTIME=$(systemctl show -p ActiveEnterTimestamp --value jito)
    [ -n "$UPTIME" ] && kv "Started" "$UPTIME"
    PID=$(systemctl show -p MainPID --value jito)
    kv "Main PID" "$PID"
    RESTARTS=$(systemctl show -p NRestarts --value jito)
    if is_pos "$RESTARTS"; then warn "Restarts since boot: $RESTARTS"; else kv "Restarts" "0"; fi
else
    bad "jito NOT active"; return
fi

hdr "XDP"
if [ -n "${PID:-}" ] && [ -d "/proc/$PID" ]; then
    USER_RUN=$(ps -o user= -p $PID 2>/dev/null | tr -d ' ')
    kv "Run as" "$USER_RUN"
fi
START_TS=$(systemctl show -p ActiveEnterTimestamp --value jito)
XDP_LOOP=$(journalctl -u jito --since="$START_TS" 2>/dev/null | grep -c "starting xdp loop")
XDP_REAL_ERR=$(journalctl -u jito --since="$START_TS" 2>/dev/null \
    | grep "agave_xdp" | grep -vE "error_events=0" \
    | grep -ciE "\b(ERROR|WARN|PANIC|FATAL)\b|error_events=[1-9]")
RETRANSMIT=$(journalctl -u jito --since "5 minutes ago" 2>/dev/null | grep -c "retransmit-first-shred")
if [ "$XDP_LOOP" -gt 0 ]; then
    ok "XDP loop started (since service start)"
else
    warn "XDP loop not seen — check unit flags or version"
fi
kv "retransmit-first-shred (5m)" "$RETRANSMIT"
[ "$XDP_REAL_ERR" -gt 0 ] && bad "XDP real errors: $XDP_REAL_ERR" || ok "No XDP errors"
HP_T=$(awk '/HugePages_Total/ {print $2}' /proc/meminfo)
HP_F=$(awk '/HugePages_Free/  {print $2}' /proc/meminfo)
[ "${HP_T:-0}" -gt 0 ] && kv "Hugepages" "$((HP_T-HP_F)) used / $HP_T total"

hdr "CPU LOAD (XDP=core${XDP_CPU}, PoH=core${POH_CPU})"
if command -v mpstat &>/dev/null; then
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
LOAD=$(awk '{print $1, $2, $3}' /proc/loadavg)
NCPU=$(nproc)
kv "Load avg (1/5/15m)" "$LOAD  ${D}(${NCPU} cores)${N}"

hdr "MEMORY"
free -h | awk 'NR==2 {printf "  %-22s used=%s / total=%s (avail=%s)\n", "RAM", $3, $2, $7}'
free -h | awk 'NR==3 {printf "  %-22s used=%s / total=%s\n", "Swap", $3, $2}'
for path in /dev/shm /mnt/ramdisk; do
    [ -d "$path" ] || continue
    SHM=$(df -h "$path" 2>/dev/null | awk 'NR==2 {printf "used=%s / total=%s (%s)", $3, $2, $5}')
    SHM_PCT=$(df "$path" 2>/dev/null | awk 'NR==2 {print $5}' | tr -d '%')
    if [ "${SHM_PCT:-0}" -ge 90 ]; then bad "$path: $SHM"
    elif [ "${SHM_PCT:-0}" -ge 75 ]; then warn "$path: $SHM"
    else kv "$path" "$SHM"; fi
done

hdr "DISK"
if [ -d "$LEDGER_DIR" ]; then
    LDISK=$(df -h "$LEDGER_DIR" | awk 'NR==2 {printf "used=%s / total=%s (%s)", $3, $2, $5}')
    kv "Ledger volume" "$LDISK"
    LSIZE=$(du -sh "$LEDGER_DIR" 2>/dev/null | awk '{print $1}')
    kv "Ledger size" "$LSIZE"
fi

hdr "NETWORK (${DEFIFACE:-?})"
if [ -n "${DEFIFACE:-}" ]; then
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
    RX_PPS=$((RXP2-RXP1)); TX_PPS=$((TXP2-TXP1))
    printf "  %-22s ${G}↓${N} %6s Mbps  %6s pps\n" "RX" "$RX_MBPS" "$RX_PPS"
    printf "  %-22s ${R}↑${N} %6s Mbps  %6s pps\n" "TX" "$TX_MBPS" "$TX_PPS"
    DROP_RX=$(cat /sys/class/net/$DEFIFACE/statistics/rx_dropped)
    DROP_TX=$(cat /sys/class/net/$DEFIFACE/statistics/tx_dropped)
    ERR_RX=$(cat /sys/class/net/$DEFIFACE/statistics/rx_errors)
    ERR_TX=$(cat /sys/class/net/$DEFIFACE/statistics/tx_errors)
    if is_pos "$DROP_RX" || is_pos "$DROP_TX" || is_pos "$ERR_RX" || is_pos "$ERR_TX"; then
        kv "drops/errors" "rx_drop=$DROP_RX tx_drop=$DROP_TX rx_err=$ERR_RX tx_err=$ERR_TX"
    else
        ok "no drops or errors"
    fi
fi

hdr "VALIDATOR"
if command -v agave-validator &>/dev/null && [ -d "$LEDGER_DIR" ]; then
    CINFO=$(timeout 5 agave-validator --ledger "$LEDGER_DIR" contact-info 2>/dev/null \
        | awk -F':' '{
            if ($1 ~ /Identity/) ident=$2;
            if ($1 ~ /^Version/) ver=$2;
            if ($1 ~ /Shred Version/) shred=$2;
        } END { printf "%s|%s|%s", ident, ver, shred }')
    IFS='|' read -r IDENT VER SHRED <<<"$CINFO"
    [ -n "$IDENT" ]  && kv "Identity" "$(echo $IDENT | tr -d ' ')"
    [ -n "$VER" ]    && kv "Version"  "$(echo $VER | tr -d ' ')"
    [ -n "$SHRED" ]  && kv "Shred ver" "$(echo $SHRED | tr -d ' ')"
fi

hdr "VOTING (via ${RPC_URL:-no RPC})"
if command -v solana &>/dev/null && [ -n "${VOTE_ACCOUNT:-}" ] && [ -f "$VOTE_ACCOUNT" ] && [ -n "${RPC_URL:-}" ]; then
    VOTE_PUB=$(solana-keygen pubkey "$VOTE_ACCOUNT" 2>/dev/null)
    [ -n "$VOTE_PUB" ] && kv "Vote account" "$VOTE_PUB"
    VA=$(timeout 10 solana --url "$RPC_URL" vote-account "$VOTE_PUB" 2>/dev/null)
    if [ -n "$VA" ]; then
        COMM=$(echo "$VA" | grep -i "Commission:" | head -1 | awk '{print $2}')
        ROOT=$(echo "$VA" | grep -i "Root Slot:" | head -1 | awk '{print $3}')
        CRED=$(echo "$VA" | grep -E "^Credits:" | head -1 | awk '{print $2}')
        [ -n "$COMM" ] && kv "Commission" "$COMM"
        [ -n "$ROOT" ] && kv "Root Slot" "$ROOT"
        [ -n "$CRED" ] && kv "Credits" "$CRED"
    fi
    if [ -n "${IDENT:-}" ]; then
        IDENT_CLEAN=$(echo "$IDENT" | tr -d ' ')
        DLQ_LINE=$(timeout 10 solana --url "$RPC_URL" validators 2>/dev/null | grep "$IDENT_CLEAN" | head -1)
        if [ -z "$DLQ_LINE" ]; then warn "Identity не найден в validators"
        elif echo "$DLQ_LINE" | grep -qE "^\s*⚠|delinquent"; then bad "${BO}WE ARE DELINQUENT${N}"
        else ok "Not delinquent"; fi
    fi
fi

hdr "JITO BAM/RELAYER (фоновый шум — не критично)"
BAM_EXP=$(journalctl -u jito --since "10 minutes ago" 2>/dev/null | grep -c "Challenge expired")
BAM_LAST_LAT=$(journalctl -u jito --since "10 minutes ago" 2>/dev/null \
    | grep "Challenge expired" | tail -1 \
    | grep -oE "elapsed since creation: [0-9.]+(ns|µs|ms|s)")
RELAYER_ERR=$(journalctl -u jito --since "10 minutes ago" 2>/dev/null | grep -c "relayer_stage-proxy_error")
if [ "$BAM_EXP" -gt 0 ]; then
    info "BAM 'Challenge expired' = $BAM_EXP (latency to BAM > 30ms)"
    [ -n "$BAM_LAST_LAT" ] && info "  Last: $BAM_LAST_LAT (limit 30ms)"
else
    ok "BAM clean"
fi
[ "$RELAYER_ERR" -gt 0 ] && info "Relayer errors = $RELAYER_ERR" || ok "Relayer clean"

hdr "REAL ERRORS (last 10 min, БЕЗ BAM/relayer)"
REAL_ERR=$(journalctl -u jito --since "10 minutes ago" 2>/dev/null \
    | grep -E "\b(ERROR|PANIC|FATAL)\b" \
    | grep -v "bam_connection" | grep -v "Challenge expired" \
    | grep -v "relayer_stage-proxy_error" | grep -v "block_engine" \
    | wc -l)
REAL_WARN=$(journalctl -u jito --since "10 minutes ago" 2>/dev/null \
    | grep -E "\bWARN\b" \
    | grep -v "bam_connection" | grep -v "relayer" | grep -v "block_engine" \
    | wc -l)
kv "Real errors (10m)" "$REAL_ERR"
kv "Real warnings (10m)" "$REAL_WARN"
if is_pos "$REAL_ERR"; then
    echo "  ${D}Last 3 real errors:${N}"
    journalctl -u jito --since "10 minutes ago" 2>/dev/null \
        | grep -E "\b(ERROR|PANIC|FATAL)\b" \
        | grep -v "bam_connection" | grep -v "Challenge expired" \
        | grep -v "relayer_stage-proxy_error" | grep -v "block_engine" \
        | tail -3 | cut -c1-200 | sed "s/^/    ${R}│${N} /"
fi
echo
}

MODE="${1:-once}"; INTERVAL="${2:-30}"
case "$MODE" in
    watch) while true; do snapshot; printf "${D}refresh every ${INTERVAL}s — Ctrl-C${N}\n"; sleep "$INTERVAL"; done ;;
    once|"") snapshot ;;
    *) echo "Usage: $0 [once|watch] [sec]"; exit 1 ;;
esac
STATUSEOF

chmod 755 /usr/local/sbin/solana-status
printf "${G}✔${N} /usr/local/sbin/solana-status\n"

# ============================================================================
# solana-audit
# ============================================================================
cat > /usr/local/sbin/solana-audit <<'AUDITEOF'
#!/usr/bin/env bash
# solana-audit — READ-ONLY полный аудит ноды против Anza canon

set -u
G=$'\033[32m'; R=$'\033[31m'; Y=$'\033[33m'; B=$'\033[34m'
M=$'\033[35m'; C=$'\033[36m'; D=$'\033[2m'; N=$'\033[0m'; BO=$'\033[1m'

ok()   { printf "  ${G}✔${N} %s\n" "$1"; }
warn() { printf "  ${Y}⚠${N} %s\n" "$1"; }
bad()  { printf "  ${R}✘${N} %s\n" "$1"; }
info() { printf "  ${B}ℹ${N} %s\n" "$1"; }
kv()   { printf "  ${D}%-26s${N} %s\n" "$1" "$2"; }
hdr()  { echo; printf "${BO}${C}▌ %s${N}\n" "$1"; printf "${D}──────────────────────────────────────────────────────────────────────${N}\n"; }

UNIT=/etc/systemd/system/jito.service
[ -f "$UNIT" ] || { bad "Нет $UNIT"; exit 1; }

PID=$(systemctl show -p MainPID --value jito 2>/dev/null)
[ "$PID" = "0" ] && PID=""

CLUSTER="unknown"; RPC=""
if command -v solana &>/dev/null; then
    CFG_RPC=$(solana config get 2>/dev/null | awk -F': ' '/^RPC URL/ {print $2}' | tr -d ' \r\n')
    case "$CFG_RPC" in
        *testnet*)        CLUSTER="testnet";      RPC="$CFG_RPC" ;;
        *mainnet-beta*)   CLUSTER="mainnet-beta"; RPC="$CFG_RPC" ;;
        *devnet*)         CLUSTER="devnet";       RPC="$CFG_RPC" ;;
    esac
fi
if [ "$CLUSTER" = "unknown" ]; then
    if   grep -q "entrypoint.testnet"      "$UNIT" 2>/dev/null; then CLUSTER="testnet";      RPC="https://api.testnet.solana.com"
    elif grep -q "entrypoint.mainnet-beta" "$UNIT" 2>/dev/null; then CLUSTER="mainnet-beta"; RPC="https://api.mainnet-beta.solana.com"
    elif grep -q "entrypoint.devnet"       "$UNIT" 2>/dev/null; then CLUSTER="devnet";       RPC="https://api.devnet.solana.com"
    fi
fi

printf "${BO}${M}═══════════════════════════════════════════════════════════════════════${N}\n"
printf "${BO}${M}  SOLANA AUDIT — $(hostname) [%s] — $(date '+%Y-%m-%d %H:%M:%S %Z')${N}\n" "$CLUSTER"
printf "${BO}${M}═══════════════════════════════════════════════════════════════════════${N}\n"

hdr "1. SERVICE STATE"
if systemctl is-active --quiet jito; then
    ok "jito.service active"
    kv "Started"  "$(systemctl show -p ActiveEnterTimestamp --value jito)"
    kv "PID"      "${PID:-?}"
    kv "Restarts" "$(systemctl show -p NRestarts --value jito)"
else
    bad "jito не active"
fi

hdr "2. CAPABILITIES — сверка с Anza canon"
ANZA_CAPS="CAP_NET_RAW CAP_NET_ADMIN CAP_BPF CAP_PERFMON"
CB=$(grep "^CapabilityBoundingSet=" "$UNIT" | sed 's/^CapabilityBoundingSet=//')
AB=$(grep "^AmbientCapabilities="    "$UNIT" | sed 's/^AmbientCapabilities=//')
kv "CapabilityBoundingSet" "${CB:-<not set>}"
kv "AmbientCapabilities"   "${AB:-<not set>}"
if [ "$CB" = "$ANZA_CAPS" ]; then
    ok "CapabilityBoundingSet точно как Anza canon"
else
    extra=""; miss=""
    for c in $CB; do case " $ANZA_CAPS " in *" $c "*) ;; *) extra="$extra $c";; esac; done
    for c in $ANZA_CAPS; do echo " $CB " | grep -q " $c " || miss="$miss $c"; done
    [ -n "$miss"  ] && bad "Не хватает:$miss"
    [ -n "$extra" ] && warn "Лишние (Agave дропнет):$extra"
fi
if [ -n "$PID" ] && [ -d "/proc/$PID" ]; then
    USR=$(ps -o user= -p $PID | tr -d ' ')
    kv "Process User" "$USR"
    [ "$USR" = "root" ] && info "User=root: CapEff пустые ожидаемо (root неявно)"
fi

hdr "3. XDP CONFIG"
if [ -n "$PID" ]; then
    XDP=$(tr '\0' '\n' < /proc/$PID/cmdline 2>/dev/null | grep -A1 "experimental-")
    if echo "$XDP" | grep -q "retransmit-xdp"; then
        ok "XDP-флаги в живом процессе:"
        echo "$XDP" | sed 's/^/    /'
    else
        warn "XDP-флагов нет в cmdline"
    fi
fi
DEFIFACE=$(ip route show default 2>/dev/null | awk '{print $5; exit}')
DRIVER=$(ethtool -i "$DEFIFACE" 2>/dev/null | awk -F': ' '/^driver:/ {print $2}' | tr -d ' \r\n')
kv "Active iface" "${DEFIFACE:-?}"
kv "NIC driver"   "${DRIVER:-?}"
ZC=$(grep -c "experimental-retransmit-xdp-zero-copy" "$UNIT")
case "$DRIVER" in
    bnxt_en)
        [ "$ZC" -eq 0 ] && ok "Нет --xdp-zero-copy (Anza запрет для bnxt_en)" \
                       || bad "С bnxt_en НЕЛЬЗЯ --xdp-zero-copy"
        ;;
    r8169|r8125)
        [ "$ZC" -eq 0 ] && ok "Нет --xdp-zero-copy (правильно для Realtek)" \
                       || warn "--xdp-zero-copy на Realtek не запустится"
        ;;
    ixgbe|i40e|ice|mlx5_core)
        [ "$ZC" -gt 0 ] && ok "--xdp-zero-copy включен (разрешено на $DRIVER)" \
                       || info "На $DRIVER можно включить --xdp-zero-copy"
        ;;
esac
START_TS=$(systemctl show -p ActiveEnterTimestamp --value jito)
XDP_LOOP=$(journalctl -u jito --since="$START_TS" 2>/dev/null | grep -c "starting xdp loop")
[ "$XDP_LOOP" -gt 0 ] && ok "XDP стартовал ($XDP_LOOP × loop)" || bad "XDP loop не найден в логах"

hdr "4. NIC TUNING"
[ -n "${DEFIFACE:-}" ] && kv "Speed" "$(ethtool $DEFIFACE 2>/dev/null | awk -F': ' '/Speed:/ {print $2}')"
RING=$(ethtool -g "${DEFIFACE:-x}" 2>/dev/null || true)
if [ -n "$RING" ]; then
    CUR_RX=$(echo "$RING" | awk '/Current hardware settings:/{f=1;next} f && /^RX:/ {print $2; exit}')
    CUR_TX=$(echo "$RING" | awk '/Current hardware settings:/{f=1;next} f && /^TX:/ {print $2; exit}')
    MAX_RX=$(echo "$RING" | awk '/Pre-set maximums:/{f=1;next} f && /^RX:/ {print $2; exit}')
    kv "Ring RX/TX" "${CUR_RX:-?} / ${CUR_TX:-?} (max=$MAX_RX)"
    is_pow2() { local n="$1"; [[ "$n" =~ ^[0-9]+$ ]] && [ "$n" -gt 0 ] && [ $((n & (n-1))) -eq 0 ] && echo yes || echo no; }
    [ "$(is_pow2 "$CUR_RX")" = "yes" ] && [ "$(is_pow2 "$CUR_TX")" = "yes" ] \
        && ok "ring power-of-2" || warn "ring NOT power-of-2"
fi
grep -q "^ExecStartPre=.*ethtool -G" "$UNIT" && ok "ExecStartPre с ethtool есть" \
    || { [ "$DRIVER" = "bnxt_en" ] && warn "Для bnxt_en полезен ExecStartPre ethtool -G" \
                                  || info "ExecStartPre не нужен для $DRIVER"; }
CUR_CMB=$(ethtool -l "${DEFIFACE:-x}" 2>/dev/null | awk '/Current hardware settings:/{f=1;next} f && /^Combined:/ {print $2; exit}')
MAX_CMB=$(ethtool -l "${DEFIFACE:-x}" 2>/dev/null | awk '/Pre-set maximums:/{f=1;next} f && /^Combined:/ {print $2; exit}')
kv "Combined queues" "${CUR_CMB:-n/a} / ${MAX_CMB:-n/a}"

hdr "5. HUGEPAGES"
HP_T=$(awk '/HugePages_Total/ {print $2}' /proc/meminfo)
HP_F=$(awk '/HugePages_Free/   {print $2}' /proc/meminfo)
HP_S=$(awk '/Hugepagesize/     {print $2}' /proc/meminfo)
HP_GB=$(awk "BEGIN {printf \"%.2f\", $HP_T*$HP_S/1024/1024}")
kv "HugePages_Total" "$HP_T (=${HP_GB} GB)"
kv "Used / Free"     "$((HP_T-HP_F)) / $HP_F"
[ "$HP_T" -ge 1024 ] && ok "Hugepages выделены" \
    || { [ "$HP_T" -gt 0 ] && warn "Меньше 1024 — фрагментация" || bad "Hugepages не выделены"; }
[ -f /etc/sysctl.d/99-solana-xdp.conf ] && ok "persistent config есть" || warn "/etc/sysctl.d/99-solana-xdp.conf отсутствует"
HF=$(journalctl -u jito --since="$START_TS" 2>/dev/null | grep -c "huge page alloc failed")
[ "$HF" -eq 0 ] && ok "Нет 'huge page alloc failed'" || warn "'huge page alloc failed' = $HF раз"

hdr "6. METRICS"
ENV_LINE=$(grep "^Environment" "$UNIT" | grep "SOLANA_METRICS_CONFIG")
DB=$(echo "$ENV_LINE" | grep -oE "db=[^,\"]+" | sed 's/db=//')
U=$( echo "$ENV_LINE" | grep -oE "u=[^,\"]+"  | sed 's/u=//')
kv "db / user" "$DB / $U"
case "$DB-$U" in
    "tds-testnet_write")               ok "Testnet — Anza canon" ;;
    "mainnet-beta-mainnet-beta_write") ok "Mainnet — Anza canon" ;;
    "devnet-scratch_writer")           ok "Devnet — Anza canon" ;;
    *) warn "Нестандартный db/user — сверь с docs.anza.xyz/clusters/available" ;;
esac
echo "$ENV_LINE" | grep -qE 'Environment="[A-Z_]+="' && bad "Вложенные кавычки в Environment" || ok "Синтаксис Environment ок"

hdr "7. CLUSTER & SERVICE FLAGS"
SCH=$(grep -oE "block-production-method [a-z-]+" "$UNIT" | awk '{print $2}')
kv "block-production-method" "${SCH:-?}"
[ "$SCH" = "central-scheduler-greedy" ] && ok "greedy scheduler (latest)" \
                                        || warn "$SCH — обнови до central-scheduler-greedy"
DEPR=$(journalctl -u jito --since="$START_TS" 2>/dev/null | grep -c "deprecated")
[ "$DEPR" -eq 0 ] && ok "Нет deprecation warnings" || warn "$DEPR deprecation warnings"

hdr "8. RESOURCES"
NCPU=$(nproc)
NNODES=$(lscpu | awk '/NUMA node\(s\):/ {print $3}')
kv "CPU / NUMA" "$NCPU cores / $NNODES nodes"
[ "$NNODES" -ge 2 ] && ok "2+ NUMA (Anza recommended)" || warn "1 NUMA (Anza советует ≥2)"
RAM_T=$(awk '/MemTotal/ {print $2}' /proc/meminfo)
RAM_A=$(awk '/MemAvailable/ {print $2}' /proc/meminfo)
kv "RAM total/avail" "$(awk "BEGIN {printf \"%.1f GB / %.1f GB\", $RAM_T/1048576, $RAM_A/1048576}")"
LEDGER=$(grep -oE -- "--ledger [^ ]+" "$UNIT" | head -1 | awk '{print $2}')
if [ -n "${LEDGER:-}" ] && [ -d "$LEDGER" ]; then
    kv "Ledger" "$(df -h "$LEDGER" | awk 'NR==2 {printf "%s / %s (%s)", $3, $2, $5}')"
fi

hdr "9. NETWORK HEALTH"
if [ -n "${DEFIFACE:-}" ]; then
    RX_DROP=$(cat /sys/class/net/$DEFIFACE/statistics/rx_dropped 2>/dev/null || echo 0)
    TX_DROP=$(cat /sys/class/net/$DEFIFACE/statistics/tx_dropped 2>/dev/null || echo 0)
    kv "rx_drop / tx_drop" "$RX_DROP / $TX_DROP"
fi
RT=$(journalctl -u jito --since "5 minutes ago" 2>/dev/null | grep -c "retransmit-first-shred")
kv "retransmit-first-shred (5m)" "$RT"
[ "$RT" -gt 100 ] && ok "Retransmit активен" || warn "Мало retransmit"
BAM_EXP=$(journalctl -u jito --since "5 minutes ago" 2>/dev/null | grep -c "Challenge expired")
if [ "$BAM_EXP" -gt 0 ]; then
    info "BAM 'Challenge expired' = $BAM_EXP (фоновый шум, не влияет)"
else
    ok "BAM clean"
fi

hdr "10. VOTING (via ${RPC:-no RPC})"
VA_PATH=$(grep -oE -- "--vote-account [^ ]+" "$UNIT" | head -1 | awk '{print $2}')
if command -v solana &>/dev/null && [ -n "${VA_PATH:-}" ] && [ -f "$VA_PATH" ] && [ -n "${RPC:-}" ]; then
    VA_PUB=$(solana-keygen pubkey "$VA_PATH" 2>/dev/null)
    kv "Vote account" "${VA_PUB:-?}"
    VA=$(timeout 10 solana --url "$RPC" vote-account "$VA_PUB" 2>/dev/null)
    [ -n "$VA" ] && {
        CRED=$(echo "$VA" | grep -E "^Credits:" | head -1 | awk '{print $2}')
        ROOT=$(echo "$VA" | grep -i "Root Slot:" | head -1 | awk '{print $3}')
        [ -n "$CRED" ] && kv "Credits" "$CRED"
        [ -n "$ROOT" ] && kv "Root Slot" "$ROOT"
    }
fi

hdr "11. REAL ERRORS / WARNINGS LAST 10 MIN"
ERR=$(journalctl -u jito --since "10 minutes ago" 2>/dev/null \
    | grep -E "\b(ERROR|PANIC|FATAL)\b" \
    | grep -v "bam_connection" | grep -v "Challenge expired" \
    | grep -v "relayer_stage-proxy_error" | grep -v "block_engine" \
    | wc -l)
WRN=$(journalctl -u jito --since "10 minutes ago" 2>/dev/null \
    | grep -E "\bWARN\b" \
    | grep -v "bam" | grep -v "relayer" | grep -v "block_engine" \
    | wc -l)
kv "Real ERROR (10m)" "$ERR"
kv "Real WARN (10m)"  "$WRN"
if [ "$ERR" -gt 0 ]; then
    echo "  ${D}Last 3 real errors:${N}"
    journalctl -u jito --since "10 minutes ago" 2>/dev/null \
        | grep -E "\b(ERROR|PANIC|FATAL)\b" \
        | grep -v "bam_connection" | grep -v "Challenge expired" \
        | grep -v "relayer_stage-proxy_error" | grep -v "block_engine" \
        | tail -3 | cut -c1-200 | sed 's/^/    /'
fi

hdr "12. РЕЗЮМЕ"
if [ "$ERR" -eq 0 ] && [ "$XDP_LOOP" -gt 0 ] && [ "$HF" -eq 0 ] && [ "$DEPR" -eq 0 ]; then
    printf "  ${G}${BO}✔ ВСЁ ОК — XDP активен, Anza canon, без настоящих ошибок${N}\n"
else
    printf "  ${Y}${BO}⚠ Есть замечания (см. выше)${N}\n"
fi
AUDITEOF

chmod 755 /usr/local/sbin/solana-audit
printf "${G}✔${N} /usr/local/sbin/solana-audit\n"

echo
printf "${BO}${C}SYNTAX CHECK${N}\n"
bash -n /usr/local/sbin/solana-status && printf "  ${G}✔${N} solana-status: bash -n ок\n" || printf "  ${R}✘${N} solana-status: syntax error\n"
bash -n /usr/local/sbin/solana-audit  && printf "  ${G}✔${N} solana-audit:  bash -n ок\n" || printf "  ${R}✘${N} solana-audit:  syntax error\n"

echo
printf "${BO}${C}УСТАНОВЛЕНО${N}\n"
ls -la /usr/local/sbin/solana-status /usr/local/sbin/solana-audit
echo
printf "${BO}Использование:${N}\n"
printf "  ${C}solana-status${N}            — dashboard, один прогон\n"
printf "  ${C}solana-status watch${N}      — обновление каждые 30 сек\n"
printf "  ${C}solana-status watch 10${N}   — каждые 10 сек\n"
printf "  ${C}solana-audit${N}             — полный аудит против Anza canon\n"

echo
echo "##########################################################################"
echo "########## END OF OUTPUT #################################################"
echo "##########################################################################"
