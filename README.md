# Typink

**Typink** is a professional-grade scientific notebook application that seamlessly integrates **Typst**'s powerful typesetting with stable **handwriting** and diagramming capabilities.

## Key Features

- **Stable Diagramming (Option C)**: A dedicated Drawing Pad with a fixed 1333x1000 coordinate system, ensuring your diagrams never distort or drift.
- **Translucent UI**: Draw directly over your Typst preview with a translucent canvas for perfect alignment.
- **Professional Persistence**: Automatic saving of strokes as JSON (for editing) and SVG (for display). Robust data protection with AppLifecycle-aware flushing.
- **Multi-File Management**: A built-in sidebar to manage multiple `.typ` files within a single synced project.
- **Scientific PDF Export**: One-click professional PDF generation with timestamped filenames.

## Architecture

Typink uses a hybrid architecture:
- **Frontend**: Flutter (Riverpod for state, `re_editor` for Typst editing).
- **Engine**: Rust (Typst engine integration via `flutter_rust_bridge`).

### File Structure
```
Notebook/
  main.typ       # Main Typst document
  figures/       # Auto-managed directory
    fig1.svg     # Image for Typst rendering
    fig1.json    # Stroke data for re-editing
```

## Build Instructions

Typink uses a hybrid architecture with a Rust core. **Nix** is required to manage the toolchain (Flutter SDK, Rust, Android NDK).

Use the `Makefile` at the project root — it wraps every command in the correct `nix develop` environment automatically.

```bash
make help          # list all targets

make run           # build Rust (debug) + run on Linux
make build-linux   # build Rust (release) + package for Linux

make dev-android   # cross-compile Rust (arm64) + run on device
make build-apk     # cross-compile Rust (arm64) + build release APK

make bridge        # regenerate Flutter↔Rust bridge
make test          # run all tests
make clean         # clean Flutter build artefacts
```

The optimized APK will be at `flutter_app/build/app/outputs/flutter-apk/app-release.apk`.

---

> [!TIP]
> If you encounter "file INSTALL cannot find" or other directory errors, run `make clean`.

## Installation

### NixOS

The flake ships a ready-to-run package (`packages.default`) and app (`apps.default`).

**Run without installing:**
```bash
nix run github:m-tky/Typink
```

**Install to your user profile:**
```bash
nix profile install github:m-tky/Typink
```

**Add to a NixOS system flake** (`/etc/nixos/flake.nix`):
```nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    typink.url  = "github:m-tky/Typink";
  };

  outputs = { nixpkgs, typink, ... }: {
    nixosConfigurations.my-machine = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        ./configuration.nix
        ({ pkgs, ... }: {
          environment.systemPackages = [
            typink.packages.x86_64-linux.default
          ];
        })
      ];
    };
  };
}
```

**home-manager:**
```nix
home.packages = [ inputs.typink.packages.${pkgs.system}.default ];
```

**Build locally from source:**
```bash
nix build .       # output → ./result/bin/typink
nix run .         # build and launch immediately
```

---

### Other Linux distributions (Ubuntu, Arch, Fedora, …)

Download the pre-built bundle from the [Releases](https://github.com/m-tky/Typink/releases) page and extract it, or build from source with `make build-linux`.

**Install:**

```bash
sudo cp -r typink-bundle /opt/typink
sudo ln -sf /opt/typink/typink /usr/local/bin/typink
```

**Add a desktop launcher:**

```bash
cat > ~/.local/share/applications/typink.desktop << 'EOF'
[Desktop Entry]
Name=Typink
Comment=Scientific notebook with Typst and handwriting
Exec=/opt/typink/typink
Icon=/opt/typink/data/flutter_assets/icon.png
Type=Application
Categories=Office;Education;
EOF
```

**If the app fails to start**, install the required GTK 3 libraries:

| Distro | Command |
|--------|---------|
| Ubuntu / Debian | `sudo apt install libgtk-3-0 libglib2.0-0 libpango-1.0-0 libharfbuzz0b libatk1.0-0 libcairo2 libgdk-pixbuf-2.0-0 libfontconfig1 libfreetype6` |
| Arch Linux | `sudo pacman -S gtk3 glib2 pango harfbuzz atk cairo gdk-pixbuf2 fontconfig freetype2` |
| Fedora / RHEL | `sudo dnf install gtk3 glib2 pango harfbuzz atk cairo gdk-pixbuf2 fontconfig freetype` |

> [!NOTE]
> Any GNOME, KDE, or Xfce desktop already has these. They're only missing on minimal/server installs.

---

## User Guide

### Dynamic Handwriting
1. Click the **"Insert Drawing"** icon in the toolbar.
2. The **Drawing Pad** modal opens. Sketch your diagram.
3. Click **"Save & Close"**.
4. Typink automatically calculates the content density and suggests a width (40% / 70% / 100%) for the `#figure` tag in Typst.

### PDF Export
Click the **PDF icon** in the top right.
- **Linux**: Saved to `~/Documents/Typink/`
- **Android**: Saved to your `Downloads` directory.

### Syncthing Integration
Typink is designed to work with Syncthing. Files are saved in a clean `.typ` + `figures/` directory structure, making conflict resolution and cross-device sync straightforward.
