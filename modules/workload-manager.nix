{
  config,
  lib,
  pkgs,
  ...
}: let
  models = config.services.models or { };

  modelsOnDevice = device: lib.filterAttrs (_: m: (m.device or "gpu") == device) models;

  # 1. Model units, partitioned by hardware domain
  gpuModelUnits = lib.mapAttrsToList (_: m: m.serviceName) (modelsOnDevice "gpu");
  npuModelUnits = lib.mapAttrsToList (_: m: m.serviceName) (modelsOnDevice "npu");

  # 2. Standalone on-demand units (both live on the RDNA 3.5 iGPU today)
  gpuOnDemandUnits =
    (lib.optional (config.services ? immich-ml && config.services.immich-ml.enable) "immich-machine-learning.service")
    ++ (lib.optional (config.services ? comfyui && config.services.comfyui.enable) "comfyui.service");
  npuOnDemandUnits = [ ];

  # 3. Complete lists per domain, calculated at Nix eval time (Rule 1 applies per domain:
  #    at most one GPU workload AND at most one NPU workload may be resident at once)
  gpuExclusiveUnits = gpuModelUnits ++ gpuOnDemandUnits;
  npuExclusiveUnits = npuModelUnits ++ npuOnDemandUnits;
  allExclusiveUnits = gpuExclusiveUnits ++ npuExclusiveUnits;

  mkUnitList = units:
    if units == [ ] then "()" else ''(
      ${lib.concatStringsSep "\n      " (map (u: "\"${u}\"") units)}
    )'';

  # 4. Eval-time generated stop script: stop-other-workloads <device> <target_unit>
  #    Every caller MUST pass an explicit device; there is deliberately no default,
  #    because a silent "gpu" fallback would let an NPU request unload a 300 GB GPU model.
  #
  #    Two rules here are load-bearing, both learned from a production incident:
  #
  #    * **Absolute binaries only.** The script runs in the caller's service environment, and the
  #      switcher unit's PATH contains neither sudo nor systemctl. A bare `sudo` there died with
  #      127 "command not found", `2>/dev/null` hid it, `if` swallowed the status and the script
  #      exited 0 having stopped nothing - Rule 1 silently degraded to the asynchronous
  #      `Conflicts=` eviction, so the next model loaded against a still-resident 100 GB workload
  #      and died on `hipMalloc failed`.
  #    * **Stop the whole domain in one call and wait for it.** systemctl takes many units in one
  #      transaction and returns when they are really gone (`TimeoutStopSec`, then SIGKILL). That
  #      wait is the point: `Type=simple` makes `systemctl start <target>` return as soon as the
  #      process is forked, so an eviction that is merely queued is an OOM for whatever follows.
  stopOtherWorkloadsScript = pkgs.writeShellScript "stop-other-workloads" ''
    set -euo pipefail

    SYSTEMCTL=${pkgs.systemd}/bin/systemctl
    SUDO=/run/wrappers/bin/sudo

    DEVICE="''${1:-}"
    TARGET_UNIT="''${2:-}"

    GPU_UNITS=${mkUnitList gpuExclusiveUnits}
    NPU_UNITS=${mkUnitList npuExclusiveUnits}

    case "$DEVICE" in
      gpu) UNITS=("''${GPU_UNITS[@]}") ;;
      npu) UNITS=("''${NPU_UNITS[@]}") ;;
      all) UNITS=("''${GPU_UNITS[@]}" "''${NPU_UNITS[@]}") ;;
      *)
        echo "Unknown device domain: ''${DEVICE:-<empty>}" >&2
        exit 1
        ;;
    esac

    # Callers differ: the router reaches this through sudo (so uid 0 already), the wake scripts
    # call it directly as their own service user. Escalate only when that is actually needed.
    systemctl_run() {
      if [ "''${EUID:-$(id -u)}" -eq 0 ]; then
        "$SYSTEMCTL" "$@"
      else
        "$SUDO" -n "$SYSTEMCTL" "$@"
      fi
    }

    OTHER=()
    for unit in "''${UNITS[@]}"; do
      if [ -n "$unit" ] && [ "$unit" != "$TARGET_UNIT" ]; then
        OTHER+=("$unit")
      fi
    done

    # A unit that failed on its previous attempt must not be locked out by its start rate limit:
    # a failing ExecStartPre is gone in ~100 ms, so a client that retries on its own can reach
    # "start request repeated too quickly" and wedge the whole domain. Clearing the counter is one
    # fork on the cold path and is idempotent.
    if [ -n "$TARGET_UNIT" ]; then
      systemctl_run reset-failed "$TARGET_UNIT" || true
    fi

    if [ "''${#OTHER[@]}" -gt 0 ]; then
      # No `|| true` and no `2>/dev/null`: stderr belongs to whoever orchestrates the switch, and
      # a non-zero status means "do not start the next workload" - the only safe reading.
      systemctl_run stop "''${OTHER[@]}"
    fi
  '';

  # Claim the per-domain state file for a workload that is about to start (ExecStartPre).
  #
  # `active_gpu` / `active_npu` are written by every workload user (gufo, llama-cpp, kyojin, npu,
  # gateway), so `echo <id> > file && chmod 666 file` is broken across engines: the file belongs
  # to whichever engine ran last, `chmod` by a non-owner is EPERM, and **a failing ExecStartPre
  # aborts the unit before ExecStart ever runs** - the workload never starts while the state file
  # it just wrote claims that it did. In a 0777 directory unlink-and-recreate always works, which
  # is the same move dash.py's `set_state_file` and the router's `write_active` make.
  claimStateScript = pkgs.writeShellScript "claim-workload-state" ''
    set -eu

    DEVICE="''${1:-}"
    WORKLOAD="''${2:-}"
    case "$DEVICE" in
      gpu | npu) ;;
      *)
        echo "Unknown device domain: ''${DEVICE:-<empty>}" >&2
        exit 1
        ;;
    esac
    if [ -z "$WORKLOAD" ]; then
      echo "usage: claim-workload-state <device> <workload-id>" >&2
      exit 1
    fi

    STATE="/run/model-lock/active_$DEVICE"
    rm -f "$STATE" 2>/dev/null || true
    printf "%s" "$WORKLOAD" >"$STATE"
    # Nice to have, never a reason to fail a start: the next writer recreates it anyway.
    chmod 666 "$STATE" 2>/dev/null || true
  '';
