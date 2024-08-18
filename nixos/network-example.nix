# Please copy this file to network.nix and edit it
# based on your local configuration

{ config, pkgs, inputs, ... }:

{
  # Enable networking using wpa_supplicant
  networking.wireless = {
    enable = true;
    networks."SSID".psk = "password";
    extraConfig = "ctrl_interface=DIR=/var/run/wpa_supplicant GROUP=wheel";
  };
}
