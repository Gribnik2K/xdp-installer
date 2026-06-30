#!/usr/bin/env bash
# xdp-tester.sh
# Двухфазная проверка готовности ноды к XDP (Agave/Jito-Solana):
#   ФАЗА A — статический детект железа (драйвер, ring, queues, kernel, NUMA, agave)
#   ФАЗА B — реальный UDP roundtrip-тест к публичному DNS (1.1.1.1 и/или 8.8.8.8)
#            подтверждает что сетевой путь через NIC реально гоняет UDP в обе стороны
#
# Меню при запуске:
#   1) Тест к 1.1.1.1 (Cloudflare)
#   2) Тест к 8.8.8.8 (Google)
#   3) Оба + сводный вердикт о режиме работы XDP
#
# Неинтерактивный запуск:
#   xdp-tester.sh --target 1.1.1.1
#   xdp-tester.sh --both
#   xdp-tester.sh --hw-only          # только детект железа, без сетевого теста
#
# Репозиторий: github.com/Gribnik2K/Checker

set -u

# ============================================================================
# Цвета
# ============================================================================
if [ -t 1 ]; then
    G=$'\033[32m'; R=$'\033[31m'; Y=$'\033[33m'; B=$'\033[34m'
    M=$'\033[35m'; C=$'\033[36m'; D=$'\033[2m'; N=$'\033[0m'; BO=$'\033[1m'
else
    G=""; R=""; Y=""; B=""; M=""; C=""; D=""; N=""; BO=""
fi

ok()   { printf "  ${G}✔${N} %s\n" "$1"; }
warn() { printf "  ${Y}⚠${N} %s\n" "$1"; }
bad()  { printf "  ${R}✘${N} %s\n" "$1"; }
info() { printf "  ${B}ℹ${N} %s\n" "$1"; }
kv()   { printf "  ${D}%-24s${N} %s\n" "$1" "$2"; }
hdr()  { echo; printf "${BO}${C}▌ %s${N}\n" "$1"; printf "${D}──────────────────────────────────────────────────────────────────────${N}\n"; }

# ============================================================================
# Парсинг аргументов
# ============================================================================
MODE=""           # interactive | target | both | hw-only
TARGET=""
for arg in "$@"; do
    case "$arg" in
        --both)     MODE="both" ;;
        --hw-only)  MODE="hw-only" ;;
        --target)   MODE="target" ;;
        1.1.1.1|8.8.8.8) TARGET="$arg" ;;
        --target=*) MODE="target"; TARGET="${arg#--target=}" ;;
        -h|--help)  sed -n '2,22p' "$0"; exit 0 ;;
    esac
done

echo
echo "##########################################################################"
echo "########## OUTPUT BELOW — copy from here when pasting back ###############"
echo "##########################################################################"
echo

printf "${BO}${M}═══════════════════════════════════════════════════════════════════════${N}\n"
printf "${BO}${M}  XDP TESTER — $(hostname) — $(date '+%Y-%m-%d %H:%M:%S')${N}\n"
printf "${BO}${M}═══════════════════════════════════════════════════════════════════════${N}\n"

# ============================================================================
# ФАЗА A — ДЕТЕКТ ЖЕЛЕЗА
# ============================================================================
DEFIFACE=$(ip route show default 2>/dev/null | awk '/default/ {print $5; exit}')
if [ -z "$DEFIFACE" ]; then
    bad "Не нашёл default route — нечего тестировать"
    exit 1
fi

