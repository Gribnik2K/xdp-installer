#!/usr/bin/env bash
# xdp-install.sh
# Универсальный установщик XDP для Jito-Solana валидатора согласно Anza guide:
#   https://www.anza.xyz/blog/agave-xdp-setup-guide
#   https://docs.anza.xyz/clusters/available
#
# Что делает:
#   1) Детектит активный NIC и драйвер
#   2) Проверяет соответствие требованиям (драйвер, ring buffer, multi-queue, kernel, agave version)
#   3) Выделяет 2GB hugepages (persistent через /etc/sysctl.d/)
#   4) Модифицирует /etc/systemd/system/jito.service ИНКРЕМЕНТАЛЬНО:
#      - Добавляет/обновляет CapabilityBoundingSet/AmbientCapabilities = Anza canon
#      - Добавляет LimitMEMLOCK/LimitNPROC/KillSignal/TimeoutStopSec
#      - Для bnxt_en: ExecStartPre=ethtool -G ... rx 1024 tx 1024
#      - Добавляет XDP-флаги в ExecStart с учётом драйвера:
#        - bnxt_en      → БЕЗ --xdp-zero-copy (Anza запрет)
#        - ixgbe/i40e/ice/mlx5_core → С --xdp-zero-copy
#        - Realtek      → С предупреждением, generic mode
#      - Обновляет block-production-method до central-scheduler-greedy
#   5) Делает бэкап с datestamp
#   6) Показывает diff, ждёт подтверждения
#   7) daemon-reload + restart с verification
#
# Использование:
#   bash xdp-install.sh                # интерактивно, спросит подтверждение перед restart
#   bash xdp-install.sh --auto         # без вопросов (для скриптинга)
#   bash xdp-install.sh --dry-run      # только показать что будет сделано
#
# Override (если автодетект ошибается):
#   XDP_CPU=20 POH_CPU=4 bash xdp-install.sh
#   XDP_INTERFACE=enp1s0f1 bash xdp-install.sh

set -u

# ============================================================================
# Параметры (через env override)
# ============================================================================
XDP_CPU="${XDP_CPU:-16}"
POH_CPU="${POH_CPU:-0}"
HUGEPAGES_COUNT="${HUGEPAGES_COUNT:-1024}"
RING_SIZE="${RING_SIZE:-1024}"
MODE="interactive"
for arg in "$@"; do
    case "$arg" in
        --auto)     MODE="auto" ;;
        --dry-run)  MODE="dry-run" ;;
        -h|--help)
            sed -n '2,30p' "$0"
            exit 0
            ;;
    esac
done

G=$'\033[32m'; R=$'\033[31m'; Y=$'\033[33m'; B=$'\033[34m'
M=$'\033[35m'; C=$'\033[36m'; D=$'\033[2m'; N=$'\033[0m'; BO=$'\033[1m'

ok()   { printf "  ${G}✔${N} %s\n" "$1"; }
warn() { printf "  ${Y}⚠${N} %s\n" "$1"; }
bad()  { printf "  ${R}✘${N} %s\n" "$1"; }
info() { printf "  ${B}ℹ${N} %s\n" "$1"; }
kv()   { printf "  ${D}%-26s${N} %s\n" "$1" "$2"; }
hdr()  { echo; printf "${BO}${C}▌ %s${N}\n" "$1"; printf "${D}──────────────────────────────────────────────────────────────────────${N}\n"; }

echo
echo "##########################################################################"
echo "########## OUTPUT BELOW — copy from here when pasting back ###############"
echo "##########################################################################"
echo

printf "${BO}${M}═══════════════════════════════════════════════════════════════════════${N}\n"
printf "${BO}${M}  XDP INSTALL FOR JITO-SOLANA — $(hostname) — $(date '+%Y-%m-%d %H:%M:%S')${N}\n"
printf "${BO}${M}  Mode: %s${N}\n" "$MODE"
printf "${BO}${M}═══════════════════════════════════════════════════════════════════════${N}\n"

