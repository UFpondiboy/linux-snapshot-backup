# Snapshot Backup (Engine v5.1)

A lightweight, hardened snapshot-based backup system for Linux, built on `rsync` and hard links.

Each backup appears as a complete, independent copy of your files, while unchanged files are shared between snapshots using hard links. This gives you Time Machine–style versioned backups without duplicating unchanged data on disk.

Built and tested on KDE Plasma / udisks2 automount setups, with fallback support for other Linux desktop environments.

> **What "snapshot" means in this project**
>
> This project creates **directory-based snapshots** using `rsync` and hard links.
> It does **not** create filesystem snapshots such as **Btrfs**, **ZFS**, or **LVM** snapshots.
>
> Every snapshot is an ordinary directory that can be browsed, searched, copied, and restored using standard Linux file tools — no special restore utility, database, or proprietary format is required.

---

## Design Goals

This project intentionally prioritizes **reliability, simplicity, and long-term recoverability** over feature count.

The guiding principles are:

- **Single self-contained Bash script** — no helper scripts, libraries, or installation process.
- **Human-readable backups** — every snapshot is a normal directory that can be browsed with any file manager.
- **Simple restores** — recover files using standard Linux tools such as `cp`, `rsync`, or your preferred file manager.
- **No proprietary formats** — backups remain usable even if this project is no longer available.
- **Fail safely** — if the script cannot verify that a snapshot completed correctly, it refuses to mark it as complete.
- **Integrity first** — completed snapshots include SHA-256 manifests and multiple verification stages to help detect corruption.
- **Portable by design** — depends only on standard Linux utilities available on virtually every distribution.
- **No cloud services, databases, daemons, or background processes** — the script performs its work and exits.

The philosophy is simple:

> **If this script disappeared tomorrow, every backup it created should still be completely usable with standard Linux filesystem tools.**

---

## Table of Contents

- [Quick Start](#quick-start)
- [Features](#features)
- [Non-Goals](#non-goals)
- [Requirements](#requirements)
- [Filesystem Support](#filesystem-support)
- [How It Works](#how-it-works)
- [Usage](#usage)
- [Restoring Files](#restoring-files)
- [Snapshot Verification](#snapshot-verification)
- [Configuration](#configuration)
- [.backupignore Support](#backupignore-support)
- [Retention](#retention)
- [Security & Privacy](#security--privacy)
- [Known Limitations](#known-limitations)
- [Example Output](#example-output)
- [Design Philosophy](#design-philosophy)
- [License](#license)
- [Disclaimer](#disclaimer)

---

## Quick Start