xdp_grade() {
    case "$1" in
        mlx5_core) echo "A+|Mellanox ConnectX-4/5/6 — эталонный native XDP, zero-copy полностью" ;;
        mlx4_core) echo "A|Mellanox ConnectX-3 — native XDP" ;;
        ice)       echo "A+|Intel E810 (100G) — native XDP_DRV + zero-copy" ;;
        i40e)      echo "A|Intel X710/XL710 — native XDP, рекомендован Anza" ;;
        ixgbe)     echo "A-|Intel 82599/X550 (10G) — native XDP, классика" ;;
        igb)       echo "C|Intel I210/I350 (1G) — generic mode only" ;;
        igc)       echo "C|Intel I225/I226 (2.5G) — generic XDP" ;;
        bnxt_en)   echo "B|Broadcom NetXtreme-E — native XDP, БЕЗ --xdp-zero-copy" ;;
        sfc)       echo "A|Solarflare — native XDP" ;;
        nfp)       echo "A|Netronome Agilio — native XDP с hardware offload" ;;
        r8169|r8125) echo "D|Realtek — generic mode only, профита ~0" ;;
        virtio_net) echo "C-|Виртуальная карта — generic XDP only" ;;
        vmxnet3)   echo "C-|VMware — generic XDP" ;;
        e1000|e1000e) echo "D|Старый Intel 1G — generic mode only" ;;
        tg3)       echo "D|Старый Broadcom — generic mode only" ;;
        *)         echo "?|Драйвер '$1' не в списке — проверь '<drv> xdp native support'" ;;
    esac
}

hdr "ФАЗА A — ДЕТЕКТ ЖЕЛЕЗА"

kv "Interface" "$DEFIFACE"
DRIVER=$(ethtool -i "$DEFIFACE" 2>/dev/null | awk -F': ' '/^driver:/ {print $2}' | tr -d ' \r\n')
DRV_VER=$(ethtool -i "$DEFIFACE" 2>/dev/null | awk -F': ' '/^version:/ {print $2}')
FW_VER=$(ethtool -i "$DEFIFACE" 2>/dev/null | awk -F': ' '/^firmware-version:/ {print $2}')
[ -z "$DRIVER" ] && { bad "ethtool -i не работает на $DEFIFACE"; exit 1; }
kv "Driver" "$DRIVER"
kv "Driver version" "$DRV_VER"
kv "Firmware" "$FW_VER"
LINK_SPEED=$(ethtool "$DEFIFACE" 2>/dev/null | awk -F': ' '/Speed:/ {print $2}' | tr -d ' \r\n')
kv "Link speed" "${LINK_SPEED:-?}"

# Grade
RES=$(xdp_grade "$DRIVER")
GRADE="${RES%%|*}"; GCOMMENT="${RES#*|}"
echo
case "$GRADE" in
    "A+") printf "  ${G}${BO}GRADE: A+  ★★★★★${N}  %s\n" "$GCOMMENT" ;;
    "A")  printf "  ${G}${BO}GRADE: A   ★★★★☆${N}  %s\n" "$GCOMMENT" ;;
    "A-") printf "  ${G}GRADE: A-  ★★★★☆${N}  %s\n" "$GCOMMENT" ;;
    "B")  printf "  ${G}GRADE: B   ★★★☆☆${N}  %s\n" "$GCOMMENT" ;;
    "C")  printf "  ${Y}GRADE: C   ★★☆☆☆${N}  %s\n" "$GCOMMENT" ;;
    "C-") printf "  ${Y}GRADE: C-  ★★☆☆☆${N}  %s\n" "$GCOMMENT" ;;
    "D")  printf "  ${R}GRADE: D   ★☆☆☆☆${N}  %s\n" "$GCOMMENT" ;;
    *)    printf "  ${Y}GRADE: ?   ${N}  %s\n" "$GCOMMENT" ;;
esac

# Определяем ожидаемый РЕЖИМ XDP (native vs generic) по драйверу
case "$DRIVER" in
    mlx5_core|mlx4_core|ice|i40e|ixgbe|sfc|nfp) XDP_MODE="native" ;;
    bnxt_en)                                    XDP_MODE="native-no-zc" ;;
    igb|igc|virtio_net|vmxnet3|e1000|e1000e|tg3|r8169|r8125) XDP_MODE="generic" ;;
    *)                                          XDP_MODE="unknown" ;;
