# Ubuntu VM Provisioning Script

Interactive provisioning script for fresh Ubuntu VMs.

It configures core system settings (hostname + static networking) and can install optional developer tooling in one guided run.

## Features

### System preflight
- Runs `apt-get update`
- Runs `apt-get upgrade -y` (non-interactive)
- Warns if reboot is recommended (`/var/run/reboot-required`)

### System configuration
- Change hostname (interactive)
- Configure static IPv4 with Netplan
- Auto-detect current gateway and DNS, with optional overrides
- Backup existing Netplan YAML before writing new config
- Validate config with `netplan generate` before apply

### Optional software
- `nvm` (for the invoking sudo user)
- Latest Node.js LTS via `nvm`
- `fish` shell
- `oh-my-posh`
- `oh-my-posh` atomic theme for `fish`

### UX and safety improvements
- Colored prompts and example input hints (when terminal supports color)
- Strict IPv4/CIDR validation
- Explicit error handling around key provisioning steps

## Requirements

- Ubuntu Server/Desktop (20.04+ recommended)
- Root or `sudo` access
- Internet access

## Usage

### 1) Get the script

If you already have this repo:

```bash
cd /path/to/provision-ubuntu-vm
```

Or clone it:

```bash
git clone <your-repo-url>
cd provision-ubuntu-vm
```

### 2) Make executable

```bash
chmod +x provision-ubuntu-vm.sh
```

### 3) Run with sudo

```bash
sudo ./provision-ubuntu-vm.sh
```

The script is interactive and will ask for:
- New hostname
- Network interface + static CIDR
- Gateway/DNS override choices
- Optional installs (`nvm`, Node LTS, `fish`, `oh-my-posh`, atomic theme)

## What gets changed

- Hostname via `hostnamectl`
- `/etc/hosts` entry for `127.0.1.1`
- Netplan file: `/etc/netplan/99-custom-static.yaml`
- Netplan backup directory: `/etc/netplan/backup-<timestamp>/`
- User shell config files (when optional tools are selected), such as:
  - `~/.bashrc`
  - `~/.config/fish/config.fish`
  - `~/.poshthemes/atomic.omp.json`

## After provisioning

Open a new terminal session (or log out/in if default shell changed), then verify:

```bash
hostnamectl
ip addr
fish --version
oh-my-posh version
bash -lc 'source ~/.bashrc && command -v nvm && node -v'
```

## Notes

- The script targets the original sudo user for per-user installs (`SUDO_USER`).
- If colors are not desired, run with `NO_COLOR=1`:

```bash
sudo NO_COLOR=1 ./provision-ubuntu-vm.sh
```
