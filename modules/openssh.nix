{
  config,
  lib,
  pkgs,
  ...
}:
{
  services.openssh = {
    enable = true;
    settings = {
      PasswordAuthentication = true;
      PermitRootLogin = "no";
      KbdInteractiveAuthentication = false;
    };
  };

  # Open standard SSH port
  networking.firewall.allowedTCPPorts = [ 22 ];


  users.users.cloudburst = {
    isNormalUser = true;
    description = "cloudburst";
    extraGroups = [
      "wheel"
      "video"
      "render"
      "networkmanager"
    ];
    openssh.authorizedKeys.keys = [
      "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQDr78YYF81SudwLa3sCOjGcdaB7o8bUUGjqq3j92IfwY+DUx1zI6pV9gMxLgXcQTaNVMSVYns433k6PbnDu3wbORyWz58fRjGJUozuwHUVXaQPV9Lrk5LurTdAkGL5Fn6gE5zTYgZL51E30ln6XzYhmZVaaQoCTlhQRIs93v8AEqz5RnnflB0j3huAz12sOC8iJ+LD976+bVZqMkflKL+y1j9y7yvjgMxYvTpsVVD7+GPjAW+tCzReRFhfaHWXCK4HHZ7V7LQ4SSd3sRiQzwesUtIU6rudVWP8SqWDdu+FjNdp6vXRupwtydBxvn7DVkIug7zhQztQlyc0CSKfeXWM9swciScCvDJCmt3MxrCpm1NgQG27gOPTslyjn9xq6W/4eaQUemcKR2BMCtGx2LjifxrROKXdwZm0AOne7H8w+uEfPAxlbZ9Wc9Oko4E8mMqk7dkREVtkNxwRO/CwqWyT5mLLXWQ45o93ZxmidZ4nGg2KsJAgdYGfbRrCE0hYNY78= cloudburst@cloudburst-laptop"
    ];
  };

  # Passwordless sudo for convenience on headless AI server
  security.sudo.wheelNeedsPassword = false;
}
