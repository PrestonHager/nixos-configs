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

Requires Nix with `mdbook` and `mdbook-mermaid` available:

```bash
nix develop .#docs-dev
cd docs/site
mdbook serve --open
```

Default URL: http://127.0.0.1:3000

Alternatively without the dev shell:

```bash
nix shell nixpkgs#mdbook nixpkgs#mdbook-mermaid -c mdbook serve docs/site
```

Mermaid diagrams in fenced ` ```mermaid ` blocks are rendered in the browser via the `mdbook-mermaid` preprocessor and bundled `mermaid.min.js`.

## Deploy on ace

The site is built during `nixos-rebuild switch --flake /etc/nixos#ace` and served at:

**https://serverdocs.prestonhager.com** (LAN / RFC1918 clients only)

### Bootstrap SSH public key (LAN-only)

Installers can fetch the homelab admin pubkey without pasting it by hand:

```text
https://serverdocs.prestonhager.com/ssh/id_ed25519.pub
```

Source file: `docs/bootstrap/ssh-ed25519.pub` (copied into the docs derivation at build time).

Example:

```bash
curl -fsSL https://serverdocs.prestonhager.com/ssh/id_ed25519.pub
# use with bootstrap:
curl -fsSL https://raw.githubusercontent.com/PrestonHager/nixos-configs/main/scripts/bootstrap-minimal.sh \
  | sudo bash -s -- -y -d /dev/nvme0n1 \
      -k "$(curl -fsSL https://serverdocs.prestonhager.com/ssh/id_ed25519.pub)"
```

Non-LAN clients get **403** (same as the rest of serverdocs).

After editing `docs/*.md`, `docs/bootstrap/`, or `docs/site/`:

```bash
git pull
sudo nixos-rebuild switch --flake /etc/nixos#ace
```

## Source layout

| Path | Purpose |
|------|---------|
| `docs/*.md` | Canonical service runbooks (edit these). Inter-page links must be relative to the **including chapter** under `docs/site/src/`, not to the flat `docs/` folder. |
| `docs/bootstrap/ssh-ed25519.pub` | LAN-served bootstrap admin SSH public key |
| `docs/site/src/SUMMARY.md` | mdBook navigation |
| `docs/site/src/**` | Thin wrappers with `{{#include ../_includes/...}}` (path relative to chapter) |
| `nixos/caddy/serverdocs.nix` | Caddy vhost (LAN-only) |
| `docs/site/check-docs-links.js` | `node docs/site/check-docs-links.js` — verify internal chapter links |