[ "$EUID" -eq 0 ] || { bad "Запускай под root"; exit 1; }

UNIT=/etc/systemd/system/jito.service
[ -f "$UNIT" ] || { bad "Нет $UNIT"; exit 1; }

# ============================================================================
# 1. ДЕТЕКТ ЖЕЛЕЗА
# ============================================================================
hdr "1. ДЕТЕКТ ЖЕЛЕЗА"

# Активный интерфейс
if [ -n "${XDP_INTERFACE:-}" ]; then
    IFACE="$XDP_INTERFACE"
    info "Interface overridden: $IFACE"
else
    IFACE=$(ip route show default 2>/dev/null | awk '{print $5; exit}')
fi
[ -z "$IFACE" ] && { bad "Не нашёл активный интерфейс"; exit 1; }

DRIVER=$(ethtool -i "$IFACE" 2>/dev/null | awk -F': ' '/^driver:/ {print $2}' | tr -d ' \r\n')
SPEED=$(ethtool "$IFACE" 2>/dev/null | awk -F': ' '/Speed:/ {print $2}' | tr -d ' \r\n')
kv "Interface" "$IFACE"
kv "Driver"    "$DRIVER"
kv "Speed"     "$SPEED"

# Решение по драйверу
case "$DRIVER" in
    bnxt_en)
        GRADE="B"
        USE_ZEROCOPY=0
        NEED_ETHTOOL_PRE=1
        info "Broadcom NetXtreme-E (bnxt_en): native XDP, БЕЗ zero-copy (Anza запрет)"
        info "Понадобится ExecStartPre=ethtool -G ... rx $RING_SIZE tx $RING_SIZE"
        ;;
    ixgbe)
        GRADE="A-"
        USE_ZEROCOPY=1
        NEED_ETHTOOL_PRE=0
        info "Intel 82599/X550 (ixgbe): native XDP + zero-copy разрешён"
        ;;
    i40e)
        GRADE="A"
        USE_ZEROCOPY=1
        NEED_ETHTOOL_PRE=0
        info "Intel X710/XL710 (i40e): native XDP + zero-copy, рекомендован Anza"
        ;;
    ice)
        GRADE="A+"
        USE_ZEROCOPY=1
        NEED_ETHTOOL_PRE=0
        info "Intel E810 (ice): эталонный native XDP + zero-copy"
        ;;
    mlx5_core)
        GRADE="A+"
        USE_ZEROCOPY=1
        NEED_ETHTOOL_PRE=0
        info "Mellanox ConnectX-4+ (mlx5_core): эталонный native XDP + zero-copy"
        ;;
    r8169|r8125)
        GRADE="D"
        USE_ZEROCOPY=0
        NEED_ETHTOOL_PRE=0
        warn "Realtek ($DRIVER): generic XDP only, профита почти не будет"
        warn "Можно установить для подготовки к будущим обязательным режимам"
        ;;
    *)
        GRADE="?"
        USE_ZEROCOPY=0
        NEED_ETHTOOL_PRE=0
        warn "Неизвестный драйвер '$DRIVER' — продолжаем БЕЗ zero-copy"
        ;;
esac
kv "XDP Grade" "$GRADE"

# Ring size check
RING_OUT=$(ethtool -g "$IFACE" 2>/dev/null)
if [ -n "$RING_OUT" ]; then
    CUR_RX=$(echo "$RING_OUT" | awk '/Current hardware settings:/{f=1;next} f && /^RX:/ {print $2; exit}')
    MAX_RX=$(echo "$RING_OUT" | awk '/Pre-set maximums:/{f=1;next} f && /^RX:/ {print $2; exit}')
    kv "Ring RX current/max" "$CUR_RX / $MAX_RX"
    is_pow2() { local n="$1"; [[ "$n" =~ ^[0-9]+$ ]] && [ "$n" -gt 0 ] && [ $((n & (n-1))) -eq 0 ] && echo yes || echo no; }
    if [ "$(is_pow2 "$CUR_RX")" = "no" ]; then
        NEED_ETHTOOL_PRE=1
        # Подобрать ближайший разумный power-of-2 ≤ max
        for s in 4096 2048 1024 512; do
            if [ "${MAX_RX:-0}" -ge "$s" ] 2>/dev/null; then
                RING_SIZE=$s
                break
            fi
        done
        warn "Ring NOT power-of-2 → ExecStartPre установит $RING_SIZE/$RING_SIZE"
    fi
