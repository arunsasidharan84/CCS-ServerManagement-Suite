# CCS Server Management Suite

A centralized toolset for managing high-performance neuroimaging research servers (MATLAB, Python, VNC, and NAS Mounts).

## Features
- **Mount Management**: Robust bind-mounting for NAS shares with automated health checks.
- **Performance Watchdog**: Automatic detection and restoration of stacked or broken mounts.
- **VNC Orchestration**: Multi-user VNC session management with resource locking.
- **Conda Optimization**: Bulk environment thread-limiting for OpenBLAS/MKL.

## Security & Configuration
This repository uses an external configuration pattern to ensure laboratory-specific credentials (IPs, paths) are never leaked.

1. Copy `ccs.conf.template` to `/etc/ccs/ccs.conf` on your server.
2. Update the variables in `/etc/ccs/ccs.conf` with your lab's infrastructure details.
3. The `ccs.sh` script will automatically source this file at startup.

## Installation
1. Move `ccs.sh` to `/usr/local/bin/ccs`.
2. Ensure it is executable: `chmod +x /usr/local/bin/ccs`.
3. Set up the configuration at `/etc/ccs/ccs.conf`.

---
*Note: This is a private repository for CCS Lab and collaborators.*
