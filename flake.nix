{
  description = "Run latest AmneziaVPN GUI + localhost SOCKS5 proxy without NixOS rebuild";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs = { self, nixpkgs }:
    let
      system = "x86_64-linux";

      pkgs = import nixpkgs {
        inherit system;
        config.allowUnfree = true;
      };

      amneziaLatest = pkgs.amnezia-vpn.overrideAttrs (oldAttrs: rec {
        version = "4.8.19.0";

        src = pkgs.fetchFromGitHub {
          owner = "amnezia-vpn";
          repo = "amnezia-client";
          tag = version;
          fetchSubmodules = true;

          # Known hash for amnezia-client 4.8.19.0 with submodules.
          hash = "sha256-kftLofCyLA6DDfEXRPyy6Zx0JiQUEzpdYpTlvPihPZg=";
        };

        nativeBuildInputs = (oldAttrs.nativeBuildInputs or []) ++ [
          pkgs.python3
        ];

        # nixpkgs package may still contain patch assumptions from 4.8.18.0.
        # For 4.8.19.0, one known obsolete patch is xrayprotocol.cpp.
        # Also remove the QML drawer that can break PageHome rendering.
        postPatch =
          let
            fixedOldPostPatch = pkgs.lib.replaceStrings
              [ "--replace-fail" ]
              [ "--replace-warn" ]
              (oldAttrs.postPatch or "");
          in
          ''
            ${fixedOldPostPatch}

            echo "Checking for ApiPremV1MigrationDrawer QML issue..."

            if grep -R "ApiPremV1MigrationDrawer" -n client/ui/qml >/dev/null 2>&1; then
              echo "Patching out ApiPremV1MigrationDrawer references..."

              python3 - <<'PY'
from pathlib import Path

path = Path("client/ui/qml/Pages2/PageHome.qml")

if not path.exists():
    print("PageHome.qml does not exist, skipping")
    raise SystemExit(0)

text = path.read_text()
needle = "ApiPremV1MigrationDrawer"
idx = text.find(needle)

if idx == -1:
    print("ApiPremV1MigrationDrawer not found, skipping")
    raise SystemExit(0)

start = text.rfind("\n", 0, idx) + 1
brace = text.find("{", idx)

if brace == -1:
    raise SystemExit("Opening brace not found for ApiPremV1MigrationDrawer")

depth = 0
end = None

for i in range(brace, len(text)):
    ch = text[i]
    if ch == "{":
        depth += 1
    elif ch == "}":
        depth -= 1
        if depth == 0:
            end = i + 1
            break

if end is None:
    raise SystemExit("Closing brace not found for ApiPremV1MigrationDrawer")

while end < len(text) and text[end] in " \t\r\n":
    end += 1

new_text = (
    text[:start]
    + "\n    // ApiPremV1MigrationDrawer disabled for Nix/NixOS runtime\n"
    + text[end:]
)

path.write_text(new_text)
print("Removed ApiPremV1MigrationDrawer block")
PY
            else
              echo "ApiPremV1MigrationDrawer not found, no QML patch needed."
            fi
          '';
      });

      proxyHost = "127.0.0.1";
      proxyPort = "1080";

      runAmneziaProxy = pkgs.writeShellApplication {
        name = "run-amnezia-proxy";

        runtimeInputs = [
          amneziaLatest
          pkgs.microsocks
          pkgs.curl
          pkgs.procps
          pkgs.coreutils
          pkgs.gnugrep
          pkgs.nettools
        ];

        text = ''
          set -euo pipefail

          HOST="''${SOCKS_HOST:-${proxyHost}}"
          PORT="''${SOCKS_PORT:-${proxyPort}}"

          echo "== AmneziaVPN from this flake =="
          command -v AmneziaVPN || true
          readlink -f "$(command -v AmneziaVPN)" || true
          echo

          echo "== Expected version =="
          echo "AmneziaVPN ${amneziaLatest.version}"
          echo

          echo "== Local SOCKS5 proxy =="
          echo "SOCKS5: socks5h://$HOST:$PORT"
          echo

          if pgrep -x microsocks >/dev/null 2>&1; then
            echo "WARNING: existing microsocks process detected:"
            pgrep -a microsocks || true
            echo
            echo "If port is busy, stop it with:"
            echo "  pkill microsocks"
            echo
          fi

          if netstat -ltn 2>/dev/null | grep -q ":$PORT "; then
            echo "ERROR: port $PORT already appears to be in use."
            echo "Use another port:"
            echo "  SOCKS_PORT=1081 nix run ."
            exit 1
          fi

          echo "Starting AmneziaVPN GUI..."
          echo "Logs: /tmp/amnezia-vpn-flake.log"
          AmneziaVPN >/tmp/amnezia-vpn-flake.log 2>&1 &

          echo
          echo "Connect VPN inside AmneziaVPN app."
          echo "The SOCKS5 proxy will use whatever system route is active."
          echo

          echo "Starting microsocks on $HOST:$PORT..."
          exec microsocks -i "$HOST" -p "$PORT"
        '';
      };

      runGuiOnly = pkgs.writeShellApplication {
        name = "run-amnezia-gui-only";

        runtimeInputs = [
          amneziaLatest
          pkgs.coreutils
        ];

        text = ''
          set -euo pipefail

          echo "AmneziaVPN binary:"
          command -v AmneziaVPN
          readlink -f "$(command -v AmneziaVPN)" || true
          echo

          exec AmneziaVPN
        '';
      };

      runProxyOnly = pkgs.writeShellApplication {
        name = "run-socks5-proxy-only";

        runtimeInputs = [
          pkgs.microsocks
          pkgs.procps
          pkgs.coreutils
          pkgs.gnugrep
          pkgs.nettools
        ];

        text = ''
          set -euo pipefail

          HOST="''${SOCKS_HOST:-${proxyHost}}"
          PORT="''${SOCKS_PORT:-${proxyPort}}"

          echo "Starting SOCKS5 proxy only."
          echo "SOCKS5: socks5h://$HOST:$PORT"
          echo

          if netstat -ltn 2>/dev/null | grep -q ":$PORT "; then
            echo "ERROR: port $PORT already appears to be in use."
            exit 1
          fi

          exec microsocks -i "$HOST" -p "$PORT"
        '';
      };

      testProxy = pkgs.writeShellApplication {
        name = "test-amnezia-proxy";

        runtimeInputs = [
          pkgs.curl
        ];

        text = ''
          set -euo pipefail

          HOST="''${SOCKS_HOST:-${proxyHost}}"
          PORT="''${SOCKS_PORT:-${proxyPort}}"

          echo "Testing direct connection:"
          curl -4 --max-time 20 https://ifconfig.me || true
          echo
          echo

          echo "Testing via SOCKS5 proxy:"
          curl -4 --max-time 20 -x "socks5h://$HOST:$PORT" https://ifconfig.me || true
          echo
          echo

          echo "If AmneziaVPN is connected and both IPs are VPN IPs, good."
          echo "If proxy IP is your real IP, Amnezia is not routing microsocks traffic."
        '';
      };
    in
    {
      packages.${system} = {
        default = runAmneziaProxy;
        amnezia = amneziaLatest;
        gui-only = runGuiOnly;
        proxy-only = runProxyOnly;
        test = testProxy;
      };

      apps.${system} = {
        default = {
          type = "app";
          program = "${runAmneziaProxy}/bin/run-amnezia-proxy";
        };

        gui-only = {
          type = "app";
          program = "${runGuiOnly}/bin/run-amnezia-gui-only";
        };

        proxy-only = {
          type = "app";
          program = "${runProxyOnly}/bin/run-socks5-proxy-only";
        };

        test = {
          type = "app";
          program = "${testProxy}/bin/test-amnezia-proxy";
        };
      };

      devShells.${system} = {
        default = pkgs.mkShell {
          packages = [
            amneziaLatest
            pkgs.microsocks
            pkgs.curl
          ];

          shellHook = ''
            echo "Amnezia proxy dev shell"
            echo "Amnezia version: ${amneziaLatest.version}"
            echo
            echo "Run:"
            echo "  nix run ."
            echo
            echo "GUI only:"
            echo "  nix run .#gui-only"
            echo
            echo "Proxy only:"
            echo "  nix run .#proxy-only"
            echo
            echo "Test:"
            echo "  nix run .#test"
            echo
          '';
        };
      };
    };
}