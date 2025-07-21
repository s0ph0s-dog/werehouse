{
  description = "Web-based art archiving and sharing tool.";

  # Nixpkgs / NixOS version to use.
  inputs = {
    nixpkgs.url = "nixpkgs/nixos-25.05";
    cosmo = {
      url = "github:s0ph0s-dog/cosmopolitan/s0ph0s-patches";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = {
    self,
    cosmo,
    nixpkgs,
  }: let
    # to work with older version of flakes
    lastModifiedDate = self.lastModifiedDate or self.lastModified or "19700101";

    # Generate a user-friendly version number.
    version = "1.2.1";

    # System types to support.
    supportedSystems = ["x86_64-linux" "x86_64-darwin"]; #"aarch64-linux" "aarch64-darwin" ];

    # Helper function to generate an attrset '{ x86_64-linux = f "x86_64-linux"; ... }'.
    forAllSystems = nixpkgs.lib.genAttrs supportedSystems;

    # Nixpkgs instantiated for supported system types.
    nixpkgsFor = forAllSystems (system:
      import nixpkgs {
        inherit system;
        overlays = [self.overlays.default];
      });
  in {
    formatter = forAllSystems (
      system: nixpkgs.legacyPackages.${system}.alejandra
    );
    # A Nixpkgs overlay.
    overlays.default = final: prev: {
      werehouse = final.stdenv.mkDerivation rec {
        pname = "werehouse";
        inherit version;

        src = ./.;

        nativeBuildInputs = [
          cosmo.packages.${final.pkgs.stdenv.hostPlatform.system}.default
          final.zip
          final.gnumake
          (final.python312.withPackages (ps: [
            ps.htmlmin
          ]))
        ];

        dontCheck = true;
        dontPatch = true;
        dontConfigure = true;
        dontFixup = true;

        buildPhase = ''
          runHook preBuild

          cp "${cosmo.packages.${final.pkgs.stdenv.hostPlatform.system}.default}/bin/redbean" ./redbean-3.0beta.com
          ls .
          make build

          runHook postBuild
        '';

        installPhase = ''
          runHook preInstall

          mkdir -p $out/bin
          install werehouse.com $out/bin

          runHook postInstall
        '';
      };
    };

    # Provide some binary packages for selected system types.
    packages = forAllSystems (system: {
      inherit (nixpkgsFor.${system}) werehouse;
      default = self.packages.${system}.werehouse;
    });

    # A NixOS module, if applicable (e.g. if the package provides a system service).
    nixosModules = let
      module = {
        lib,
        pkgs,
        config,
        ...
      }: let
        cfg = config.services.werehouse;
      in {
        imports = [cosmo.nixosModules.default];
        options.services.werehouse = {
          enable = lib.mkEnableOption "Werehouse art archiving tool";

          dataDir = lib.mkOption {
            type = lib.types.path;
            default = /var/lib/werehouse;
            example = /opt/storage/werehouse;
            description = "Where to keep the databases and archived artwork files.";
          };

          createUserAndGroup = lib.mkOption {
            type = lib.types.bool;
            default = true;
            example = false;
            description = "Suppress creation of the werehouse user and group. This is not useful unless you're doing something funky like DynamicUser in the systemd unit.";
          };

          verboseLevel = lib.mkOption {
            type = lib.types.ints.between 0 2;
            default = 0;
            example = 2;
            description = "Increase log output. Valid values are 0, 1, or 2, corresponding to Info, Verbose, and Debug log levels.";
          };

          ports = lib.mkOption {
            type = lib.types.listOf lib.types.port;
            default = [8082];
            example = [80 443];
            description = "The port number(s) that Werehouse should listen on.";
          };

          sessionKey = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            example = "AAAA=";
            description = "Signing key for user session cookies. One will be generated and logged the first time you start Werehouse, copy and paste it here to avoid generating a new one every time the service restarts (which will log everyone out).";
          };

          apiKeys = lib.mkOption {
            description = "API keys for various services.  For more information on how to get these, see the README: https://github.com/s0ph0s-dog/werehouse/blob/main/README.md";
            default = {};
            type = lib.types.submodule {
              options = {
                fuzzySearch = lib.mkOption {
                  type = lib.types.nullOr lib.types.str;
                  default = null;
                  example = "AAAAAAAAAAAAAAAAAAAAAAAAA";
                  description = "API key for FuzzySearch.net, if you have one. If not, reverse searches will be done only with Fluffle.xyz.";
                };

                furAffinity = lib.mkOption {
                  description = "Login cookies for FurAffinity.net, to enable archiving Adult/Explicit posts.";
                  default = {};
                  type = lib.types.submodule {
                    options = {
                      a = lib.mkOption {
                        type = lib.types.nullOr lib.types.str;
                        default = null;
                        example = "AAA66DBC-E400-406C-B0E6-650590BFEAF8";
                        description = "The 'a' cookie from your FurAffinity.net session.";
                      };
                      b = lib.mkOption {
                        type = lib.types.nullOr lib.types.str;
                        default = null;
                        example = "AAA66DBC-E400-406C-B0E6-650590BFEAF8";
                        description = "The 'b' cookie from your FurAffinity.net session.";
                      };
                    };
                  };
                };

                telegram = lib.mkOption {
                  type = lib.types.nullOr lib.types.str;
                  example = "123456789:AAAAAAAAAAA_AAAAAAA_AAAAAAAAAAAAAAA";
                  default = null;
                  description = "A Telegram bot API key.  If provided, this enables users to enqueue links/images by sending them to the bot, and to share records from their archives to Telegram chats.";
                };

                weasyl = lib.mkOption {
                  type = lib.types.nullOr lib.types.str;
                  default = null;
                  example = "abcdef0123456789abcdef0123456789";
                  description = "API Key from Weasyl.com, to enable archiving artwork posted there.";
                };

                inkbunny = lib.mkOption {
                  description = "API credentials for Inkbunny.net, to enable archiving artwork posted there.";
                  default = {};
                  type = lib.types.submodule {
                    options = {
                      username = lib.mkOption {
                        type = lib.types.nullOr lib.types.str;
                        default = null;
                        example = "12345";
                        description = "Your Inkbunny username.";
                      };
                      password = lib.mkOption {
                        type = lib.types.nullOr lib.types.str;
                        default = null;
                        example = "please5dont.USETHIS.asyourpassword";
                        description = "Your Inkbunny password.";
                      };
                    };
                  };
                };

                e621 = lib.mkOption {
                  description = "API credentials for e621.net, to enable archiving artworks posted there with tags on the default (logged-out) block list. Most posts will be visible without this.";
                  default = {};
                  type = lib.types.submodule {
                    options = {
                      username = lib.mkOption {
                        type = lib.types.nullOr lib.types.str;
                        default = null;
                        example = "my_username";
                        description = "Your e621.net username.";
                      };
                      apiKey = lib.mkOption {
                        type = lib.types.nullOr lib.types.str;
                        default = null;
                        example = "abcdef0123456789abcdef0123456789";
                        description = "Your e621.net API key.";
                      };
                    };
                  };
                };
              };
            };
          };

          enableNginxVhost = lib.mkEnableOption "nginx virtual host configuration for reverse-proxying Xana (and doing TLS)";

          publicDomainName = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            example = "werehouse.example.com";
            default = null;
            description = "The public hostname for the nginx virtual host and TLS certificates";
          };
        };
        config = lib.mkMerge [
          (lib.mkIf cfg.createUserAndGroup {
            users.groups.werehouse = {};
            users.users.werehouse = {
              isSystemUser = true;
              group = "werehouse";
              description = "service account for Werehouse art archiving tool";
            };
            systemd.tmpfiles.rules = [
              "d ${cfg.dataDir} 0770 werehouse werehouse"
            ];
          })
          (lib.mkIf cfg.enable {
            nixpkgs.overlays = [self.overlays.default];

            systemd.services.werehouse = {
              path = [pkgs.werehouse];
              environment = lib.mkMerge [
                {TZ = "UTC";}
                (lib.mkIf (cfg.sessionKey != null) {
                  SESSION_KEY = cfg.sessionKey;
                })
                (lib.mkIf (cfg.apiKeys.telegram != null) {
                  TG_BOT_TOKEN = cfg.apiKeys.telegram;
                })
                (lib.mkIf (cfg.apiKeys.fuzzySearch != null) {
                  FUZZYSEARCH_API_KEY = cfg.apiKeys.fuzzySearch;
                })
                (lib.mkIf (cfg.apiKeys.weasyl != null) {
                  WEASYL_API_KEY = cfg.apiKeys.weasyl;
                })
                (lib.mkIf (
                    (cfg.apiKeys.furAffinity.a != null)
                    && (cfg.apiKeys.furAffinity.b != null)
                  ) {
                    FA_AUTH_COOKIES = "a=${cfg.apiKeys.furAffinity.a}; b=${cfg.apiKeys.furAffinity.b}";
                  })
                (lib.mkIf (
                    (cfg.apiKeys.inkbunny.username != null)
                    && (cfg.apiKeys.inkbunny.password != null)
                  ) {
                    IB_USERNAME = cfg.apiKeys.inkbunny.username;
                    IB_PASSWORD = cfg.apiKeys.inkbunny.password;
                  })
                (lib.mkIf (
                    (cfg.apiKeys.e621.username != null)
                    && (cfg.apiKeys.e621.apiKey != null)
                  ) {
                    E621_USERNAME = cfg.apiKeys.e621.username;
                    E621_API_KEY = cfg.apiKeys.e621.apiKey;
                  })
              ];
              script = let
                system = pkgs.stdenv.hostPlatform.system;
                ape = "${cosmo.packages.${system}.default}/bin/ape";
                werehouse = "${self.packages.${system}.default}/bin/werehouse.com";
                portString = toString (map (port: "-p ${toString port}") cfg.ports);
                verboseString = "-" + builtins.substring 0 cfg.verboseLevel "vv";
              in "${ape} ${werehouse} -l 127.0.0.1 ${portString} ${verboseString} -D .";
              wantedBy = ["multi-user.target"];
              serviceConfig = {
                Type = "simple";
                User = "werehouse";
                WorkingDirectory = cfg.dataDir;
              };
            };
          })
          (lib.mkIf (cfg.enable && cfg.enableNginxVhost) {
            assertions = [
              {
                assertion = cfg.publicDomainName != null;
                message = "if enableNginxVhost is set, you must provide publicDomainName";
              }
            ];
            services.nginx.virtualHosts.${cfg.publicDomainName} = let
              ngxSSL = config.services.nginx.virtualHosts.${cfg.publicDomainName};
              forceSSL = !(ngxSSL.onlySSL || ngxSSL.addSSL || ngxSSL.rejectSSL);
              ngxPkgName = config.services.nginx.package.pname;
              ngxHasQuic = ngxPkgName == "nginxQuic" || ngxPkgName == "angieQuic";
            in {
              forceSSL = lib.mkDefault forceSSL;
              enableACME = true;
              quic = lib.mkDefault ngxHasQuic;
              http2 = true;
              http3 = lib.mkDefault ngxHasQuic;
              locations."/" = {
                proxyPass = let
                  port = toString (builtins.head cfg.ports);
                in "https://127.0.0.1:${port}";
                recommendedProxySettings = true;
                extraConfig = ''
                  proxy_buffering off;
                  client_max_body_size 100m;
                  ${
                    # This also adds the header even if someone disables quic, but
                    # fixing that is annoying. I'll do it if someone asks.
                    lib.optionalString ngxHasQuic ''
                      add_header Alt-Svc 'h3=":443"; ma=86400';
                    ''
                  }
                '';
              };
            };
          })
        ];
      };
    in {
      werehouse = module;
      default = module;
    };
  };
}
