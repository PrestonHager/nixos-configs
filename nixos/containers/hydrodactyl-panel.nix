# Hydrodactyl panel (BlueprintFramework/hydrodactyl), built from the release
# tarball plus the homelab addons in plugins/hydrodactyl: Zitadel SSO, the
# DNS records and router port-forward extensions (PHP from their flake
# inputs), and the Minecraft tools. Everything, including Composer vendor/
# and the Vite frontend, is built here, so the container needs no network
# or build tools at runtime.
{ pkgs, inputs }:

let
  version = "6.4.2";

  php = pkgs.php84.withExtensions ({ enabled, all }: enabled ++ (with all; [
    bcmath curl gd intl mbstring opcache pdo_mysql posix redis sodium zip
  ]));

  upstream = pkgs.fetchurl {
    url = "https://github.com/BlueprintFramework/hydrodactyl/releases/download/v${version}/panel.tar.gz";
    hash = "sha256-jBm4YpS/4/SPEJJ4zC5D3vyvFI/TxWrFhz4S4XqMUpY=";
  };

  # Release source + addon hook patch + addon code.
  src = pkgs.runCommand "hydrodactyl-src-${version}" {
    nativeBuildInputs = [ pkgs.gnupatch ];
  } ''
    mkdir -p $out
    tar -xzf ${upstream} -C $out
    ${pkgs.bash}/bin/bash ${../../plugins/hydrodactyl}/install-addons.sh \
      $out ${inputs.pterodactyl-dns-records} ${inputs.pterodactyl-port-forward}
  '';

  frontend = pkgs.stdenvNoCC.mkDerivation (finalAttrs: {
    pname = "hydrodactyl-frontend";
    inherit version src;

    nativeBuildInputs = [ pkgs.nodejs_22 pkgs.pnpm_11 pkgs.pnpmConfigHook ];
    pnpmDeps = pkgs.fetchPnpmDeps {
      inherit (finalAttrs) pname version src;
      pnpm = pkgs.pnpm_11;
      fetcherVersion = 5;
      hash = "sha256-WAFGrcbtXVDq3Le2ArHXKswnKNpuVCsAz+Y4Ckpa+LM=";
    };

    # Plain Vite build; "pnpm ship" goes through turbo, which wants a daemon.
    buildPhase = ''
      runHook preBuild
      pnpm run build
      runHook postBuild
    '';
    installPhase = ''
      runHook preInstall
      cp -r public/build $out
      runHook postInstall
    '';
  });

  panel = php.buildComposerProject2 (finalAttrs: {
    pname = "hydrodactyl";
    inherit version src;
    composerNoDev = true;
    vendorHash = "sha256-hmYCOvzAXv1sQ/gUCepL0Y06bKWJN2piqDWzrjDYC4U=";

    postInstall = ''
      root=$out/share/php/hydrodactyl
      rm -rf $root/public/build $root/node_modules
      cp -r ${frontend} $root/public/build
    '';
  });
in
{
  inherit version php panel frontend;
  root = "${panel}/share/php/hydrodactyl";
}
