# Logos File Sharing

Upload, download and remove files over Logos Storage (`logos-storage-module`) from [Logos Basecamp](https://logos.co). Uploads return a CID, and anyone on the same storage network can fetch the file by that CID.

> [!WARNING]
> **Work in progress.** The module builds and installs, but end-to-end upload/download doesn't work on macOS Basecamp yet because of upstream bugs at the `storage_module` ↔ `logos_host` boundary. The comment block in [`filesharing-core/flake.nix`](filesharing-core/flake.nix) has the details. The same code is reported to work on Linux.

## Quick start

Download `filesharing-core` and `filesharing-ui` `.lgx` files from [Releases](https://github.com/hackyguru/logos-filesharing/releases). `storage_module` must be installed first (see [Install](#install)). To build them yourself, read on.

## Prerequisites

- [Nix](https://nixos.org/download/) with flakes enabled (`experimental-features = nix-command flakes` in `~/.config/nix/nix.conf`)
- [Logos Basecamp](https://github.com/logos-co/logos-basecamp/releases)

## What's here

- [`filesharing-core/`](filesharing-core/): `core` module (C++) that wraps `storage_module`'s typed `StorageModule` client, exposes `startStorage` / `uploadFile` / `downloadFile` / `removeFile` / `listFiles`, and subscribes to `storageStart` / `storageUploadDone` / `storageDownloadDone` events.
- [`filesharing-ui/`](filesharing-ui/): `ui_qml` module (QML) with a start button, an upload area (paste a path or drag a file), a download form and a "My files" list.

The comments at the top of [`filesharing_plugin.cpp`](filesharing-core/src/filesharing_plugin.cpp) cover the integration rules: the typed wrapper versus raw IPC, main-thread dispatch with `QTimer::singleShot(0, ...)`, and re-entrancy guards on polls.

## Build

```bash
cd filesharing-core
nix flake update        # first time only
nix build '.#lgx-portable' --out-link result-portable

cd ../filesharing-ui
nix build --override-input filesharing path:../filesharing-core '.#lgx-portable' --out-link result-portable
```

The first build pulls `logos-storage-module` (libstorage, Nim), which takes a while.

## Install

`storage_module` is **not** pre-installed in Basecamp, so install it once first:

```bash
nix build github:logos-co/logos-storage-module --out-link /tmp/storage
cp /tmp/storage/lib/* "$HOME/Library/Application Support/Logos/LogosBasecamp/modules/"
# Linux: "$HOME/.local/share/Logos/LogosBasecamp/modules/"
```

Restart Basecamp, then install `filesharing-core` and then `filesharing-ui` (`result-portable/*.lgx`) through **Modules → Install LGX Package**.
