#!/usr/bin/env bash
# apply-xdp-caps.sh
# Выставляет XDP-capabilities (cap_net_raw, cap_net_admin, cap_bpf, cap_perfmon)
# на текущий бинарник agave-validator.
#
# Запускать ПОСЛЕ каждого обновления Jito-Solana (после переключения active_release),
# но ДО systemctl restart валидатора.
#
# Использование:
#   sudo bash apply-xdp-caps.sh         # применить capabilities
#   sudo bash apply-xdp-caps.sh verify  # показать текущие capabilities (без правок)

set -euo pipefail

# Каноничный путь к бинарнику через active_release (symlink)
ACTIVE_LINK="/root/.local/share/solana/install/active_release/bin/agave-validator"

# Capabilities, требуемые для XDP по гайду Anza
CAPS="cap_net_raw,cap_net_admin,cap_bpf,cap_perfmon=p"

# ---------- helpers ----------------------------------------------------------
GREEN=$'\033[32m'; RED=$'\033[31m'; YELLOW=$'\033[33m'; BLUE=$'\033[34m'; CLEAR=$'\033[0m'
ok()    { echo "${GREEN}[OK]${CLEAR} $*"; }
info()  { echo "${BLUE}[..]${CLEAR} $*"; }
warn()  { echo "${YELLOW}[WW]${CLEAR} $*"; }
err()   { echo "${RED}[!!]${CLEAR} $*" >&2; }

# ---------- checks -----------------------------------------------------------
[ "$EUID" -eq 0 ] || { err "Run as root (sudo)"; exit 1; }

command -v setcap  >/dev/null || { err "'setcap' not found. apt install libcap2-bin"; exit 1; }
command -v getcap  >/dev/null || { err "'getcap' not found. apt install libcap2-bin"; exit 1; }

if [ ! -L "$ACTIVE_LINK" ] && [ ! -e "$ACTIVE_LINK" ]; then
    err "Active release not found at $ACTIVE_LINK"
    err "Run your Jito-Solana installer first."
    exit 1
fi

# Резолвим симлинк до реального файла. setcap работает на inode,
# поэтому ставим cap-ы на реальный путь, а не на симлинк.
REAL_BIN="$(readlink -f "$ACTIVE_LINK")"

if [ ! -x "$REAL_BIN" ]; then
    err "Resolved binary is not executable: $REAL_BIN"
    exit 1
fi

# ---------- verify mode ------------------------------------------------------
if [ "${1:-}" = "verify" ]; then
    info "Active release link: $ACTIVE_LINK"
    info "Real binary path:    $REAL_BIN"
    echo
    info "Current capabilities:"
    getcap "$REAL_BIN" || true
    echo
    info "Version:"
    "$REAL_BIN" --version || true
    exit 0
fi

# ---------- apply ------------------------------------------------------------
info "Active release link: $ACTIVE_LINK"
info "Real binary path:    $REAL_BIN"

# Покажем что было
CURRENT_CAPS="$(getcap "$REAL_BIN" 2>/dev/null || true)"
if [ -n "$CURRENT_CAPS" ]; then
    info "Previous caps: $CURRENT_CAPS"
else
    info "Previous caps: <none>"
fi

# Применяем
setcap "$CAPS" "$REAL_BIN"
ok "setcap applied: $CAPS"

# Проверяем что встало
NEW_CAPS="$(getcap "$REAL_BIN" 2>/dev/null || true)"
if echo "$NEW_CAPS" | grep -q "cap_net_admin"; then
    ok "Verified: $NEW_CAPS"
else
    err "Capabilities NOT applied correctly. Got: $NEW_CAPS"
    exit 1
fi

echo
warn "Capabilities are stored on the binary INODE."
warn "After ANY Jito-Solana upgrade or active_release switch — RE-RUN THIS SCRIPT."
echo
ok "Done. Don't forget to restart the validator service in a safe window."