esac

# Ring buffers
echo
RING_OUT=$(ethtool -g "$DEFIFACE" 2>/dev/null)
RING_POW2="unknown"
if [ -n "$RING_OUT" ]; then
    MAX_RX=$(echo "$RING_OUT" | awk '/Pre-set maximums:/{f=1;next} f && /^RX:/ {print $2; exit}')
    CUR_RX=$(echo "$RING_OUT" | awk '/Current hardware settings:/{f=1;next} f && /^RX:/ {print $2; exit}')
    CUR_TX=$(echo "$RING_OUT" | awk '/Current hardware settings:/{f=1;next} f && /^TX:/ {print $2; exit}')
    kv "Ring RX/TX current" "${CUR_RX:-?} / ${CUR_TX:-?} (max RX=$MAX_RX)"
    is_pow2() { local n="$1"; [[ "$n" =~ ^[0-9]+$ ]] && [ "$n" -gt 0 ] && [ $((n & (n-1))) -eq 0 ] && echo yes || echo no; }
    if [ "$(is_pow2 "$CUR_RX")" = "yes" ] && [ "$(is_pow2 "$CUR_TX")" = "yes" ]; then
        RING_POW2="yes"; ok "ring power-of-2"
    else
        RING_POW2="no"
        suggest=512
        for s in 4096 2048 1024 512; do [ "${MAX_RX:-0}" -ge "$s" ] 2>/dev/null && { suggest=$s; break; }; done
        warn "ring НЕ power-of-2 → нужен: ethtool -G $DEFIFACE rx $suggest tx $suggest"
    fi
fi

# Multi-queue
CUR_CMB=$(ethtool -l "$DEFIFACE" 2>/dev/null | awk '/Current hardware settings:/{f=1;next} f && /^Combined:/ {print $2; exit}')
MAX_CMB=$(ethtool -l "$DEFIFACE" 2>/dev/null | awk '/Pre-set maximums:/{f=1;next} f && /^Combined:/ {print $2; exit}')
kv "Combined queues" "${CUR_CMB:-n/a} / ${MAX_CMB:-n/a}"

# Kernel
KVER=$(uname -r); KMAJ=$(echo "$KVER" | cut -d. -f1); KMIN=$(echo "$KVER" | cut -d. -f2)
kv "Kernel" "$KVER"
KERNEL_OK="no"
if [ "$KMAJ" -gt 5 ] || { [ "$KMAJ" -eq 5 ] && [ "$KMIN" -ge 3 ]; }; then
    KERNEL_OK="yes"; ok "kernel ≥ 5.3 (AF_XDP zero-copy support)"
elif [ "$KMAJ" -ge 4 ]; then
    KERNEL_OK="partial"; warn "kernel 4.x — XDP есть, zero-copy может не быть"
else
    bad "kernel слишком старый"
fi
[ -f /sys/kernel/btf/vmlinux ] && ok "BTF vmlinux present"

# CPU/NUMA
NCPU=$(nproc)
NNODES=$(lscpu | awk '/NUMA node\(s\):/ {print $3}')
kv "CPU / NUMA" "$NCPU cores / $NNODES nodes"
[ "${NNODES:-1}" -ge 2 ] && ok "2+ NUMA (Anza recommended)" \
                         || warn "1 NUMA — Anza советует ≥2 (не блокер)"

# Agave
AGAVE_OK="no"
if command -v agave-validator &>/dev/null; then
    VER=$(agave-validator --version 2>/dev/null | awk '{print $2}')
    kv "Agave version" "$VER"
    VM=$(echo "$VER" | cut -d. -f1); Vm=$(echo "$VER" | cut -d. -f2); Vp=$(echo "$VER" | cut -d. -f3 | grep -oE '^[0-9]+')
    if [ "${VM:-0}" -gt 3 ] 2>/dev/null \
       || { [ "${VM:-0}" -eq 3 ] && [ "${Vm:-0}" -gt 0 ]; } \
       || { [ "${VM:-0}" -eq 3 ] && [ "${Vm:-0}" -eq 0 ] && [ "${Vp:-0}" -ge 9 ]; }; then
        AGAVE_OK="yes"; ok "Agave ≥ 3.0.9 (XDP supported)"
    else
        bad "Agave < 3.0.9 — обнови"
    fi
