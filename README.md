<div align="center">

<img src="filesharing-ui/icons/filesharing.png" alt="Logos File Sharing logo" width="128" height="128">

# Logos File Sharing

</div>

Upload, download and remove files over Logos Storage (`logos-storage-module`) from [Logos Basecamp](https://logos.co). Uploads return a CID, and anyone on the same storage network can fetch the file by that CID.

> [!NOTE]
> Works on Basecamp 0.3, which bundles `storage_module` and starts its storage node at launch. `filesharing-ui` uses that node directly; tested end to end (upload → CID → download) on macOS Basecamp 0.3.2.

## Quick start

Download `filesharing-core` and `filesharing-ui` `.lgx` files from [Releases](https://github.com/hackyguru/logos-filesharing/releases). `filesharing-ui` talks to `storage_module` directly, and Basecamp 0.3 ships it, so `filesharing-ui` is all you need. To build it yourself, read on.

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

Basecamp 0.3 bundles `storage_module`, so there's nothing to set up first. Install `filesharing-ui` (`result-portable/*.lgx`) through **Package Manager → Install Local Package**.
