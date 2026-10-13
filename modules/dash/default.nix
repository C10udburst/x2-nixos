{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.services.gateway;

  # Serialized model and workload metadata from global registry contract
  modelsConfig = {
    default_model = config.services.defaultModel;
    lock_file = "/run/model-lock/model.lock";
    state_file = "/run/model-lock/active_model";
    all_exclusive_units = config.services.workload-manager.allExclusiveUnits;
    services =
      [
        {
          id = "gateway";
          name = "API Gateway";
          port = cfg.port;
          type = "gateway";
          unit = "nginx.service";
          description = "OpenAI compatible API gateway & dashboard";
        }
      ]
      ++ (lib.optional (config.services ? immich-ml && config.services.immich-ml.enable) {
        id = "immich-machine-learning";
        name = "Immich ML";
        port = config.services.immich-ml.port;
        backend_port = config.services.immich-ml.backendPort;
        type = "on-demand";
        unit = "immich-machine-learning.service";
        socket_unit = "immich-ml-listener.socket";
        description = "Immich photo ML inference engine";
      })
      ++ (lib.optional (config.services ? comfyui && config.services.comfyui.enable) {
        id = "comfyui";
        name = "ComfyUI";
        port = config.services.comfyui.port;
        backend_port = config.services.comfyui.backendPort;
        type = "on-demand";
        unit = "comfyui.service";
        socket_unit = "comfyui-listener.socket";
        description = "ComfyUI generative AI studio";
      });
    models = lib.mapAttrs (_: m: {
      service_name = m.serviceName;
      remapped_model = m.remappedModel;
      url = m.url;
      description = m.description;
      type = m.type;
    }) config.services.models;
  };

  modelsJsonFile = pkgs.writeText "models-registry.json" (builtins.toJSON modelsConfig);
  dashboardDir = pkgs.runCommand "dashboard-dir" {} ''
    mkdir -p $out
    cp ${./dashboard.html} $out/index.html
  '';

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
    export PATH="/run/wrappers/bin:${lib.makeBinPath [
      pkgs.systemd
      pkgs.coreutils
    ]}:$PATH"
    export MODELS_CONFIG_PATH="${modelsJsonFile}"
    export SYSTEMCTL="${pkgs.systemd}/bin/systemctl"
    exec ${pkgs.python3}/bin/python3 ${./dash.py} "$@"
  '';

  # Ultra-fast Bash + jq Switcher wrapper (hot path for /v1/* inference requests)
  switcherScript = pkgs.writeShellScript "ai-v1-switcher" ''
    export PATH="/run/wrappers/bin:${lib.makeBinPath [
      pkgs.jq
      pkgs.curl
      pkgs.gnused
      pkgs.coreutils
      pkgs.systemd
      pkgs.util-linux
    ]}:$PATH"
    export MODELS_CONFIG_PATH="${modelsJsonFile}"
    export SYSTEMCTL="${pkgs.systemd}/bin/systemctl"
    export STOP_OTHER_WORKLOADS="${config.services.workload-manager.stopScript}"
    exec ${pkgs.bash}/bin/bash ${./switcher.sh} "$@"
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
    # Dedicated user for API gateway and non-inference processes
    users.users.gateway = {
      isSystemUser = true;
      group = "gateway";
      description = "AI Gateway Service User";
    };
    users.groups.gateway = {};

    # Dedicated fcgiwrap instance for Dashboard API (/api/*)
    services.fcgiwrap.instances.dash = {
      process.prefork = 4;
      process.user = "gateway";
      process.group = "gateway";
      socket = {
        type = "unix";
        address = "/run/fcgiwrap-dash.sock";
        user = "gateway";
        group = "gateway";
        mode = "0660";
      };
    };

    # Dedicated fcgiwrap instance for /v1/* inference hot path
    services.fcgiwrap.instances.gateway = {
      process.prefork = 8;
      process.user = "gateway";
      process.group = "gateway";
      socket = {
        type = "unix";
        address = "/run/fcgiwrap-gateway.sock";
        user = "gateway";
        group = "gateway";
        mode = "0660";
      };
    };

    # Bare-minimal Nginx reverse proxy / FastCGI front (~3MB memory)
    services.nginx = {
      enable = true;
      user = "gateway";
      group = "gateway";
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
        extraConfig = ''
          client_max_body_size 0;
        '';

        # 1. Static dashboard HTML (wire speed)
        locations."/" = {
          root = "${dashboardDir}";
          index = "index.html";
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

        # 3. Python Dashboard API (/api/*) on isolated fastcgi socket
        locations."/api/" = {
          extraConfig = ''
            fastcgi_pass unix:/run/fcgiwrap-dash.sock;
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
            client_body_timeout 600s;
            client_max_body_size 0;
          '';
        };
      };
    };

    # Open firewall port
    networking.firewall.allowedTCPPorts = [cfg.port];
  };
}
