{
  # The agent as a Nix package, and the declarative form of install/linux-install.sh for a NixOS box.
  #
  # A release built elsewhere does not run on NixOS -- its ERTS binaries expect a dynamic loader at a
  # path NixOS does not have -- so the agent is built here, by Nix, from this checkout.
  #
  # FIRST BUILD: `mixFodDeps.hash` below is a placeholder. `nix build .#agent` fails once, printing the
  # hash it computed for the dependency tree; paste that in and build again. The hash changes only
  # when mix.lock does.
  description = "OrbitOrc — network orchestration for multiplayer games, at indie scale";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { self, nixpkgs }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "aarch64-darwin"
        "x86_64-darwin"
      ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});
      version = "0.1.0";
    in
    {
      packages = forAllSystems (
        pkgs:
        let
          beam = pkgs.beam.packages.erlang_27;
          src = ./.;
          mixFodDeps = beam.fetchMixDeps {
            pname = "orbitorc-mix-deps";
            inherit src version;
            hash = pkgs.lib.fakeHash;
          };
          agent = beam.mixRelease {
            pname = "orbitorc_agent";
            inherit src version mixFodDeps;
            # An umbrella carries two releases; this package is the box-side one only. It has no
            # Phoenix, no assets and no database, so nothing here needs Node or a C toolchain.
            buildPhase = ''
              runHook preBuild
              mix release orbitorc_agent --no-deps-check --overwrite --path "$out"
              runHook postBuild
            '';
            installPhase = "true";
          };
        in
        {
          inherit agent;
          default = agent;
        }
      );

      apps = forAllSystems (pkgs: {
        # `nix run .#agent` on a Linux box: the whole agent with no install step. It still needs a
        # config.json in the platform's config directory; run it once and the log says where.
        agent = {
          type = "app";
          program = "${self.packages.${pkgs.stdenv.hostPlatform.system}.agent}/bin/orbitorc_agent";
        };
      });

      # A systemd USER unit bound to graphical-session.target, not a system service. A system service
      # has no DISPLAY: a rendering job launched from one draws nothing and reports success. A box with
      # no display at all can still run this; the agent reports "headless modes only".
      nixosModules.agent =
        {
          config,
          lib,
          pkgs,
          ...
        }:
        let
          cfg = config.services.orbitorc-agent;
        in
        {
          options.services.orbitorc-agent = {
            enable = lib.mkEnableOption "the OrbitOrc fleet agent";
            package = lib.mkOption {
              type = lib.types.package;
              default = self.packages.${pkgs.stdenv.hostPlatform.system}.agent;
              description = "The package providing bin/orbitorc_agent.";
            };
            extraPath = lib.mkOption {
              type = lib.types.listOf lib.types.package;
              default = [ ];
              description = ''
                Extra packages on the agent's PATH. A box needs whatever the projects it serves reach
                for: git, the task runner their build recipe uses, and the engine itself.
              '';
            };
          };
          config = lib.mkIf cfg.enable {
            systemd.user.services.orbitorc-agent = {
              description = "OrbitOrc fleet agent";
              after = [ "graphical-session.target" ];
              partOf = [ "graphical-session.target" ];
              wantedBy = [ "graphical-session.target" ];
              path = [
                pkgs.git
                pkgs.bash
              ] ++ cfg.extraPath;
              serviceConfig = {
                Type = "simple";
                ExecStart = "${cfg.package}/bin/orbitorc_agent start";
                Restart = "always";
                RestartSec = 5;
                # A restart must not orphan the previous run's engine processes holding the UDP port.
                KillMode = "control-group";
                TimeoutStopSec = 30;
              };
            };
          };
        };
    };
}
