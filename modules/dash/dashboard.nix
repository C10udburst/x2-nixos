{
  config,
  lib,
  pkgs,
  ...
}: let
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

  # Python Dashboard API wrapper (polled for system stats and manual model switching)
  dashScript = pkgs.writeShellScript "ai-dash-api" ''
    export MODELS_CONFIG_PATH="${modelsJsonFile}"
    export SYSTEMCTL="${pkgs.systemd}/bin/systemctl"
    exec ${pkgs.python3}/bin/python3 ${./dash.py} "$@"
  '';
in {
  options.services.dashboard = {
    enable = lib.mkEnableOption "AI Gateway Dashboard UI and API" // {
      default = true;
    };
  };

  # Export paths for use in default.nix / nginx
  config = lib.mkIf config.services.dashboard.enable {
    _module.args = {
      inherit modelsJsonFile dashboardHtmlFile dashScript;
    };
  };
}
