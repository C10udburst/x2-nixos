{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.services.gateway;

  # Serialized model metadata from global models registry contract
  modelsConfig = {
    default_model = config.services.defaultModel;
    lock_file = "/run/model-lock/model.lock";
    state_file = "/run/model-lock/active_model";
    models = lib.mapAttrs (_: m: {
      service_name = m.serviceName;
      remapped_model = m.remappedModel;
      url = m.url;
      description = m.description;
    }) config.services.models;
  };

  modelsJsonFile = pkgs.writeText "models-registry.json" (builtins.toJSON modelsConfig);
  dashboardHtmlFile = ./dashboard.html;

  # Classic OpenAI /v1/models payload generated at Nix eval time
  openaiModelsJson = {
    object = "list";
    data = lib.mapAttrsToList (name: _: {
      id = name;
      object = "model";
      created = 1700000000;
      owned_by = "evo-x2";
      permission = [];
      root = name;
      parent = null;
    }) config.services.models;
  };
  openaiModelsJsonFile = pkgs.writeText "openai-models.json" (builtins.toJSON openaiModelsJson);

  # Python Dashboard API wrapper
  dashScript = pkgs.writeShellScript "ai-dash-api" ''
    export MODELS_CONFIG_PATH="${modelsJsonFile}"
    export SYSTEMCTL="${pkgs.systemd}/bin/systemctl"
    exec ${pkgs.python3}/bin/python3 ${./dash.py} "$@"
  '';

  # Ultra-fast Bash + jq Switcher wrapper (hot path for /v1/* inference requests)
  switcherScript = pkgs.writeShellScript "ai-v1-switcher" ''
    export PATH="${lib.makeBinPath [
      pkgs.jq
      pkgs.curl
      pkgs.gnused
      pkgs.coreutils
      pkgs.systemd
    ]}:$PATH"
    export MODELS_CONFIG_PATH="${modelsJsonFile}"
    exec ${./switcher.sh} "$@"
  '';
in {
  imports = [
    ./dashboard.nix
  ];

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
    services.fcgiwrap.instances.gateway = {
      process.user = "gufo";
      process.group = "gufo";
      socket = {
        type = "unix";
        address = "/run/fcgiwrap-gateway.sock";
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

        # 2. Classic OpenAI /v1/models endpoint served statically at wire speed
        locations."= /v1/models" = {
          alias = "${openaiModelsJsonFile}";
          extraConfig = ''
            default_type application/json;
            add_header Access-Control-Allow-Origin *;
            add_header Access-Control-Allow-Methods "GET, OPTIONS";
            add_header Access-Control-Allow-Headers "*";
          '';
        };

        locations."= /models" = {
          alias = "${openaiModelsJsonFile}";
          extraConfig = ''
            default_type application/json;
            add_header Access-Control-Allow-Origin *;
            add_header Access-Control-Allow-Methods "GET, OPTIONS";
            add_header Access-Control-Allow-Headers "*";
          '';
        };

        # 3. Python Dashboard API (/api/*)
        locations."/api/" = {
          extraConfig = ''
            fastcgi_pass unix:/run/fcgiwrap-gateway.sock;
            include ${pkgs.nginx}/conf/fastcgi_params;
            fastcgi_param SCRIPT_FILENAME ${dashScript};
            fastcgi_buffering off;
            fastcgi_read_timeout 60s;
          '';
        };

        # 4. Ultra-fast Bash + jq Model Switcher (/v1/* inference hot path)
        locations."/v1/" = {
          extraConfig = ''
            fastcgi_pass unix:/run/fcgiwrap-gateway.sock;
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