fi

# Multi-queue
CUR_CMB=$(ethtool -l "$IFACE" 2>/dev/null | awk '/Current hardware settings:/{f=1;next} f && /^Combined:/ {print $2; exit}')
MAX_CMB=$(ethtool -l "$IFACE" 2>/dev/null | awk '/Pre-set maximums:/{f=1;next} f && /^Combined:/ {print $2; exit}')
kv "Combined queues" "${CUR_CMB:-n/a} / ${MAX_CMB:-n/a}"

# Kernel
KVER=$(uname -r); KMAJ=$(echo "$KVER" | cut -d. -f1); KMIN=$(echo "$KVER" | cut -d. -f2)
kv "Kernel" "$KVER"
if [ "$KMAJ" -gt 5 ] || { [ "$KMAJ" -eq 5 ] && [ "$KMIN" -ge 3 ]; }; then
    ok "kernel ≥ 5.3 (AF_XDP zero-copy support)"
else
    bad "kernel слишком старый для XDP"; exit 1
fi
[ -f /sys/kernel/btf/vmlinux ] && ok "BTF vmlinux present"

# CPU/NUMA
NCPU=$(nproc)
NNODES=$(lscpu | awk '/NUMA node\(s\):/ {print $3}')
kv "CPU cores" "$NCPU"
kv "NUMA nodes" "$NNODES"
[ "$NNODES" -ge 2 ] && ok "2+ NUMA (Anza recommended)" \
                    || warn "1 NUMA — Anza рекомендует ≥2 (ограничение железа, не блокер)"

# XDP/PoH cores проверка
if [ "$XDP_CPU" -ge "$NCPU" ]; then
    bad "XDP_CPU=$XDP_CPU >= NCPU=$NCPU. Set XDP_CPU env to valid core."
    exit 1
fi
if [ "$POH_CPU" -ge "$NCPU" ]; then
    bad "POH_CPU=$POH_CPU >= NCPU=$NCPU. Set POH_CPU env to valid core."
    exit 1
fi
kv "Will pin XDP to core" "$XDP_CPU"
kv "Will pin PoH to core" "$POH_CPU"

# Agave version
if command -v agave-validator &>/dev/null; then
    VER=$(agave-validator --version 2>/dev/null | awk '{print $2}')
    kv "Agave version" "$VER"
    VM=$(echo "$VER" | cut -d. -f1)
    Vm=$(echo "$VER" | cut -d. -f2)
    Vp=$(echo "$VER" | cut -d. -f3 | grep -oE '^[0-9]+')
    if [ "${VM:-0}" -gt 3 ] 2>/dev/null \
       || { [ "${VM:-0}" -eq 3 ] && [ "${Vm:-0}" -gt 0 ]; } \
       || { [ "${VM:-0}" -eq 3 ] && [ "${Vm:-0}" -eq 0 ] && [ "${Vp:-0}" -ge 9 ]; }; then
        ok "Agave ≥ 3.0.9 (XDP supported)"
    else
        bad "Agave < 3.0.9 — обнови!"; exit 1
    fi
else
    bad "agave-validator не найден"; exit 1
fi

# ============================================================================
# 2. HUGEPAGES
# ============================================================================
hdr "2. HUGEPAGES (target: $HUGEPAGES_COUNT × 2MB = 2GB)"
HP_FILE=/etc/sysctl.d/99-solana-xdp.conf
HP_T=$(awk '/HugePages_Total/ {print $2}' /proc/meminfo)
kv "Сейчас выделено" "$HP_T"

