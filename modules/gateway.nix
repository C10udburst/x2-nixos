{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.services.gateway;
  gufoCfg = config.services.gufo;

  # Serialized model metadata for switcher.py
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
  switcherPyFile = ./switcher.py;

  # FastCGI wrapper script executed by fcgiwrap
  fcgiScript = pkgs.writeShellScript "gufo-fcgi-gateway" ''
    export GUFO_CONFIG_PATH="${modelsJsonFile}"
    export GUFO_DASHBOARD_HTML="${dashboardHtmlFile}"
    export SYSTEMCTL="${pkgs.systemd}/bin/systemctl"
    exec ${pkgs.python3}/bin/python3 ${switcherPyFile} "$@"
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

    # Ultra-minimal fcgiwrap instance (~1MB memory, exits on idle)
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

        locations."/" = {
          extraConfig = ''
            fastcgi_pass unix:/run/fcgiwrap-gufo.sock;
            include ${pkgs.nginx}/conf/fastcgi_params;
            fastcgi_param SCRIPT_FILENAME ${fcgiScript};
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
