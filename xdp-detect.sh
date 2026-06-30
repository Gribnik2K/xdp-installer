#!/usr/bin/env bash
# xdp-detect.sh — ОДНОЗНАЧНАЯ проверка реального AF_XDP у работающего jito-валидатора.
#
# Зачем: метрика is_xdp=true в логах валидатора и `ip link ... prog/xdp` НЕ дают
# достоверного ответа на bnxt_en — программа AF_XDP там не отображается в ip link,
# хотя реально работает. is_xdp=true бывает false-positive при тихом fallback на UDP.
#
# Достоверные индикаторы (работают для ЛЮБОГО драйвера):
#   1) HugePages_Free < HugePages_Total  → UMEM взят валидатором → AF_XDP socket создан
#   2) `ss -f xdp` показывает сокет на <iface>:qN → AF_XDP реально забиндён
#   3) `ip -d link show` prog/xdp        → виден ТОЛЬКО на Intel (ixgbe/igb), НЕ на bnxt
#
# Вердикт: XDP считается рабочим если выполнены (1) И (2). Пункт (3) — бонус для Intel.
#
# Использование:
#   sudo bash xdp-detect.sh                 # автоопределение интерфейса по дефолтному маршруту
#   sudo bash xdp-detect.sh enp10s0f1np1    # явный интерфейс
#   sudo bash xdp-detect.sh --json          # машиночитаемый вывод
#
# Exit codes: 0 = XDP работает, 1 = НЕ работает, 2 = ошибка/не запущен валидатор.

set -uo pipefail

# ---------- args -------------------------------------------------------------
JSON=0
IFACE=""
for a in "$@"; do
    case "$a" in
        --json) JSON=1 ;;
        -*)     echo "Unknown flag: $a" >&2; exit 2 ;;
        *)      IFACE="$a" ;;
    esac
done

# ---------- colors -----------------------------------------------------------
if [ -t 1 ] && [ "$JSON" -eq 0 ]; then
    G=$'\033[32m'; R=$'\033[31m'; Y=$'\033[33m'; B=$'\033[34m'; D=$'\033[2m'; C=$'\033[0m'
else
    G=''; R=''; Y=''; B=''; D=''; C=''
fi
say()  { [ "$JSON" -eq 0 ] && echo "$@"; }
hdr()  { [ "$JSON" -eq 0 ] && echo "${B}$*${C}"; }

# ---------- detect interface -------------------------------------------------
if [ -z "$IFACE" ]; then
    IFACE=$(ip route show default 2>/dev/null | grep -oP 'dev \K\S+' | head -1)
fi
if [ -z "$IFACE" ] || ! ip link show "$IFACE" >/dev/null 2>&1; then
    say "${R}[!!]${C} Не удалось определить сетевой интерфейс. Укажи явно: sudo bash $0 <iface>"
    [ "$JSON" -eq 1 ] && echo '{"error":"interface_not_found"}'
    exit 2
fi

DRIVER=$(ethtool -i "$IFACE" 2>/dev/null | awk '/^driver/{print $2}')
KERNEL=$(uname -r)
HOST=$(hostname)

# ---------- locate validator pid ---------------------------------------------
# Пробуем systemd (любой из типичных юнитов), затем pgrep по бинарю.
VPID=""
for unit in jito jito.service solana validator agave; do
    p=$(systemctl show -p MainPID --value "$unit" 2>/dev/null || true)
    if [ -n "${p:-}" ] && [ "$p" != "0" ]; then VPID="$p"; break; fi
done
[ -z "$VPID" ] && VPID=$(pgrep -f 'agave-validator --ledger' 2>/dev/null | head -1 || true)

# ---------- indicator 1: HugePages / UMEM ------------------------------------
HP_TOTAL=$(awk '/HugePages_Total/{print $2}' /proc/meminfo 2>/dev/null || echo 0)
HP_FREE=$(awk '/HugePages_Free/{print $2}'  /proc/meminfo 2>/dev/null || echo 0)
HP_USED=$(( HP_TOTAL - HP_FREE ))
UMEM_OK=0
[ "$HP_TOTAL" -gt 0 ] && [ "$HP_USED" -gt 0 ] && UMEM_OK=1

# ---------- indicator 2: ss -f xdp socket on iface ---------------------------
# Ищем строку, где встречается имя интерфейса и :qN (queue binding).
SS_RAW=$(ss -f xdp 2>/dev/null | grep -E "${IFACE}:q[0-9]+" || true)
SOCK_OK=0
SOCK_QUEUES=""
if [ -n "$SS_RAW" ]; then
    SOCK_OK=1
    SOCK_QUEUES=$(echo "$SS_RAW" | grep -oE "${IFACE}:q[0-9]+" | sort -u | tr '\n' ' ')
fi

# ---------- indicator 3: prog/xdp in ip link (Intel-style only) --------------
PROG_LINE=$(ip -d link show "$IFACE" 2>/dev/null | grep -oE 'prog/xdp id [0-9]+ name [^ ]+' | head -1 || true)
PROG_OK=0
[ -n "$PROG_LINE" ] && PROG_OK=1

# ---------- indicator 4 (supporting): is_xdp metric --------------------------
# Не решающий — только для контекста. Берём последнее значение из логов за 2 мин.
ISXDP=$(journalctl -u jito --since "2 minutes ago" 2>/dev/null | grep -oE 'is_xdp=(true|false)' | tail -1 | cut -d= -f2 || true)
[ -z "$ISXDP" ] && ISXDP="n/a"

