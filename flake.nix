{
  description = "AmneziaVPN on NixOS: GUI, privileged service and optional localhost SOCKS5 proxy";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { self, nixpkgs }:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs { inherit system; };
      lib = pkgs.lib;

      # Use the version *packaged for this nixpkgs revision*, including matching
      # sources, runtime tools, CMake patches and AmneziaWG/Xray dependencies.
      # nixos-unstable ships 5.0.3.0 (latest stable as of 2026-10-26).
      amnezia =
        if lib.versionAtLeast pkgs.amnezia-vpn.version "5.0.3.0" then
          pkgs.amnezia-vpn
        else
          throw "amnezia-vpn is older than 5.0.3.0; run ./start-amnezia.sh update";

      # Matches the extra executable lookup PATH in the official NixOS module.
      daemonPath = lib.makeBinPath (with pkgs; [
        gawk
        iptables
        procps
        iproute2
        sudo
        coreutils
        gnugrep
        systemd
      ]);

      launcher = pkgs.writeShellApplication {
        name = "amnezia-stack";
        runtimeInputs = with pkgs; [
          bash
          coreutils
          procps
          iproute2
          systemd
          sudo
          gnugrep
          microsocks
          curl
        ];

        text = ''
          set -euo pipefail

          UNIT="amnezia-vpn-flake.service"
          GUI="${amnezia}/bin/AmneziaVPN"
          SERVICE="${amnezia}/bin/AmneziaVPN-service"
          DAEMON_PATH="${daemonPath}:/run/current-system/sw/bin"

          SOCKS_HOST="''${SOCKS_HOST:-127.0.0.1}"
          SOCKS_PORT="''${SOCKS_PORT:-1081}"
          SOCKS_ENABLE="''${SOCKS_ENABLE:-1}"
          LOG_DIR="''${XDG_STATE_HOME:-$HOME/.local/state}/amnezia-proxy"

          usage() {
            cat <<'EOF'
          Usage: ./start-amnezia.sh [start|status|stop|logs|version|test|help]

          start     Start the root VPN service (via systemd), local SOCKS5 and GUI
          status    Show service and local SOCKS5 status
          stop      Stop only the transient service created by this launcher
          logs      Show the last 100 VPN service log entries
          version   Show the Nix package version
          test      Compare direct IP with the localhost SOCKS5 IP
          help      Print this help

          ./start-amnezia.sh update updates the flake first, then starts the app.

          Environment:
            SOCKS_ENABLE=0     Don't run the local proxy
            SOCKS_PORT=1081    Default SOCKS5 port (localhost only)
            SOCKS_HOST=127.0.0.1
          EOF
          }

          validate_proxy_options() {
            if [[ "$SOCKS_ENABLE" != "0" && "$SOCKS_ENABLE" != "1" ]]; then
              echo "SOCKS_ENABLE must be 0 or 1" >&2
              exit 2
            fi
            if [[ ! "$SOCKS_PORT" =~ ^[0-9]+$ ]] || (( 10#$SOCKS_PORT < 1 || 10#$SOCKS_PORT > 65535 )); then
              echo "Invalid SOCKS_PORT: $SOCKS_PORT" >&2
              exit 2
            fi
            if [[ "$SOCKS_HOST" != "127.0.0.1" ]]; then
              echo "Only SOCKS_HOST=127.0.0.1 is allowed: an unauthenticated proxy must not be exposed." >&2
              exit 2
            fi
          }

          proxy_busy() {
            ss -H -ltn "( sport = :$SOCKS_PORT )" 2>/dev/null | grep -q .
          }

          # An already installed NixOS module may have its own native daemon.
          # Never run two AmneziaVPN services at the same time.
          check_native_service() {
            if systemctl is-active --quiet AmneziaVPN.service; then
              if systemctl show AmneziaVPN.service -p ExecStart --value | grep -Fq "$SERVICE"; then
                echo "Reusing the native NixOS AmneziaVPN.service (same store package)."
                return 0
              fi
              echo "ERROR: An installed AmneziaVPN.service is already running from a different package." >&2
              echo "Update it to the same NixOS package, or stop it before using this launcher." >&2
              exit 1
            fi
          }

          start_service() {
            check_native_service
            if systemctl is-active --quiet AmneziaVPN.service; then
              return 0
            fi

            if systemctl is-active --quiet "$UNIT"; then
              if systemctl show "$UNIT" -p ExecStart --value | grep -Fq "$SERVICE"; then
                echo "AmneziaVPN background service is already running."
                return 0
              fi
              echo "Replacing an older AmneziaVPN service with version ${amnezia.version}..."
              sudo systemctl stop "$UNIT"
            elif pgrep -f '(^|/)AmneziaVPN-service([[:space:]]|$)' >/dev/null 2>&1; then
              echo "ERROR: another AmneziaVPN-service process is already running." >&2
              echo "Stop the daemon you started from the old terminal before switching." >&2
              exit 1
            fi

            echo "Starting AmneziaVPN ${amnezia.version} as a systemd transient service..."
            sudo -v
            sudo systemctl reset-failed "$UNIT" >/dev/null 2>&1 || true
            sudo systemd-run \
              --unit=amnezia-vpn-flake \
              --collect \
              --description='AmneziaVPN (Nix flake)' \
              --property=Restart=on-failure \
              --property=RestartSec=2s \
              --setenv="PATH=$DAEMON_PATH" \
              "$SERVICE"
            sleep 1
            if ! systemctl is-active --quiet "$UNIT"; then
              echo "The daemon did not stay active; check: ./start-amnezia.sh logs" >&2
              exit 1
            fi
          }

          proxy_pid=""
          cleanup() {
            if [[ -n "$proxy_pid" ]]; then
              kill "$proxy_pid" 2>/dev/null || true
              wait "$proxy_pid" 2>/dev/null || true
            fi
          }

          run_gui() {
            mkdir -p "$LOG_DIR"

            if pgrep -u "$(id -u)" -x AmneziaVPN >/dev/null 2>&1; then
              echo "ERROR: AmneziaVPN GUI is already running. Close it first." >&2
              exit 1
            fi

            if [[ "$SOCKS_ENABLE" == "1" ]]; then
              if proxy_busy; then
                echo "ERROR: port $SOCKS_PORT is already in use; stop the old microsocks instance" >&2
                echo "or start with SOCKS_PORT=1082 (or SOCKS_ENABLE=0)." >&2
                exit 1
              fi
              echo "SOCKS5: socks5h://$SOCKS_HOST:$SOCKS_PORT"
              microsocks -i "$SOCKS_HOST" -p "$SOCKS_PORT" \
                >>"$LOG_DIR/microsocks.log" 2>&1 &
              proxy_pid=$!
            fi

            trap cleanup EXIT

            echo "Opening the GUI. Logs: $LOG_DIR/gui.log"
            echo "The daemon will stay active after this GUI exits. Stop it with ./start-amnezia.sh stop."
            "$GUI" 2>&1 | tee -a "$LOG_DIR/gui.log"
          }

          validate_proxy_options
          case "''${1:-start}" in
            start)
              start_service
              run_gui
              ;;
            status)
              echo "AmneziaVPN ${amnezia.version}"
              systemctl --no-pager --full status "$UNIT" 2>/dev/null || true
              if systemctl is-active --quiet AmneziaVPN.service; then
                systemctl --no-pager --full status AmneziaVPN.service 2>/dev/null || true
              fi
              if proxy_busy; then
                echo "Local TCP port $SOCKS_PORT is listening."
              else
                echo "Local TCP port $SOCKS_PORT is not listening."
              fi
              ;;
            stop)
              echo "Stopping transient service $UNIT (if present)..."
              sudo systemctl stop "$UNIT"
              ;;
            logs)
              journalctl --no-pager -u "$UNIT" -n 100
              ;;
            version)
              echo "AmneziaVPN ${amnezia.version}"
              echo "$GUI"
              ;;
            test)
              echo "Direct public IPv4:"
              curl -fsS -4 --max-time 15 https://ifconfig.me || true
              echo
              echo "Via local SOCKS5 proxy:"
              curl -fsS -4 --max-time 15 --proxy "socks5h://$SOCKS_HOST:$SOCKS_PORT" https://ifconfig.me || true
              echo
              echo "WARNING: microsocks does not enforce a VPN route. Test while connected to AmneziaVPN."
              ;;
            help|--help|-h)
              usage
              ;;
            *)
              usage >&2
              exit 2
              ;;
          esac
        '';
      };
    in
    {
      packages.${system} = {
        default = launcher;
        amnezia = amnezia;
      };
      apps.${system}.default = {
        type = "app";
        program = "${launcher}/bin/amnezia-stack";
      };
      devShells.${system}.default = pkgs.mkShell {
        packages = [ amnezia pkgs.microsocks pkgs.curl ];
      };
    };
}
