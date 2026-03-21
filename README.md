# Ubuntu VM Provisioning Script

A simple interactive script to quickly provision a fresh Ubuntu VM with common developer tooling and basic system configuration.

## ✨ Features

This script automates:

### System Configuration
- 🔹 Change hostname (interactive)
- 🔹 Configure static IP using Netplan
- 🔹 Preserve or override gateway and DNS

### Optional Software Installation
- 📦 nvm (Node Version Manager)
- 🟢 Latest Node.js LTS (via nvm)
- 🐟 Fish shell
- 🎨 Oh My Posh
- ⚡ Oh My Posh Atomic theme (for Fish)

---

## 📦 Requirements

- Ubuntu (tested on Ubuntu Server 20.04+ / 22.04+)
- Root or sudo access
- Internet connection

---

## 🚀 Usage

### 1. Clone the repo

```bash
git clone https://github.com/your-username/ubuntu-vm-provisioner.git
cd ubuntu-vm-provisioner