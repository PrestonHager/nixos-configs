# Build and serve locally

The documentation site uses **[mdBook](https://rust-lang.github.io/mdBook/)**, built from `docs/site/` with content includes from `docs/*.md`.

## One-shot build

From the repo root:

```bash
nix build .#docs
```

Open the result:

```bash
# Linux / WSL
xdg-open result/index.html

# macOS
open result/index.html
```

On Windows, open `result\index.html` in a browser.

The flake output is a static HTML tree suitable for Caddy `file_server` on ace.

## Live reload (development)

Requires Nix with `mdbook` available:

```bash
nix develop .#docs-dev
cd docs/site
mdbook serve --open
```

Default URL: http://127.0.0.1:3000

Alternatively without the dev shell:

```bash
nix shell nixpkgs#mdbook -c mdbook serve docs/site
```

## Deploy on ace

The site is built during `nixos-rebuild switch --flake /etc/nixos#ace` and served at:

**https://serverdocs.prestonhager.com** (LAN / RFC1918 clients only)

After editing `docs/*.md` or `docs/site/`:

```bash
git pull
sudo nixos-rebuild switch --flake /etc/nixos#ace
```

## Source layout

| Path | Purpose |
|------|---------|
| `docs/*.md` | Canonical service runbooks (edit these) |
| `docs/site/SUMMARY.md` | mdBook navigation |
| `docs/site/src/**` | Thin wrappers with `{{#include ../_includes/...}}` (path relative to chapter) |
| `nixos/caddy/serverdocs.nix` | Caddy vhost (LAN-only) |
| `docs/site/default.nix` | Nix derivation for `mdbook build` |