else
    warn "agave-validator не в PATH (для теста железа не критично)"
fi

# ============================================================================
# Если только железо — выходим тут
# ============================================================================
if [ "$MODE" = "hw-only" ]; then
    hdr "ИТОГ (только железо)"
    kv "Driver" "$DRIVER"
    kv "Grade" "$GRADE"
    kv "Expected XDP mode" "$XDP_MODE"
    echo
    echo "##########################################################################"
    echo "########## END OF OUTPUT #################################################"
    echo "##########################################################################"
    exit 0
fi

# ============================================================================
# UDP ROUNDTRIP TEST — функция
# ============================================================================
# Шлёт реальный DNS-запрос (A-запись для solana.com) на UDP/53 указанного резолвера,
# измеряет успех и latency. Это проверяет полный сетевой путь TX→RX через NIC.
#
# Возвращает через глобалы: TEST_RESULT (pass/fail), TEST_LATENCY, TEST_DETAIL
udp_roundtrip_test() {
    local resolver="$1"
    TEST_RESULT="fail"; TEST_LATENCY=""; TEST_DETAIL=""

    # Метод 1: dig (самый чистый DNS-тест)
    if command -v dig &>/dev/null; then
        local out
        out=$(dig @"$resolver" solana.com +short +time=3 +tries=2 +stats 2>/dev/null)
        if [ -n "$out" ] && echo "$out" | grep -qE '^[0-9]+\.'; then
            # latency из +stats — строка "Query time: N msec"
            local qt
            qt=$(dig @"$resolver" solana.com +noall +stats +time=3 2>/dev/null | grep "Query time" | grep -oE '[0-9]+ msec' | grep -oE '[0-9]+')
            TEST_RESULT="pass"
            TEST_LATENCY="${qt:-?}"
            TEST_DETAIL="dig: получены A-записи ($(echo "$out" | head -1))"
            return 0
        fi
    fi

    # Метод 2: nslookup fallback
    if command -v nslookup &>/dev/null; then
        if timeout 5 nslookup solana.com "$resolver" 2>/dev/null | grep -qE 'Address: [0-9]'; then
            TEST_RESULT="pass"
            TEST_DETAIL="nslookup: ответ получен"
            return 0
        fi
    fi

    # Метод 3: ручной UDP через /dev/udp (bash) + python для DNS-payload
    if command -v python3 &>/dev/null; then
        local pyout
        pyout=$(timeout 5 python3 - "$resolver" <<'PYEOF' 2>/dev/null
import socket, struct, sys, time
resolver = sys.argv[1]
# Минимальный DNS-запрос A solana.com
tid = 0x1234
header = struct.pack('>HHHHHH', tid, 0x0100, 1, 0, 0, 0)
qname = b''.join(bytes([len(p)])+p.encode() for p in "solana.com".split('.')) + b'\x00'
question = qname + struct.pack('>HH', 1, 1)
packet = header + question
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.settimeout(3)
t0 = time.time()
try:
    s.sendto(packet, (resolver, 53))
    data, _ = s.recvfrom(512)
    dt = (time.time() - t0) * 1000
    if len(data) > 12 and data[:2] == struct.pack('>H', tid):
        print(f"PASS {dt:.1f}")
    else:
        print("FAIL bad-response")
except Exception as e:
    print(f"FAIL {e}")
PYEOF
)
        if echo "$pyout" | grep -q "^PASS"; then
            TEST_RESULT="pass"
            TEST_LATENCY=$(echo "$pyout" | awk '{print $2}')
            TEST_DETAIL="python UDP/53: DNS roundtrip OK"
            return 0
        else
            TEST_DETAIL="python UDP/53: $pyout"
        fi
    fi

    TEST_DETAIL="${TEST_DETAIL:-нет dig/nslookup/python3 или нет ответа}"
    return 1
}

