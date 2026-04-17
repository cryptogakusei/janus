# Mesh Network: Archer A7 OpenWrt + B.A.T.M.A.N. Setup

## Goal

Build a mesh network for Janus using OpenWrt routers running B.A.T.M.A.N. (`batman-adv`).

## Context

- **GL.iNet Opal** is already running but does not support `batman-adv`
- **TP-Link Archer A7 v5.8** acquired as the target OpenWrt node
- Plan: flash OpenWrt on one Archer A7, verify `batman-adv` works, then scale to multiple routers

## Current State (2026-04-17)

Attempted to flash OpenWrt on the Archer A7. Flash did not complete successfully. Router is now stuck — power LED was blinking (space shuttle/TP-Link logo), later settled to solid power light only after a reset button recovery attempt.

The router is **not bricked** — the bootloader is intact and the solid power light indicates it has booted into something (likely recovery mode).

## Recovery Plan

### What You Need

- **USB-C to ethernet adapter** (ordered, pending delivery) — required because MacBook has no built-in ethernet port
- **Ethernet cable** (already have)
- **OpenWrt factory image** for Archer A7 v5 (already downloaded)

### Recovery Steps (once adapter arrives)

1. Connect USB-C ethernet adapter to Mac
2. Plug ethernet cable from Mac into **Archer A7 LAN port 1** (the port labeled "1", closest to the WAN port — NOT the single WAN port)
3. Set static IP on Mac:
   - System Settings → Network → Ethernet → Details → TCP/IP
   - Configure IPv4: **Manually**
   - IP Address: `192.168.0.225`
   - Subnet Mask: `255.255.255.0`
   - Router: `192.168.0.1`
4. Try web recovery first — open browser at `http://192.168.0.1`
   - If a firmware upload page appears, upload the OpenWrt `factory.bin` directly
5. If no web page, use TFTP from Terminal:
   ```bash
   ping 192.168.0.1          # confirm router is reachable
   tftp 192.168.0.1
   put ArcherA7v5_factory.bin
   ```
6. If still no response, trigger TFTP recovery mode manually:
   - Unplug power from Archer A7
   - Hold reset button (small pinhole on back)
   - Plug power back in while holding reset
   - Hold for 8-10 seconds, then release
   - Retry ping/TFTP immediately

### Important Notes

- Always use a **LAN port** (group of 4), never the WAN port (single port) — the WAN port does not respond in recovery mode
- Use the **factory.bin** image (not sysupgrade.bin) for first flash from recovery
- The USB port on the Archer A7 is for USB storage only — cannot be used for network recovery

## After Recovery: Install OpenWrt

1. Flash OpenWrt factory image via web UI or TFTP recovery
2. Verify OpenWrt boots — router should be accessible at `192.168.1.1` (OpenWrt default)
3. SSH in: `ssh root@192.168.1.1`
4. Install `batman-adv`:
   ```bash
   opkg update
   opkg install kmod-batman-adv batctl
   ```
5. Verify `batman-adv` loads:
   ```bash
   modprobe batman-adv
   batctl -v
   ```

## After Single-Node Verification: Mesh Build

Once one Archer A7 is running OpenWrt + `batman-adv`, replicate to additional routers and configure the mesh:
- Each node runs `batman-adv` on a wireless interface in ad-hoc mode
- Nodes discover each other and route automatically
- Janus provider/client nodes communicate over the mesh without a central router

## Troubleshooting Notes from Session

| Attempt | Result |
|---------|--------|
| Opal bridge via `eth0` | No ARP response — wrong interface (VLAN) |
| Opal bridge via `eth0.2` | No ARP response — VLAN tagging may confuse A7 bootloader |
| Reset button recovery | LED changed from blinking logo → solid power only |
| Direct Mac connection | Blocked by missing USB-C ethernet adapter |

The Opal bridge approach (SSH into Opal, run TFTP from there) hit complications because the Opal's WAN port uses VLAN-tagged ethernet (`eth0.2`), which the Archer A7 bootloader may not understand. Direct Mac connection is the cleaner path.