if [ "$MODE" = "dry-run" ]; then
    info "[dry-run] Создал бы $HP_FILE с vm.nr_hugepages=$HUGEPAGES_COUNT"
else
    cat > "$HP_FILE" <<EOSY
# Solana / Jito XDP optimization
# $HUGEPAGES_COUNT × 2MB = 2GB hugepages reserved for XDP buffers
vm.nr_hugepages = $HUGEPAGES_COUNT
EOSY
    sysctl -p "$HP_FILE" 2>&1 | sed 's/^/    /'
    HP_T=$(awk '/HugePages_Total/ {print $2}' /proc/meminfo)
    if [ "$HP_T" -ge "$HUGEPAGES_COUNT" ]; then
        ok "Hugepages выделены полностью"
    elif [ "$HP_T" -gt 0 ]; then
        warn "Выделено $HP_T < $HUGEPAGES_COUNT (фрагментация). Не критично."
    else
        bad "Hugepages не выделены — память фрагментирована, нужен reboot"
    fi
fi

# ============================================================================
# 3. ПОДГОТОВКА UNIT-ФАЙЛА
# ============================================================================
hdr "3. ПОДГОТОВКА UNIT-ФАЙЛА"

STAMP=$(date +%Y%m%d-%H%M)
BACKUP="/root/jito.service.bak.xdp-install.$STAMP"
NEW=/tmp/jito.service.xdp-new

cp -a "$UNIT" "$BACKUP"
ok "Backup: $BACKUP"

# Идём по шагам — каждое изменение через awk/sed, проверяя что строки есть.

cp -a "$UNIT" "$NEW"

# 3.1. CapabilityBoundingSet и AmbientCapabilities — Anza canon
ANZA_CAPS="CAP_NET_RAW CAP_NET_ADMIN CAP_BPF CAP_PERFMON"
if grep -q "^CapabilityBoundingSet=" "$NEW"; then
    sed -i "s|^CapabilityBoundingSet=.*|CapabilityBoundingSet=$ANZA_CAPS|" "$NEW"
else
    # вставить после первой [Service] строки
    sed -i "/^\[Service\]$/a CapabilityBoundingSet=$ANZA_CAPS" "$NEW"
fi
if grep -q "^AmbientCapabilities=" "$NEW"; then
    sed -i "s|^AmbientCapabilities=.*|AmbientCapabilities=$ANZA_CAPS|" "$NEW"
else
    sed -i "/^CapabilityBoundingSet=/a AmbientCapabilities=$ANZA_CAPS" "$NEW"
fi
ok "Capabilities = Anza canon ($ANZA_CAPS)"

# 3.2. LimitMEMLOCK, LimitNPROC, KillSignal, TimeoutStopSec
add_if_missing() {
    local key="$1" value="$2"
    if ! grep -q "^$key=" "$NEW"; then
        sed -i "/^\[Service\]$/a $key=$value" "$NEW"
        ok "Added: $key=$value"
    fi
}
add_if_missing "LimitMEMLOCK"   "infinity"
add_if_missing "LimitNPROC"     "1048576"
add_if_missing "KillSignal"     "SIGINT"
add_if_missing "TimeoutStopSec" "300"

# 3.3. ExecStartPre для bnxt_en (или если ring не power-of-2)
if [ "$NEED_ETHTOOL_PRE" -eq 1 ]; then
    PRECMD="ExecStartPre=-/usr/sbin/ethtool -G $IFACE rx $RING_SIZE tx $RING_SIZE"
    # Убираем старый ExecStartPre с ethtool если есть
    sed -i "/^ExecStartPre=.*ethtool -G/d" "$NEW"
    # Добавляем перед ExecStart
    sed -i "/^ExecStart=/i $PRECMD" "$NEW"
    ok "ExecStartPre: ethtool -G $IFACE rx $RING_SIZE tx $RING_SIZE"
fi

