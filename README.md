# AmneziaVPN: one launcher on NixOS

Built for `x86_64-linux` (the architecture used by the uploaded flake), with **no NixOS rebuild needed**.

## First run

```bash
chmod +x start-amnezia.sh
./start-amnezia.sh
```

This builds/uses the `amnezia-vpn` package in `nixos-unstable`, starts its **matching root service** as a transient systemd unit, launches the GUI as your own user, and optionally runs a localhost-only `microsocks` SOCKS5 proxy on port **1081**.

The `sudo` prompt is for the privileged daemon, **not** the GUI. Keep the launcher terminal open while using the GUI; the VPN service itself continues running after the GUI closes. The proxy ends when the GUI process ends.

Do not keep the old `start-amnezia-service.sh` session running at the same time. Stop the manually launched service before running the new launcher.

## Commands

```bash
./start-amnezia.sh                   # Start daemon + GUI + SOCKS5
./start-amnezia.sh status            # Status of managed daemon and SOCKS5 port
./start-amnezia.sh logs              # Root daemon journal
./start-amnezia.sh version           # Packaged version
./start-amnezia.sh test              # Compare direct and SOCKS5 public IP
./start-amnezia.sh stop              # Stop managed root daemon
./start-amnezia.sh update            # Update flake.lock, then start
SOCKS_ENABLE=0 ./start-amnezia.sh    # Daemon + GUI without SOCKS5
SOCKS_PORT=1082 ./start-amnezia.sh   # Alternate SOCKS5 port
```

You can also use `nix run -L . -- status` or `nix run -L .` directly.

The GUI log is stored at `${XDG_STATE_HOME:-$HOME/.local/state}/amnezia-proxy/gui.log`; the daemon is logged by systemd/journald as `amnezia-vpn-flake.service`.

## Version policy

As of 2026-10-26, AmneziaVPN **5.0.3.0** is the latest stable release; **5.0.4.2** is a pre-release. NixOS `nixos-unstable` already ships **5.0.3.0**. This flake deliberately uses `pkgs.amnezia-vpn` instead of merely replacing `version` and `src` of an older derivation: the latter would leave stale patches and incompatible runtime tooling. The version is reproducible via `flake.lock`; running `./start-amnezia.sh update` refreshes the nixpkgs input and then runs the package provided by that channel. This **does not guarantee** the latest upstream prerelease or an update faster than nixpkgs maintains it.

## Important notes

* This runs on **NixOS with systemd and sudo**, assuming a functional Linux desktop display session. NixOS package builds and VPN behavior were not run in the environment where these files were prepared; only static code checks were done.
* Requires functional Nix flakes; if necessary, enable `nix-command` and `flakes` in your NixOS configuration.
* The transient daemon survives closing the GUI. `./start-amnezia.sh stop` terminates it. The service is **not enabled for automatic startup after reboot**.
* If `AmneziaVPN.service` from the declarative NixOS module is already active from **a different Nix store package**, the launcher refuses to start another daemon. Use a matching package instead.
* `microsocks` **is not a VPN or killswitch**. It uses the current system routing, and may expose your real IP if the VPN disconnects. It's bound only to `127.0.0.1` for safety. `socks5h://` performs remote DNS resolution via the proxy protocol, but does not magically force a VPN.
* Upstream package's NixOS module enables `systemd-resolved` and adds system integration, while this local flake does not reconfigure the host. If DNS integration fails, prefer the declarative configuration below.

## Better long-term NixOS option (requires one rebuild)

The existing NixOS module manages the daemon at boot and handles system dependencies:

```nix
# Inside your NixOS config's module body; use a recent nixpkgs
programs.amnezia-vpn.enable = true;
```

After `sudo nixos-rebuild switch --flake ...`, the OS starts `AmneziaVPN.service` automatically; launch the GUI simply with `AmneziaVPN`. Do **not** run the transient service from this flake at the same time if using a separate AmneziaVPN build.
