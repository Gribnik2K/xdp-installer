# xdp-installer

Инструменты для развёртывания, настройки и **достоверной проверки** AF_XDP на Solana / Jito-валидаторах (Agave 4.1+).

Набор отработан на гетерогенном парке: Intel (ixgbe X550, igb i210) и Broadcom (bnxt_en BCM57416), ядра 6.17 и 7.0, Ubuntu 24.04 LTS.

---

## TL;DR — как проверить работает ли XDP

```bash
sudo bash xdp-detect.sh
```

Скрипт даёт **однозначный вердикт** для любого драйвера. Не полагайся на `is_xdp=true` в логах валидатора и на `ip link ... prog/xdp` — на bnxt_en они вводят в заблуждение (см. ниже).

---

## Скрипты

| Скрипт | Назначение | Когда запускать |
|---|---|---|
| **`xdp-detect.sh`** | Runtime-проверка: реально ли активен AF_XDP у работающего валидатора. Однозначный вердикт. | После старта валидатора (когда вышел на режим) |
| `xdp-tester.sh` | Pre-flight: потянет ли железо/ядро AF_XDP. Детект NIC, драйвера, ring, kernel, UDP-roundtrip. | До настройки XDP, при выборе/диагностике железа |
| `xdp-install.sh` | Установка/настройка XDP-окружения (hugepages, ring buffers, флаги). | При первичном развёртывании |
| `apply-xdp-caps.sh` | setcap для **ручного** запуска `agave-xdp-compatibility` тестера. Валидатору через systemd НЕ нужен (есть AmbientCapabilities в unit). | Только перед ручным прогоном Anza-тестера |
| `audit-install.sh` | Аудит конфигурации ноды. | Периодически / при отладке |
| `solana-status.sh` | Сводный статус валидатора (версия, синк, голос, кредиты). | Мониторинг |

---

## Как ПРАВИЛЬНО проверять AF_XDP

Метрика `is_xdp=true` в логах валидатора означает лишь, что **флаг `--xdp-interface` принят**. Она **НЕ гарантирует**, что AF_XDP реально работает — при тихом fallback на kernel UDP метрика всё равно показывает `true`. Это известный false-positive, особенно на bnxt_en.

`ip -d link show <iface> | grep prog/xdp` показывает XDP-программу **только на Intel** (ixgbe/igb) — там attach в DRV mode. На **bnxt_en программа не отображается в `ip link`**, хотя AF_XDP функционирует через XSK-сокет. Отсутствие `prog/xdp` на bnxt — НЕ признак поломки.

### Достоверные индикаторы (работают для любого драйвера)

| # | Индикатор | Команда | Признак работы |
|---|---|---|---|
| 1 | **UMEM** | `grep HugePages_Free /proc/meminfo` | `Free < Total` → валидатор взял память под UMEM → AF_XDP socket создан |
| 2 | **Socket** | `ss -f xdp` | строка `<iface>:qN` → AF_XDP сокет забиндён на queue |
| 3 | prog/xdp (Intel only) | `ip -d link show <iface>` | `prog/xdp id NN name agave_xdp` — бонус, только Intel |

**Вердикт: AF_XDP работает, если выполнены (1) И (2).** Пункт (3) — дополнительный для Intel; его отсутствие на bnxt не считается провалом.

### Anza compatibility tester — нюанс интерпретации

`agave-xdp-compatibility` (https://github.com/anza-xyz/agave-xdp-compatibility) при запущенном валидаторе **падает** — и это нормально:

- `panic: failed to create AF_XDP socket on queue QueueId(0)` **при взятом UMEM** (HugePages_Free < Total) → queue 0 уже занята валидатором → **AF_XDP РАБОТАЕТ**.
- тот же panic **при UMEM = 0** (HugePages_Free == Total) → сокет реально не создаётся → **fallback / не работает**.

Различить можно только по HugePages. Сам по себе panic ничего не доказывает.

---

## Поддержка AF_XDP по драйверам (проверено на парке)

| NIC | Driver | AF_XDP | Режим | Примечание |
|---|---|---|---|---|
| Intel X550 | ixgbe | ✅ | zero-copy | `--xdp-zero-copy` разрешён |
| Intel i210 | igb | ✅ | zero-copy | kernel ≥ 6.14; `--xdp-zero-copy` ок |
| Broadcom BCM57416 | bnxt_en | ✅ | **native** | zero-copy ЗАПРЕЩЁН Anza; prog/xdp не виден в ip link, но работает |
| Realtek RTL8125 | r8169 | ❌ | — | нет `ndo_xsk_wakeup` в upstream, не лечится ядром |
| Broadcom BCM5719 | tg3 | ❌ | — | нет AF_XDP в драйвере |

**Native AF_XDP — это полноценный XDP** (bypass kernel network stack, снижение CPU на retransmit). Zero-copy даёт дополнительный выигрыш (~10-15%), но требует поддержки драйвера. На bnxt доступен только native — и этого достаточно для рабочего ускорения.

---

## Ключевые флаги jito.service (Agave 4.1+)

```
--xdp-interface <iface>      # обязателен; включает AF_XDP retransmit
--xdp-cpu-cores <N>          # ядро(а) под XDP TX loop
--xdp-zero-copy              # ТОЛЬКО Intel (ixgbe/igb/ice); НЕ для bnxt_en
```

Изменения при переходе с Agave 4.0 → 4.1:
- `--experimental-retransmit-xdp-interface` → `--xdp-interface`
- `--experimental-retransmit-xdp-cpu-cores` → `--xdp-cpu-cores`
- `--experimental-retransmit-xdp-zero-copy` → `--xdp-zero-copy`
- `--experimental-poh-pinned-cpu-core` → **удалён** (agave распределяет PoH сам)
- `--block-production-method central-scheduler` → `central-scheduler-greedy`

Capabilities в unit (через systemd, setcap не нужен):
```
CapabilityBoundingSet=CAP_NET_RAW CAP_NET_ADMIN CAP_BPF CAP_PERFMON
AmbientCapabilities=CAP_NET_RAW CAP_NET_ADMIN CAP_BPF CAP_PERFMON
```

HugePages под UMEM (пример — 1024 страницы = 2 GB):
```
echo 1024 > /proc/sys/vm/nr_hugepages
```

---

## Лицензия

Личный набор инструментов для администрирования собственного валидаторского парка. Используйте на свой риск.