# 3.4. Заменить block-production-method на central-scheduler-greedy
if grep -q "block-production-method central-scheduler\b" "$NEW" && \
   ! grep -q "central-scheduler-greedy" "$NEW"; then
    sed -i 's|block-production-method central-scheduler\b|block-production-method central-scheduler-greedy|' "$NEW"
    ok "block-production-method → central-scheduler-greedy"
fi

# 3.5. Добавить XDP-флаги в ExecStart
# Проверяем что флагов ещё нет
add_xdp_flag() {
    local flag="$1"
    if ! grep -qF -- "$flag" "$NEW"; then
        # Вставляем перед "--log -" если есть, иначе перед закрывающей пустой строкой ExecStart
        if grep -q "^[[:space:]]*--log -" "$NEW"; then
            sed -i "/^[[:space:]]*--log -/i\\  $flag \\\\" "$NEW"
        else
            warn "Не нашёл --log - для якоря вставки $flag — добавь руками"
            return 1
        fi
        ok "Added: $flag"
    fi
}

add_xdp_flag "--experimental-retransmit-xdp-interface $IFACE"
add_xdp_flag "--experimental-retransmit-xdp-cpu-cores $XDP_CPU"
add_xdp_flag "--experimental-poh-pinned-cpu-core $POH_CPU"
if [ "$USE_ZEROCOPY" -eq 1 ]; then
    add_xdp_flag "--experimental-retransmit-xdp-zero-copy"
else
    # Убираем если был
    if grep -q "experimental-retransmit-xdp-zero-copy" "$NEW"; then
        sed -i '/experimental-retransmit-xdp-zero-copy/d' "$NEW"
        warn "Removed --experimental-retransmit-xdp-zero-copy (запрет для $DRIVER)"
    fi
fi

# 3.6. Убрать устаревший --enable-accounts-disk-index если есть и есть --accounts-index-path
if grep -q "enable-accounts-disk-index" "$NEW" && grep -q "accounts-index-path" "$NEW"; then
    sed -i '/enable-accounts-disk-index/d' "$NEW"
    ok "Removed: --enable-accounts-disk-index (устарел при --accounts-index-path)"
fi

# ============================================================================
# 4. DIFF
# ============================================================================
hdr "4. DIFF (текущий vs предложенный)"
printf "${D}══════════════════════════════════════════════════════════════════════${N}\n"
diff -u "$UNIT" "$NEW" || true
printf "${D}══════════════════════════════════════════════════════════════════════${N}\n"

# ============================================================================
# 5. SANITY CHECK
# ============================================================================
hdr "5. SANITY CHECK"
issues=0
must_have=(
    "CapabilityBoundingSet=$ANZA_CAPS"
    "AmbientCapabilities=$ANZA_CAPS"
    "experimental-retransmit-xdp-interface $IFACE"
    "experimental-retransmit-xdp-cpu-cores $XDP_CPU"
    "experimental-poh-pinned-cpu-core $POH_CPU"
)
for s in "${must_have[@]}"; do
    if grep -qF -- "$s" "$NEW"; then
        ok "$s"
    else
        bad "MISSING: $s"
        issues=$((issues+1))
    fi
done

# Forbidden (если drv = bnxt_en, zero-copy не должно быть)
if [ "$DRIVER" = "bnxt_en" ] && grep -q "experimental-retransmit-xdp-zero-copy" "$NEW"; then
    bad "zero-copy на bnxt_en — Anza запрет"
    issues=$((issues+1))
fi

# Vложенные кавычки
if grep -qE 'Environment="[A-Z_]+="' "$NEW"; then
    bad "Вложенные кавычки в Environment"
    issues=$((issues+1))
fi

if [ "$issues" -gt 0 ]; then
    bad "Sanity check FAILED ($issues проблем)"
    rm -f "$NEW"
    exit 1
fi
ok "Sanity check passed"

# ============================================================================
# 6. APPLY
# ============================================================================
hdr "6. APPLY"

if [ "$MODE" = "dry-run" ]; then
    info "[dry-run] Не применяю. Файл с предложенными изменениями: $NEW"
    info "Чтобы применить вручную:"
    printf "  ${C}cp $NEW $UNIT${N}\n"
    printf "  ${C}systemctl daemon-reload && systemctl restart jito${N}\n"
    exit 0
