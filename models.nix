{
  services.gufo = {
    enable = true;
    modelsDir = "/srv/models";
    port = 8080;
    defaultModel = "qwen3.8-flash-next";

    models = {
      # 1. Primary Model: Qwen 3.8 Flash Next with MTP & mmproj
      "qwen3.8-flash-next" = {
        alias = "qwen3.8-flash-next";
        description = "Qwen 3.8 Flash Next UD-Q4_K_XL with MTP speculative decoding & vision";
        modelPath = "qwen3.8-flash-next/UD-Q4_K_XL";
        mmprojPath = "qwen3.8-flash-next/mmproj-BF16.gguf";
        speculative = "mtp";
        mtpModelPath = "qwen3.8-flash-next/MTP/mtp-Qwen3.8-Flash-Next-shared-Q8_0.gguf";
        context = 65536;
        sessions = 1;
        # HSA_OVERRIDE_GFX_VERSION can be set here if needed by ROCm runtime:
        # env = {
        #   HSA_OVERRIDE_GFX_VERSION = "11.5.1";
        # };
      };

      # 2. Example Second Model (easy to swap or enable when downloaded)
      "qwen2.5-72b-instruct" = {
        alias = "qwen2.5-72b-instruct";
        description = "Qwen 2.5 72B Instruct (Q4_K_M) - High reasoning capability";
        modelPath = "qwen2.5-72b-instruct";
        context = 32768;
        sessions = 1;
      };

      # 3. Example Third Model
      "deepseek-r1-distill-qwen-32b" = {
        alias = "deepseek-r1-32b";
        description = "DeepSeek R1 Distill Qwen 32B (Q8_0) - Deep reasoning specialist";
        modelPath = "deepseek-r1-distill-qwen-32b";
        context = 65536;
        sessions = 1;
      };
    };
  };
}
