# Loftia Community Wiki public launch (2026-11-03)

Status checked 2026-10-24 on ace. The wiki stays login-walled until launch day.

## Already done (2026-10-24)

`/mw/html/PrelaunchSettings.php` is included at the end of `LocalSettings.php`.
Backup of the previous file: `/mw/LocalSettings.php.pre-launch-2026-10-24` (outside the web root).
It opens nothing. It:

- Turns Turnstile on. `$wgCaptchaClass` was still `SimpleCaptcha` (an arithmetic question), even though the Turnstile keys were set and the privacy policy says Turnstile is used.
  Triggers: account creation, adding URLs, new pages by non-autoconfirmed users, and bad logins.
- Makes autoconfirmed mean 4 days, 10 edits and a confirmed email. It used to be 0 days and 0 edits, so every account qualified.
- Limits uploads to autoconfirmed users and sysops.
- Removes the Wikibase entity rights that `ExampleSettings.php` gave to `*`.
- Adds tighter rate limits for new accounts, and caps account creation at 3 per IP per day.

## Checklist findings

| # | Item | Finding |
|---|------|---------|
| 1 | Open reading | `*` read = false. Staged in `LaunchSettings.php`. |
| 2 | Indexing, sitemap, robots.txt | noindex comes from the login wall and goes away once reading is open. `/robots.txt` and `/sitemap.xml` don't exist: they return the login-wall HTML with a 200 status. |
| 3 | Account creation, email | `*` createaccount = false (staged). `$wgEmailAuthentication` is on, and SMTP goes through iCloud. Only 3 of 17 users with an email have confirmed it, so **send a test mail before launch**. |
| 4 | Anonymous editing | Already off (`*` edit = false). The "IP address will be visible" text is just MediaWiki's standard notice. It stays off by design. |
| 5 | Uploads, licence | Fixed (autoconfirmed only). `MediaWiki:Licenses` offers CC BY-SA 2.5, GPL, LGPL and others, and was missing CC BY 4.0. **Done 2026-10-24:** the list is now CC BY 4.0 (own work), `Loftia_owned` (© Qloud Games, all rights reserved) and PD. Also added `Template:CC-BY-4.0`. loftia.gg publishes no fan-content or screenshot licence. |
| 6 | Spam | Turnstile fixed. AbuseFilter, SpamBlacklist, TitleBlacklist and Nuke are loaded. AbuseFilter has no filters yet, so add some. |
| 7 | About, disclaimer | `Loftia:About` and `Loftia:General_disclaimer` don't exist (404), even though they're in `$wgWhitelistRead`. **Done 2026-10-24.** |
| 8 | Footer | `MediaWiki:Citizen-footer-desc` and `MediaWiki:Citizen-footer-tagline` were never created. **Done 2026-10-24.** |
| 9 | Privacy date | Confirmed. The source is `''Last updated: {{CURRENTYEAR}}-{{CURRENTMONTH}}-{{CURRENTDAY}}''`, and the last revision was 2025-04-22. **Done 2026-10-24:** now `''Last updated: 2025-04-22''`. |
| 10 | Add links, Badtitle | "Add links" comes from WikibaseClient's site-link widget. Wikibase holds 371 items and 11 properties, so keep it and hide the widget with CSS. Badtitle is a login-wall artefact and goes away once reading is open. |

## Decide before opening

- **`Alpha_NDA` (11.8 kB), `Secrets` and `Admin_Discords`** become public. `Admin_Discords` is already in `$wgWhitelistRead`. Check that this is intended, and delete or protect what isn't.
- **Admin roster.** Sysops: Admin, Pi, WannaCry, Isy, Bunky, Amy. Bureaucrats: Admin, Pi, WannaCry, Isy. Only Admin and Pi have a confirmed email. `LaunchSettings.php` sets `$wgEmailConfirmToEdit`, so **the others can't edit until they confirm**. Ask them to do that before 11-03.
- **Thin content.** There are 15 articles, 14 of them uncategorised. Orphans: Admin_Discords, Alpha_NDA, Plastic_Discards. Red links: `Loftia:Rules` (linked from the Main Page), `Template:Button`, `Loftia:Interface_administrators` and `Module:*/doc`. There are no broken or double redirects, because the wiki has no redirects at all.

## Backups

The nightly restic run succeeded at 03:40 on 2026-10-24. It covers the DB dump, `/mw/images` and `LocalSettings.php`. It is local only (`/stor`). It does not include `PrelaunchSettings.php`, `LaunchSettings.php`, the Citizen skin, extensions or `resources/assets/loftia*.png`. Add those paths to `nixos/backup.nix`.

## Caching

There's no CDN, and file cache is off. Every logged-out hit runs PHP, with Redis as the parser cache. `LaunchSettings.php` turns on `$wgUseFileCache`. That should be enough for a small wiki. Put it behind Cloudflare if the spike is large.

## Launch day (2026-11-03)

1. Append to `/mw/html/LocalSettings.php`:
   `require_once "$IP/LaunchSettings.php";`
2. Add `/mw/html/robots.txt`:
   ```
   User-agent: *
   Disallow: /index.php?
   Disallow: /api.php
   Disallow: /Special:
   Sitemap: https://loftiawiki.org/sitemap/sitemap-index-loftiawiki.xml
   ```
3. Generate the sitemap (and repeat it nightly):
   `podman exec -u www-data mediawiki php maintenance/run.php generateSitemap --fspath=/var/www/html/sitemap --urlpath=/sitemap/ --server=https://loftiawiki.org --identifier=loftiawiki --compress=no`
4. While logged out, check: the Main Page and a few articles return 200 with no `noindex`; Special:CreateAccount shows Turnstile; the confirmation email arrives; the upload link sends you to log in.
5. Rollback: remove the `LaunchSettings.php` line.

## Contributing guide

Create `Loftia:Contributing`, using the sections from the pre-launch checklist. Link it from `MediaWiki:Sidebar` and the Main Page. Its images section should say CC BY 4.0, to match `$wgRightsUrl`.