# Обёртка с красивым выводом
run_target() {
    local resolver="$1" label="$2"
    hdr "ФАЗА B — UDP ROUNDTRIP → $label ($resolver)"

    # ICMP ping для baseline latency
    if command -v ping &>/dev/null; then
        local pavg
        pavg=$(ping -c 3 -W 2 -q "$resolver" 2>/dev/null | tail -1 | grep -oE '[0-9.]+/[0-9.]+/[0-9.]+' | cut -d/ -f2)
        [ -n "$pavg" ] && kv "ICMP ping avg" "${pavg} ms"
    fi

    udp_roundtrip_test "$resolver"
    if [ "$TEST_RESULT" = "pass" ]; then
        ok "UDP roundtrip PASS"
        [ -n "$TEST_LATENCY" ] && kv "UDP roundtrip latency" "${TEST_LATENCY} ms"
        kv "Detail" "$TEST_DETAIL"
        return 0
    else
        bad "UDP roundtrip FAIL"
        kv "Detail" "$TEST_DETAIL"
        return 1
    fi
}

# ============================================================================
# Меню если интерактивно
# ============================================================================
if [ -z "$MODE" ]; then
    echo
    printf "${BO}Выбери тест:${N}\n"
    printf "  ${C}1${N}) Тест к 1.1.1.1 (Cloudflare)\n"
    printf "  ${C}2${N}) Тест к 8.8.8.8 (Google)\n"
    printf "  ${C}3${N}) Оба + сводный вердикт о режиме XDP\n"
    printf "Выбор [1/2/3]: "
    read -r CHOICE
    case "$CHOICE" in
        1) MODE="target"; TARGET="1.1.1.1" ;;
        2) MODE="target"; TARGET="8.8.8.8" ;;
        3) MODE="both" ;;
        *) bad "Неверный выбор"; exit 1 ;;
    esac
fi

# ============================================================================
# Выполнение тестов
# ============================================================================
PASS_COUNT=0
TOTAL_COUNT=0
RES_CF="skip"; RES_GG="skip"
LAT_CF=""; LAT_GG=""

if [ "$MODE" = "target" ]; then
    case "$TARGET" in
        1.1.1.1) run_target "1.1.1.1" "Cloudflare" && { RES_CF="pass"; PASS_COUNT=1; } || RES_CF="fail"; LAT_CF="$TEST_LATENCY"; TOTAL_COUNT=1 ;;
        8.8.8.8) run_target "8.8.8.8" "Google" && { RES_GG="pass"; PASS_COUNT=1; } || RES_GG="fail"; LAT_GG="$TEST_LATENCY"; TOTAL_COUNT=1 ;;
        *) bad "Неизвестный target: $TARGET"; exit 1 ;;
    esac
elif [ "$MODE" = "both" ]; then
    run_target "1.1.1.1" "Cloudflare" && { RES_CF="pass"; PASS_COUNT=$((PASS_COUNT+1)); } || RES_CF="fail"; LAT_CF="$TEST_LATENCY"
    run_target "8.8.8.8" "Google"    && { RES_GG="pass"; PASS_COUNT=$((PASS_COUNT+1)); } || RES_GG="fail"; LAT_GG="$TEST_LATENCY"
    TOTAL_COUNT=2
fi

# ============================================================================
# СВОДНЫЙ ВЕРДИКТ
# ============================================================================
hdr "ВЕРДИКТ"

