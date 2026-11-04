// Hager Homelab — progressive enhancement only; every page works without JS.
// Loaded in <head> (not deferred) so the saved theme applies before paint.
(function () {
  var root = document.documentElement;
  var KEY = "hl-theme";

  function stored() {
    try { return localStorage.getItem(KEY); } catch (e) { return null; }
  }
  function save(v) {
    try { localStorage.setItem(KEY, v); } catch (e) { /* private mode */ }
  }
  var saved = stored();
  if (saved === "light" || saved === "dark") root.setAttribute("data-theme", saved);
  root.classList.remove("no-js");

  function currentTheme() {
    var t = root.getAttribute("data-theme");
    if (t) return t;
    return window.matchMedia && window.matchMedia("(prefers-color-scheme: dark)").matches ? "dark" : "light";
  }

  document.addEventListener("DOMContentLoaded", function () {
    // Theme toggle
    var tbtn = document.querySelector("[data-theme-toggle]");
    function label() {
      if (!tbtn) return;
      var next = currentTheme() === "dark" ? "light" : "dark";
      tbtn.setAttribute("aria-label", "Switch to " + next + " theme");
      tbtn.setAttribute("title", "Switch to " + next + " theme");
    }
    if (tbtn) {
      label();
      tbtn.addEventListener("click", function () {
        var next = currentTheme() === "dark" ? "light" : "dark";
        root.setAttribute("data-theme", next);
        save(next);
        label();
      });
    }

    // Mobile menu
    var mbtn = document.querySelector("[data-menu-toggle]");
    var links = document.getElementById("nav-links");
    if (mbtn && links) {
      mbtn.addEventListener("click", function () {
        var open = links.classList.toggle("open");
        mbtn.setAttribute("aria-expanded", open ? "true" : "false");
      });
      links.addEventListener("click", function (e) {
        if (e.target.closest("a")) { links.classList.remove("open"); mbtn.setAttribute("aria-expanded", "false"); }
      });
    }

    // Tabs (WAI-ARIA tabs pattern). Auto-selects the visitor's OS once.
    document.querySelectorAll("[data-tabs]").forEach(function (box) {
      var tabs = Array.prototype.slice.call(box.querySelectorAll('[role="tab"]'));
      var panels = tabs.map(function (t) { return document.getElementById(t.getAttribute("aria-controls")); });
      function select(i, focus) {
        tabs.forEach(function (t, j) {
          var on = i === j;
          t.setAttribute("aria-selected", on ? "true" : "false");
          t.tabIndex = on ? 0 : -1;
          if (panels[j]) panels[j].hidden = !on;
        });
        if (focus) tabs[i].focus();
      }
      tabs.forEach(function (t, i) {
        t.addEventListener("click", function () { select(i, false); });
        t.addEventListener("keydown", function (e) {
          var k = e.key, n = tabs.length;
          if (k === "ArrowRight") { e.preventDefault(); select((i + 1) % n, true); }
          else if (k === "ArrowLeft") { e.preventDefault(); select((i - 1 + n) % n, true); }
          else if (k === "Home") { e.preventDefault(); select(0, true); }
          else if (k === "End") { e.preventDefault(); select(n - 1, true); }
        });
      });
      var ua = (navigator.userAgent || "").toLowerCase();
      var guess = /iphone|ipad|ipod/.test(ua) ? "ios" : /android/.test(ua) ? "android" :
        /mac os/.test(ua) ? "macos" : /windows/.test(ua) ? "windows" : /linux/.test(ua) ? "linux" : null;
      var idx = 0;
      tabs.forEach(function (t, i) { if (t.dataset.os === guess) idx = i; });
      select(idx, false);
    });

    // Highlight the current section in the table of contents
    var toc = document.querySelectorAll(".toc a[href^='#']");
    if (toc.length && "IntersectionObserver" in window) {
      var map = {};
      toc.forEach(function (a) { map[a.getAttribute("href").slice(1)] = a; });
      var io = new IntersectionObserver(function (entries) {
        entries.forEach(function (en) {
          if (en.isIntersecting && map[en.target.id]) {
            toc.forEach(function (a) { a.classList.remove("active"); });
            map[en.target.id].classList.add("active");
          }
        });
      }, { rootMargin: "-80px 0px -70% 0px" });
      Object.keys(map).forEach(function (id) { var el = document.getElementById(id); if (el) io.observe(el); });
    }

    var y = document.querySelector("[data-year]");
    if (y) y.textContent = String(new Date().getFullYear());
  });
})();