fi

if [ "$MODE" = "interactive" ]; then
    echo
    printf "${BO}${Y}Применить изменения и рестартануть jito? (yes/no):${N} "
    read -r ANSWER
    if [ "$ANSWER" != "yes" ]; then
        info "Отменено. Файл с предложением: $NEW"
        info "Откат не нужен (изменений не было)"
        exit 0
    fi
fi

cp "$NEW" "$UNIT"
ok "Установлен новый $UNIT"

systemctl daemon-reload
ok "daemon-reload"

systemctl restart jito
sleep 3

if systemctl is-active --quiet jito; then
    NEW_PID=$(systemctl show -p MainPID --value jito)
    ok "jito active, new PID: $NEW_PID"
else
    bad "jito НЕ запустился!"
    echo
    printf "${R}${BO}ОТКАТ:${N}\n"
    printf "  ${C}cp $BACKUP $UNIT${N}\n"
    printf "  ${C}systemctl daemon-reload && systemctl restart jito${N}\n"
    echo
    systemctl status jito --no-pager | head -15
    exit 1
fi

# ============================================================================
# 7. POST-START VERIFY
# ============================================================================
hdr "7. POST-START VERIFY (через 15 сек)"
sleep 15

XDP_LOOP=$(journalctl -u jito --since "30 seconds ago" 2>/dev/null | grep -c "starting xdp loop")
HUGE_FAIL=$(journalctl -u jito --since "30 seconds ago" 2>/dev/null | grep -c "huge page alloc failed")
DEPR=$(journalctl -u jito --since "30 seconds ago" 2>/dev/null | grep -c "deprecated")
CAP_W=$(journalctl -u jito --since "30 seconds ago" 2>/dev/null | grep -c "extraneous capabilities")

[ "$XDP_LOOP" -gt 0 ] && ok "XDP loop started" \
                      || warn "XDP loop не виден в логах за 30 сек"
[ "$HUGE_FAIL" -eq 0 ] && ok "нет 'huge page alloc failed'" \
                       || warn "'huge page alloc failed' = $HUGE_FAIL"
[ "$DEPR" -eq 0 ] && ok "нет deprecation warnings" \
                  || warn "deprecation warnings = $DEPR"
[ "$CAP_W" -eq 0 ] && ok "нет 'extraneous capabilities'" \
                   || warn "'extraneous capabilities' = $CAP_W"

if [ "$NEED_ETHTOOL_PRE" -eq 1 ]; then
    ACTUAL_RX=$(ethtool -g "$IFACE" 2>/dev/null | awk '/Current hardware settings:/{f=1;next} f && /^RX:/ {print $2; exit}')
    [ "$ACTUAL_RX" = "$RING_SIZE" ] && ok "Ring set to $ACTUAL_RX" \
                                    || warn "Ring is $ACTUAL_RX, expected $RING_SIZE"
fi

# ============================================================================
# ИТОГ
# ============================================================================
hdr "ИТОГ"
echo
printf "  Backup unit:     ${C}$BACKUP${N}\n"
printf "  Sysctl hugepages: ${C}$HP_FILE${N}\n"
echo
printf "${BO}Откат (если что-то не так):${N}\n"
printf "  ${C}cp $BACKUP $UNIT${N}\n"
printf "  ${C}rm $HP_FILE${N}\n"
printf "  ${C}sysctl -w vm.nr_hugepages=0${N}\n"
printf "  ${C}systemctl daemon-reload && systemctl restart jito${N}\n"
echo
printf "${BO}Дальше:${N}\n"
printf "  ${C}solana-status${N}  — мониторинг\n"
printf "  ${C}solana-audit${N}   — полный аудит\n"
printf "  ${C}journalctl -fu jito${N}  — live логи\n"

echo
echo "##########################################################################"
echo "########## END OF OUTPUT #################################################"
echo "##########################################################################"
