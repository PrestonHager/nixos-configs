{ config, pkgs, inputs, ... }:

{
  # Enable networking using wpa_supplicant
  networking.wireless = {
    enable = true;
    # import sops secrets here
    networks."SSID".psk = "";
    extraConfig = "ctrl_interface=DIR=/var/run/wpa_supplicant GROUP=wheel";
  };
}
