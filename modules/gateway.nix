{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.services.gateway;
  gufoCfg = config.services.gufo;

  # Serialized model metadata for dash.py
  modelsConfig = {
    backend_port = gufoCfg.backendPort;
    default_model = gufoCfg.defaultModel;
    models = lib.mapAttrs (name: m: {
      alias = m.alias;
      description = m.description;
      context = m.context;
      speculative = m.speculative;
      systemd_unit = "gufo-${name}.service";
    }) gufoCfg.models;
  };

  modelsJsonFile = pkgs.writeText "gufo-models.json" (builtins.toJSON modelsConfig);
  dashboardHtmlFile = ./dashboard.html;

  # Python Dashboard API wrapper (rarely used, polled for stats)
  dashScript = pkgs.writeShellScript "gufo-dash-api" ''
    export GUFO_CONFIG_PATH="${modelsJsonFile}"
    export SYSTEMCTL="${pkgs.systemd}/bin/systemctl"
    exec ${pkgs.python3}/bin/python3 ${./dash.py} "$@"
  '';

  # Ultra-fast Bash + jq Switcher wrapper (hot path for /v1/* inference requests)
  switcherScript = pkgs.writeShellScript "gufo-v1-switcher" ''
    export PATH="${lib.makeBinPath [
      pkgs.jq
      pkgs.curl
      pkgs.gnused
      pkgs.coreutils
      pkgs.systemd
    ]}:$PATH"
    export GUFO_BACKEND_PORT="${toString gufoCfg.backendPort}"
    exec ${./switcher.sh} "$@"
  '';
in {
  options.services.gateway = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Enable the FastCGI model switcher gateway and web dashboard.";
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 8080;
      description = "Public port for web dashboard and OpenAI-compatible API.";
    };
  };

  config = lib.mkIf cfg.enable {
    # Allow gufo user passwordless sudo strictly for systemctl commands
    security.sudo.extraRules = [
      {
        users = ["gufo"];
        commands = [
          {
            command = "${pkgs.systemd}/bin/systemctl";
            options = ["NOPASSWD"];
          }
          {
            command = "/run/current-system/sw/bin/systemctl";
            options = ["NOPASSWD"];
          }
        ];
      }
    ];

    # Ultra-minimal fcgiwrap instance (~1MB memory)
    services.fcgiwrap.instances.gufo = {
      process.user = "gufo";
      process.group = "gufo";
      socket = {
        type = "unix";
        address = "/run/fcgiwrap-gufo.sock";
        user = "nginx";
        group = "nginx";
        mode = "0660";
      };
    };

    # Bare-minimal Nginx reverse proxy / FastCGI front (~3MB memory)
    services.nginx = {
      enable = true;
      recommendedOptimisation = true;
      recommendedGzipSettings = false; # Do not buffer or gzip SSE token streams!

      virtualHosts."gateway" = {
        default = true;
        listen = [
          {
            addr = "0.0.0.0";
            port = cfg.port;
          }
        ];

        # 1. Static dashboard HTML (wire speed)
        locations."= /" = {
          alias = "${dashboardHtmlFile}";
          extraConfig = ''
            default_type text/html;
          '';
        };

        locations."= /index.html" = {
          alias = "${dashboardHtmlFile}";
          extraConfig = ''
            default_type text/html;
          '';
        };

        # 2. Python Dashboard API (/api/*)
        locations."/api/" = {
          extraConfig = ''
            fastcgi_pass unix:/run/fcgiwrap-gufo.sock;
            include ${pkgs.nginx}/conf/fastcgi_params;
            fastcgi_param SCRIPT_FILENAME ${dashScript};
            fastcgi_buffering off;
            fastcgi_read_timeout 60s;
          '';
        };

        # 3. Ultra-fast Bash + jq Model Switcher (/v1/* inference hot path)
        locations."/v1/" = {
          extraConfig = ''
            fastcgi_pass unix:/run/fcgiwrap-gufo.sock;
            include ${pkgs.nginx}/conf/fastcgi_params;
            fastcgi_param SCRIPT_FILENAME ${switcherScript};
            fastcgi_buffering off;
            fastcgi_read_timeout 600s;
            fastcgi_send_timeout 600s;
            client_max_body_size 100M;
          '';
        };
      };
    };

    # Open firewall port
    networking.firewall.allowedTCPPorts = [cfg.port];
  };
}