in {
  options.services.workload-manager = {
    gpuExclusiveUnits = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = gpuExclusiveUnits;
      description = "Eval-time calculated list of mutually exclusive GPU (RDNA 3.5) workload units.";
    };

    npuExclusiveUnits = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = npuExclusiveUnits;
      description = "Eval-time calculated list of mutually exclusive NPU (XDNA 2) workload units.";
    };

    allExclusiveUnits = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = allExclusiveUnits;
      description = "Every exclusive workload unit across both hardware domains.";
    };

    lockFiles = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = {
        gpu = "/run/model-lock/gpu.lock";
        npu = "/run/model-lock/npu.lock";
      };
      description = "Per-domain flock files.";
    };

    stateFiles = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = {
        gpu = "/run/model-lock/active_gpu";
        npu = "/run/model-lock/active_npu";
      };
      description = "Per-domain active workload state files.";
    };

    stopScript = lib.mkOption {
      type = lib.types.package;
      default = stopOtherWorkloadsScript;
      description = "Eval-time generated script stopping active workloads of one domain: <device> <target>.";
    };

    claimStateScript = lib.mkOption {
      type = lib.types.package;
      default = claimStateScript;
      description = "Cross-user-safe script that claims a domain state file in ExecStartPre: <device> <workload-id>.";
    };
  };

  config = {
    # Consolidated passwordless sudo for workload orchestration
    security.sudo.extraRules = [
      {
        users = [
          "gateway"
          "gufo"
          "llama-cpp"
          "kyojin"
          "immich-ml"
          "comfyui"
        ];
        commands = [
          {
            command = "${pkgs.systemd}/bin/systemctl";
            options = [ "NOPASSWD" ];
          }
          {
            command = "/run/current-system/sw/bin/systemctl";
            options = [ "NOPASSWD" ];
          }
          {
            command = "${stopOtherWorkloadsScript}";
            options = [ "NOPASSWD" ];
          }
        ];
      }
    ];

    # Model lock directory and one lock + state file per hardware domain.
    # No legacy `model.lock` / `active_model` symlinks: every reader lives in this repo
    # and a dangling active_model -> active_gpu link would make os.path.exists() report a
    # stale model while the GPU domain is idle.
    systemd.tmpfiles.rules = [
      "d /run/model-lock 0777 root root - -"
      "f /run/model-lock/gpu.lock 0666 root root - -"
      "f /run/model-lock/active_gpu 0666 root root - -"
      "f /run/model-lock/npu.lock 0666 root root - -"
      "f /run/model-lock/active_npu 0666 root root - -"
    ];

    # Mutual systemd Conflicts - strictly intra-domain (Rule 1 per domain).
    systemd.services = {
      immich-machine-learning = lib.mkIf (config.services ? immich-ml && config.services.immich-ml.enable) {
        conflicts = lib.filter (u: u != "immich-machine-learning.service") gpuExclusiveUnits;
      };
      comfyui = lib.mkIf (config.services ? comfyui && config.services.comfyui.enable) {
        conflicts = lib.filter (u: u != "comfyui.service") gpuExclusiveUnits;
      };
    };
  };
}
