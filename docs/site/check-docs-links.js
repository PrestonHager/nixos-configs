#!/usr/bin/env node
/** Verify internal markdown links in the mdBook site (includes expanded). */
const fs = require("fs");
const path = require("path");

const repo = path.resolve(__dirname, "../..");
const srcRoot = path.join(repo, "docs", "site", "src");
const docsRoot = path.join(repo, "docs");
const LINK_RE = /\[([^\]]*)\]\(([^)]+)\)/g;
const INCLUDE_RE = /\{\{#include \.\.\/_includes\/([^}]+)\}\}/;
const SKIP = ["http://", "https://", "mailto:", "ftp://"];

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

function splitHref(href) {
  if (href.startsWith("#")) return ["", href.slice(1)];
  const i = href.indexOf("#");
  if (i >= 0) return [href.slice(0, i), href.slice(i + 1)];
  return [href, ""];
}

function headingIds(text) {
  const ids = new Set();
  for (const line of text.split(/\r?\n/)) {
    const hm = /^(#{1,6})\s+(.+)$/.exec(line);
    if (!hm) continue;
    let slug = hm[2]
      .toLowerCase()
      .replace(/[`*_]/g, "")
      .replace(/[^\w\s-]/g, "")
      .trim()
      .replace(/\s+/g, "-");
    ids.add(slug);
  }
  return ids;
}

const chapters = walkMd(srcRoot);
const summary = fs.readFileSync(path.join(srcRoot, "SUMMARY.md"), "utf8");
const summaryFiles = new Set();
for (const m of summary.matchAll(/\[[^\]]*\]\(([^)]+)\)/g)) {
  const p = splitHref(m[1])[0];
  if (p.endsWith(".md")) summaryFiles.add(p.replace(/^\.\//, ""));
}

const broken = [];
const missingSummary = [];
const external = [];

for (const md of chapters) {
  const chapter = posix(path.relative(srcRoot, md));
  let text = fs.readFileSync(md, "utf8");
  const inc = text.match(INCLUDE_RE);
  if (inc && !inc[1].includes("...")) {
    const incPath = path.join(docsRoot, inc[1].trim());
    if (!fs.existsSync(incPath)) {
      broken.push({ chapter, href: inc[0], reason: `missing include ${incPath}` });
      continue;
    }
    text = fs.readFileSync(incPath, "utf8");
  }
  LINK_RE.lastIndex = 0;
  let m;
  while ((m = LINK_RE.exec(text))) {
    const href = m[2];
    if (SKIP.some((s) => href.startsWith(s))) {
      if (href.startsWith("http")) external.push({ chapter, href, label: m[1] });
      continue;
    }
    const [p, frag] = splitHref(href);
    if (!p) continue;
    if (!p.endsWith(".md") && !p.endsWith(".html") && !p.endsWith(".js")) continue;
    const resolved = path.posix.normalize(
      path.posix.join(path.posix.dirname(chapter) || ".", p)
    );
    const abs = path.join(srcRoot, ...resolved.split("/"));
    const docsAbs = path.join(docsRoot, path.posix.basename(p));
    // Chapter wrappers exist in src; includes live in docs/ and are mapped via wrappers
    let ok = fs.existsSync(abs);
    if (!ok && resolved.startsWith("ace/") || resolved.startsWith("shared/") || resolved.startsWith("pterodactyl-nodes/") || resolved.startsWith("poweredge/") || resolved.startsWith("ph-nixos/")) {
      ok = fs.existsSync(abs);
    }
    if (!ok) {
      broken.push({ chapter, href, resolved, label: m[1] });
    }
  }
}

for (const md of chapters) {
  const chapter = posix(path.relative(srcRoot, md));
  if (chapter === "SUMMARY.md") continue;
  if (!summaryFiles.has(chapter) && !summaryFiles.has("./" + chapter)) {
    missingSummary.push(chapter);
  }
}

console.log("=== broken internal links ===");
if (!broken.length) console.log("(none)");
else for (const b of broken) console.log(`${b.chapter}: [${b.label}](${b.href}) -> ${b.resolved || b.reason}`);

console.log("\n=== chapters not in SUMMARY.md ===");
if (!missingSummary.length) console.log("(none)");
else missingSummary.forEach((c) => console.log(c));

console.log(`\n=== external links (${external.length}, not fetched) ===`);
const uniq = [...new Set(external.map((e) => e.href))].sort();
uniq.forEach((h) => console.log(h));
