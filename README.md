# nixos-configs

Configurations for NixOS and Nix Package Manager

# Setup

Setup by cloning the repository into `/etc/nixos`.

```
sudo git clone https://github.com/PrestonHager/nixos-configs.git /etc/nixos
```

Then rebuild the nixos system using flakes.

```
sudo nixos-rebuild switch --flake /etc/nixos#default
```

