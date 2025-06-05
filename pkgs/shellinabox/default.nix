{ lib, stdenv, fetchFromGitHub, pkg-config, autoreconfHook, openssl, zlib }:

stdenv.mkDerivation rec {
  pname = "shellinabox";
  version = "unstable-2024-04-16";

  src = fetchFromGitHub {
    owner = "shellinabox";
    repo = "shellinabox";
    rev = "5c7fb5cde2d2a74775af040549bb5cb11aae6790";
    sha256 = "sha256-2cnPPXoN2oHhWAElaVfXr1ZAKSFJnCI9FXqyIKBXrsI=";
  };

  nativeBuildInputs = [ autoreconfHook pkg-config ];
  buildInputs = [ openssl zlib ];

  configureFlags = [
    "--disable-init"
    "--disable-runtime-loading"
  ];

  meta = with lib; {
    description = "Web-based AJAX terminal emulator";
    homepage = "https://github.com/shellinabox/shellinabox";
    license = licenses.gpl2Plus;
    maintainers = [];
    platforms = platforms.linux;
  };
}
