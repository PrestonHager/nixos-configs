#!/usr/bin/env node
/**
 * Rewrite markdown links in canonical docs/*.md so they resolve from the
 * mdBook chapter that {{#include}}s them (not from the flat docs/ directory).
 * Idempotent: links that already point at an existing chapter are left alone.
 */
const fs = require("fs");
const path = require("path");

const repo = path.resolve(__dirname, "../..");
const srcRoot = path.join(repo, "docs", "site", "src");
const docsRoot = path.join(repo, "docs");

const LINK_RE = /\[([^\]]*)\]\(([^)]+)\)/g;
const INCLUDE_RE = /\{\{#include \.\.\/_includes\/([^}]+)\}\}/;
const SKIP_PREFIXES = ["http://", "https://", "mailto:", "ftp://"];

function posix(p) {
  return p.split(path.sep).join("/");
}

function walkMd(dir, acc = []) {
  for (const ent of fs.readdirSync(dir, { withFileTypes: true })) {
    const full = path.join(dir, ent.name);
    if (ent.isDirectory()) {
      if (ent.name === "_includes") continue;
      walkMd(full, acc);
    } else if (ent.name.endsWith(".md")) acc.push(full);
  }
  return acc;
}

function discoverIncludes() {
  const mapping = {};
  for (const md of walkMd(srcRoot)) {
    const text = fs.readFileSync(md, "utf8");
    const m = text.match(INCLUDE_RE);
    if (!m) continue;
    const includeName = m[1].trim();
    if (includeName.includes("...") || !includeName.endsWith(".md")) continue;
    const chapter = posix(path.relative(srcRoot, md));
    const prev = mapping[includeName];
    if (!prev || (prev.startsWith("shared/") && chapter.startsWith("ace/"))) {
      mapping[includeName] = chapter;
    }
  }
  return mapping;
}

function chapterIndex(includeMap) {
  const idx = {};
  for (const [includeName, chapter] of Object.entries(includeMap)) {
    idx[includeName] = chapter;
    idx[path.posix.basename(includeName)] = chapter;
    idx[chapter] = chapter;
    idx[path.posix.basename(chapter)] = chapter;
  }
  for (const md of walkMd(srcRoot)) {
    const chapter = posix(path.relative(srcRoot, md));
    if (!idx[chapter]) idx[chapter] = chapter;
    const base = path.posix.basename(chapter);
    if (!idx[base]) idx[base] = chapter;
  }
  return idx;
}

function splitHref(href) {
  if (href.startsWith("#")) return ["", href];
  const i = href.indexOf("#");
  if (i >= 0) return [href.slice(0, i), href.slice(i)];
  return [href, ""];
}

function relTo(fromChapter, toChapter) {
  const fromDir = path.posix.dirname(fromChapter);
  let rel = path.posix.relpath
    ? path.posix.relpath(toChapter, fromDir === "." ? "." : fromDir)
    : path.posix.relative(fromDir === "." ? "." : fromDir, toChapter);
  if (!rel.startsWith(".")) rel = "./" + rel;
  return rel;
}

function chapterExists(resolved) {
  return fs.existsSync(path.join(srcRoot, ...resolved.split("/")));
}

function resolveTarget(hrefPath, chapter, idx) {
  if (!hrefPath.endsWith(".md")) return null;
  const cleaned = hrefPath.replace(/\\/g, "/");
  const resolved = path.posix.normalize(
    path.posix.join(path.posix.dirname(chapter) || ".", cleaned)
  );
  if (Object.values(idx).includes(resolved) || chapterExists(resolved)) {
    const destBase = path.posix.basename(cleaned);
    const resolvedBase = path.posix.basename(resolved);
    // Same path exists — but docs basename may differ from chapter basename
    // (e.g. network-astracap-router.md vs network-astracap.md). If the
    // resolved file does not exist, keep looking.
    if (chapterExists(resolved)) return null;
  }
  const prefixes = [
    "../docs/site/src/",
    "docs/site/src/",
    "../site/src/",
    "site/src/",
  ];
  for (const prefix of prefixes) {
    if (cleaned.startsWith(prefix)) {
      const rest = cleaned.slice(prefix.length);
      if (idx[rest]) return idx[rest];
    }
  }
  const base = path.posix.basename(cleaned);
  // Ambiguous when several chapters share a basename (index.md).
  const hits = Object.values(idx).filter((c) => path.posix.basename(c) === base);
  if (hits.length === 1) return hits[0];
  if (idx[base] && hits.length === 1) return idx[base];
  if (idx[cleaned]) return idx[cleaned];
  if (idx[base] && base !== "index.md") return idx[base];
  return null;
}

function rewriteText(text, chapter, idx) {
  const changes = [];
  const newText = text.replace(LINK_RE, (full, label, href) => {
    if (SKIP_PREFIXES.some((p) => href.startsWith(p))) return full;
    const [p, frag] = splitHref(href);
    if (!p) return full;
    const posixHref = p.replace(/\\/g, "/");
    if (posixHref.endsWith(".md") && posixHref.includes("/apps/")) {
      const norm = path.posix.normalize(path.posix.join("docs", posixHref));
      const url = `https://github.com/PrestonHager/nixos-configs/blob/dell-poweredge-r730xd/${norm}`;
      changes.push([href, url]);
      return `[${label}](${url})`;
    }
    const dest = resolveTarget(p, chapter, idx);
    if (!dest) return full;
    const newHref = relTo(chapter, dest) + frag;
    if (newHref === href) return full;
    changes.push([href, newHref]);
    return `[${label}](${newHref})`;
  });
  return [newText, changes];
}

function main() {
  const includeMap = discoverIncludes();
  const idx = chapterIndex(includeMap);
  let any = false;
  for (const [includeName, chapter] of Object.entries(includeMap).sort()) {
    const srcFile = path.join(docsRoot, includeName);
    if (!fs.existsSync(srcFile)) {
      console.error("missing include source:", srcFile);
      continue;
    }
    const text = fs.readFileSync(srcFile, "utf8");
    const [next, changes] = rewriteText(text, chapter, idx);
    if (changes.length) {
      fs.writeFileSync(srcFile, next.replace(/\r\n/g, "\n"));
      any = true;
      console.log(`${includeName} (chapter ${chapter}):`);
      for (const [a, b] of changes) console.log(`  ${a} -> ${b}`);
    }
  }
  for (const md of walkMd(srcRoot)) {
    const text = fs.readFileSync(md, "utf8");
    if (INCLUDE_RE.test(text)) continue;
    const chapter = posix(path.relative(srcRoot, md));
    const [next, changes] = rewriteText(text, chapter, idx);
    if (changes.length) {
      fs.writeFileSync(md, next.replace(/\r\n/g, "\n"));
      any = true;
      console.log(`site ${chapter}:`);
      for (const [a, b] of changes) console.log(`  ${a} -> ${b}`);
    }
  }
  if (!any) console.log("no link rewrites needed");
}

main();