kv "NIC driver" "$DRIVER"
kv "Hardware grade" "$GRADE"
kv "Kernel ≥ 5.3" "$KERNEL_OK"
kv "Agave ≥ 3.0.9" "$AGAVE_OK"
[ "$MODE" = "both" ] && {
    kv "UDP → Cloudflare" "$RES_CF${LAT_CF:+ (${LAT_CF}ms)}"
    kv "UDP → Google" "$RES_GG${LAT_GG:+ (${LAT_GG}ms)}"
}
kv "Network test" "$PASS_COUNT/$TOTAL_COUNT passed"
echo

# Логика вердикта:
# 1. Железо должно быть не-D (иначе XDP бесполезен/не работает)
# 2. Kernel ≥ 5.3
# 3. Agave ≥ 3.0.9
# 4. Сетевой путь должен пройти хотя бы один тест (UDP реально летает)
NETWORK_OK="no"
[ "$PASS_COUNT" -gt 0 ] && NETWORK_OK="yes"

if [ "$GRADE" = "D" ]; then
    printf "  ${Y}${BO}XDP запустится в GENERIC mode — будет работать, но без выигрыша${N}\n"
    printf "  Драйвер %s не имеет native XDP. Реальной пользы почти нет.\n" "$DRIVER"
    VERDICT_MODE="generic (профит ~0)"
elif [ "$GRADE" = "?" ]; then
    printf "  ${Y}${BO}Драйвер неизвестен — режим XDP под вопросом${N}\n"
    VERDICT_MODE="unknown"
elif [ "$KERNEL_OK" = "no" ] || [ "$AGAVE_OK" = "no" ]; then
    printf "  ${R}${BO}XDP НЕ заработает — не выполнены базовые требования${N}\n"
    [ "$KERNEL_OK" = "no" ] && printf "    ${R}• kernel < 5.3${N}\n"
    [ "$AGAVE_OK" = "no" ]  && printf "    ${R}• agave < 3.0.9 или не установлен${N}\n"
    VERDICT_MODE="blocked"
elif [ "$NETWORK_OK" = "no" ] && [ "$MODE" != "hw-only" ]; then
    printf "  ${R}${BO}Железо готово, но СЕТЬ не прошла тест${N}\n"
    printf "  XDP-путь зависит от рабочего UDP в обе стороны. Проверь файрвол/маршруты.\n"
    VERDICT_MODE="network-issue"
else
    case "$XDP_MODE" in
        native)
            printf "  ${G}${BO}✔ XDP заработает в NATIVE mode + zero-copy${N}\n"
            printf "  Флаги: --xdp-interface %s \\\\\n" "$DEFIFACE"
            printf "         --xdp-cpu-cores <N> \\\\\n"
            printf "         --xdp-zero-copy \\\\\n"
            VERDICT_MODE="native + zero-copy"
            ;;
        native-no-zc)
            printf "  ${G}${BO}✔ XDP заработает в NATIVE mode (БЕЗ zero-copy)${N}\n"
            printf "  Broadcom bnxt_en: zero-copy ЗАПРЕЩЁН (Anza guide).\n"
            [ "$RING_POW2" = "no" ] && printf "  ${Y}Нужен ExecStartPre: ethtool -G %s rx 1024 tx 1024${N}\n" "$DEFIFACE"
            printf "  Флаги: --xdp-interface %s \\\\\n" "$DEFIFACE"
            printf "         --xdp-cpu-cores <N> \\\\\n"
            VERDICT_MODE="native (no zero-copy)"
            ;;
        generic)
            printf "  ${Y}${BO}XDP заработает в GENERIC mode — профит минимальный${N}\n"
            VERDICT_MODE="generic"
            ;;
        *)
            printf "  ${Y}${BO}Режим XDP под вопросом — драйвер неизвестен${N}\n"
            VERDICT_MODE="unknown"
            ;;
    esac
fi

echo
kv "РЕЖИМ XDP" "$VERDICT_MODE"

echo
echo "##########################################################################"
echo "########## END OF OUTPUT #################################################"
echo "##########################################################################"
