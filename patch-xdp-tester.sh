#!/usr/bin/env bash
# patch-xdp-tester.sh — обновляет xdp-tester.sh под Agave 4.1.
#
# Старый xdp-tester.sh в секции ВЕРДИКТ печатает рекомендованные флаги
# в формате Agave 4.0 (--experimental-retransmit-xdp-*). В Agave 4.1 это
# переименовано в --xdp-*, а --experimental-poh-pinned-cpu-core удалён.
# Скрипт правит эти строки на месте (с бэкапом).
#
# Использование:
#   bash patch-xdp-tester.sh [путь_к_xdp-tester.sh]
# По умолчанию ищет ./xdp-tester.sh

set -euo pipefail

TARGET="${1:-./xdp-tester.sh}"

if [ ! -f "$TARGET" ]; then
    echo "[!!] Не найден $TARGET" >&2
    echo "     Укажи путь: bash patch-xdp-tester.sh /root/xdp-installer/xdp-tester.sh" >&2
    exit 1
fi

# Бэкап
BACKUP="${TARGET}.bak.$(date +%Y%m%d-%H%M%S)"
cp -a "$TARGET" "$BACKUP"
echo "[..] Backup: $BACKUP"

# --- Замены флагов в выводе вердикта -----------------------------------------
# 1) experimental-retransmit-xdp-interface  → xdp-interface
# 2) experimental-retransmit-xdp-cpu-cores  → xdp-cpu-cores
# 3) experimental-retransmit-xdp-zero-copy  → xdp-zero-copy
# 4) строки с --experimental-poh-pinned-cpu-core удаляем (флаг removed в 4.1)
sed -i \
    -e 's|--experimental-retransmit-xdp-interface|--xdp-interface|g' \
    -e 's|--experimental-retransmit-xdp-cpu-cores|--xdp-cpu-cores|g' \
    -e 's|--experimental-retransmit-xdp-zero-copy|--xdp-zero-copy|g' \
    -e '/--experimental-poh-pinned-cpu-core/d' \
    "$TARGET"

echo "[OK] Флаги обновлены под Agave 4.1"
echo
echo "=== Diff (что изменилось) ==="
diff "$BACKUP" "$TARGET" || true
echo
echo "=== Проверка: остались ли старые experimental-флаги? ==="
if grep -q "experimental-retransmit-xdp\|experimental-poh-pinned" "$TARGET"; then
    echo "[WW] Ещё остались упоминания — проверь вручную:"
    grep -n "experimental" "$TARGET" || true
else
    echo "[OK] Старых experimental-флагов не осталось."
fi
echo
echo "[OK] Готово. Если что-то не так — откат: cp $BACKUP $TARGET"
