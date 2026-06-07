# xdp-installer

Toolkit for rolling out AF_XDP across a Solana / Jito validator fleet.

## Scripts

- `xdp-tester.sh` — two-phase XDP readiness check (hardware grade + real UDP roundtrip)
- `xdp-install.sh` — incrementally edits `jito.service` to apply XDP flags, capabilities, hugepages
- `audit-install.sh` — installs `solana-status` (live dashboard) and `solana-audit` (12-section Anza canon audit) to `/usr/local/sbin/`
- `apply-xdp-caps.sh` — applies XDP-related kernel capabilities
- `solana-status.sh` — live validator status dashboard

## Tested on

- Ubuntu 24.04 LTS
- Kernel 6.17 / 7.0 (HWE)
- Agave / Jito-Solana 4.0.1+

## Driver compatibility (AF_XDP)

| Driver       | Native XDP | Zero-copy |
|--------------|------------|-----------|
| ixgbe        | yes        | yes       |
| i40e         | yes        | yes       |
| igb          | yes        | yes (kernel 6.14+) |
| ice          | yes        | yes       |
| mlx5_core    | yes        | yes       |
| bnxt_en      | yes        | no (Anza forbidden) |
| r8169/r8125  | no         | no        |