# ---------- supporting: rx_dropped -------------------------------------------
RXDROP=$(cat "/sys/class/net/$IFACE/statistics/rx_dropped" 2>/dev/null || echo "n/a")

# ---------- verdict ----------------------------------------------------------
# Главный критерий: UMEM взят И сокет забиндён. На Intel дополнительно есть prog/xdp.
MODE="unknown"
VERDICT=1   # 1 = не работает (по умолчанию)
if [ "$UMEM_OK" -eq 1 ] && [ "$SOCK_OK" -eq 1 ]; then
    VERDICT=0
    if [ "$PROG_OK" -eq 1 ]; then
        MODE="native+prog (Intel-style; zero-copy если включён флагом)"
    else
        MODE="native AF_XDP (bnxt-style; prog не виден в ip link — это норма)"
    fi
elif [ "$UMEM_OK" -eq 1 ] || [ "$SOCK_OK" -eq 1 ]; then
    VERDICT=1
    MODE="partial/uncertain (один индикатор сработал, другой нет)"
else
    VERDICT=1
    MODE="fallback to kernel UDP (AF_XDP не активен)"
fi

# ---------- JSON output ------------------------------------------------------
if [ "$JSON" -eq 1 ]; then
    printf '{'
    printf '"host":"%s","iface":"%s","driver":"%s","kernel":"%s",' "$HOST" "$IFACE" "${DRIVER:-unknown}" "$KERNEL"
    printf '"validator_pid":"%s",' "${VPID:-none}"
    printf '"hugepages_total":%s,"hugepages_free":%s,"hugepages_used":%s,"umem_ok":%s,' "$HP_TOTAL" "$HP_FREE" "$HP_USED" "$UMEM_OK"
    printf '"xdp_socket_ok":%s,"xdp_socket_queues":"%s",' "$SOCK_OK" "$(echo "$SOCK_QUEUES" | sed 's/ *$//')"
    printf '"prog_xdp_visible":%s,"prog_xdp":"%s",' "$PROG_OK" "$PROG_LINE"
    printf '"is_xdp_metric":"%s","rx_dropped":"%s",' "$ISXDP" "$RXDROP"
    printf '"mode":"%s","xdp_working":%s' "$MODE" "$([ $VERDICT -eq 0 ] && echo true || echo false)"
    printf '}\n'
    exit $VERDICT
fi

# ---------- human output -----------------------------------------------------
say "═══════════════════════════════════════════════════════════════"
say "  XDP DETECT — ${HOST} — $(date '+%Y-%m-%d %H:%M:%S')"
say "═══════════════════════════════════════════════════════════════"
say "  Интерфейс    ${IFACE}"
say "  Драйвер      ${DRIVER:-unknown}"
say "  Ядро         ${KERNEL}"
if [ -n "$VPID" ]; then
    say "  Валидатор    PID ${VPID} (запущен)"
else
    say "  Валидатор    ${Y}не найден${C} — индикаторы UMEM/socket будут пустыми"
fi
say ""
hdr "── Индикаторы ──────────────────────────────────────────────────"

# 1
if [ "$UMEM_OK" -eq 1 ]; then
    say "  ${G}✔${C} [1] UMEM      HugePages used=${HP_USED} (free ${HP_FREE}/${HP_TOTAL}) — UMEM взят"
else
    say "  ${R}✗${C} [1] UMEM      HugePages used=0 (free ${HP_FREE}/${HP_TOTAL}) — UMEM НЕ взят"
fi
# 2
if [ "$SOCK_OK" -eq 1 ]; then
    say "  ${G}✔${C} [2] SOCKET    ss -f xdp: ${SOCK_QUEUES}— AF_XDP сокет забиндён"
else
    say "  ${R}✗${C} [2] SOCKET    ss -f xdp: нет сокета на ${IFACE} — AF_XDP не забиндён"
fi
# 3
if [ "$PROG_OK" -eq 1 ]; then
    say "  ${G}✔${C} [3] PROG/XDP  ${PROG_LINE} (Intel-style attach)"
else
    say "  ${D}·${C} [3] PROG/XDP  не виден в ip link ${D}(норма для bnxt_en native)${C}"
fi
say ""
hdr "── Контекст (не решающий) ──────────────────────────────────────"
say "  is_xdp метрика   ${ISXDP}  ${D}(может врать на bnxt — не доверять в одиночку)${C}"
say "  rx_dropped       ${RXDROP}"
say ""
hdr "── ВЕРДИКТ ─────────────────────────────────────────────────────"
if [ "$VERDICT" -eq 0 ]; then
    say "  ${G}✅ AF_XDP РАБОТАЕТ${C}"
    say "  Режим: ${MODE}"
else
    if [ -z "$VPID" ]; then
        say "  ${Y}⚠ Валидатор не запущен — проверка невозможна${C}"
        say "  Запусти валидатор и повтори. Индикаторы UMEM/socket появляются"
        say "  только когда retransmit-stage вышла на режим (после catchup)."
    else
        say "  ${R}❌ AF_XDP НЕ АКТИВЕН (fallback на kernel UDP)${C}"
        say "  Режим: ${MODE}"
        say ""
        say "  Возможные причины:"
        say "    • валидатор ещё в rebuild/catchup (подожди ~5 мин, повтори)"
        say "    • драйвер не поддерживает AF_XDP (Realtek r8169, tg3 — не умеют)"
        say "    • нет --xdp-interface в jito.service"
        say "    • HugePages не выделены (нужны для UMEM)"
    fi
fi
say "═══════════════════════════════════════════════════════════════"

exit $VERDICT
