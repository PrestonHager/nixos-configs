@php
    $defaultSrvJson = json_encode($defaultSrvProfiles ?? [], JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES);
    $defaultDomainsJson = json_encode($defaultPrimaryDomains ?? [], JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES);
@endphp

<div hidden aria-hidden="true">
    <div data-dns-help-panel="srv-profiles">
        <h5>Purpose</h5>
        <p>SRV profiles define reusable game and service templates. When a profile is enabled for a server, the extension creates an SRV record such as <code>_minecraft._tcp.myserver.prestonhager.com</code> pointing at the server hostname and allocation port.</p>
        <p>Profiles listed here are global defaults. Per-server toggles live on each server’s <strong>DNS</strong> tab under <em>SRV Profiles</em>.</p>

        <h5>JSON structure</h5>
        <p>Enter a JSON <strong>array</strong> of profile objects. Each object describes one selectable SRV template.</p>
        <pre>{{ $defaultSrvJson }}</pre>

        <h5>Fields</h5>
        <table>
            <thead>
                <tr>
                    <th>Field</th>
                    <th>Required</th>
                    <th>Description</th>
                </tr>
            </thead>
            <tbody>
                <tr>
                    <td><code>id</code></td>
                    <td>Yes</td>
                    <td>Unique profile key (lowercase, dashes). Used in server state and API. Example: <code>minecraft-java</code>.</td>
                </tr>
                <tr>
                    <td><code>preset</code></td>
                    <td>No*</td>
                    <td>Built-in game preset. When set, <code>service</code> and <code>proto</code> come from the preset unless you override them. *Either <code>preset</code> or both <code>service</code> + <code>proto</code> are required.</td>
                </tr>
                <tr>
                    <td><code>label</code></td>
                    <td>No</td>
                    <td>Human-readable name in the admin UI. Defaults to the preset label or <code>id</code>.</td>
                </tr>
                <tr>
                    <td><code>service</code></td>
                    <td>Conditional</td>
                    <td>SRV service name with or without leading underscore. Example: <code>_minecraft</code> or <code>minecraft</code>. Required when no <code>preset</code> is set.</td>
                </tr>
                <tr>
                    <td><code>proto</code></td>
                    <td>Conditional</td>
                    <td>Transport protocol: <code>_tcp</code> or <code>_udp</code> (with or without leading underscore). Required when no <code>preset</code> is set.</td>
                </tr>
                <tr>
                    <td><code>port</code></td>
                    <td>No</td>
                    <td>Fixed SRV port. Omit to use the server’s <strong>primary allocation port</strong> (recommended for Pterodactyl game servers).</td>
                </tr>
                <tr>
                    <td><code>priority</code></td>
                    <td>No</td>
                    <td>SRV priority (RFC 2782). Default <code>0</code>.</td>
                </tr>
                <tr>
                    <td><code>weight</code></td>
                    <td>No</td>
                    <td>SRV weight for load balancing. Default <code>5</code>.</td>
                </tr>
                <tr>
                    <td><code>auto_provision</code></td>
                    <td>No</td>
                    <td>When <code>true</code>, this profile is enabled automatically when a server finishes installing (if global auto-provision is on). Default <code>false</code>.</td>
                </tr>
                <tr>
                    <td><code>target_provider</code></td>
                    <td>No</td>
                    <td>Override DNS provider for this profile only: <code>cloudflare</code>, <code>technitium</code>, <code>both</code>, or omit/<code>inherit</code> to use the global provider mode.</td>
                </tr>
            </tbody>
        </table>

        <h5>Built-in presets</h5>
        <table>
            <thead>
                <tr>
                    <th>Preset</th>
                    <th>Service</th>
                    <th>Proto</th>
                    <th>Typical use</th>
                </tr>
            </thead>
            <tbody>
                <tr><td><code>minecraft-java</code></td><td><code>_minecraft</code></td><td><code>_tcp</code></td><td>Java Edition (port from allocation, usually 25565)</td></tr>
                <tr><td><code>minecraft-bedrock</code></td><td><code>_minecraft</code></td><td><code>_udp</code></td><td>Bedrock Edition</td></tr>
                <tr><td><code>factorio</code></td><td><code>_factorio</code></td><td><code>_udp</code></td><td>Factorio multiplayer</td></tr>
                <tr><td><code>terraria</code></td><td><code>_terraria</code></td><td><code>_tcp</code></td><td>Terraria</td></tr>
                <tr><td><code>rust</code></td><td><code>_rust</code></td><td><code>_tcp</code></td><td>Rust</td></tr>
                <tr><td><code>valheim</code></td><td><code>_valheim</code></td><td><code>_udp</code></td><td>Valheim</td></tr>
                <tr><td><code>ark</code></td><td><code>_ark</code></td><td><code>_udp</code></td><td>ARK: Survival Evolved</td></tr>
                <tr><td><code>mumble</code></td><td><code>_mumble</code></td><td><code>_tcp</code></td><td>Mumble voice</td></tr>
            </tbody>
        </table>

        <h5>How records are named</h5>
        <p>For profile <code>minecraft-java</code>, hostname label <code>ead</code>, and primary domain <code>prestonhager.com</code> on node <code>crux.lc1.nm.us.prestonhager.com</code>:</p>
        <ul>
            <li>CNAME: <code>ead.prestonhager.com</code> → <code>crux.lc1.nm.us.prestonhager.com</code> (node FQDN, not LAN IP)</li>
            <li>SRV record: <code>_minecraft._tcp.ead.prestonhager.com</code> → node FQDN + allocation port</li>
        </ul>
        <p>Game clients should connect via SRV. The CNAME gives bare-hostname lookups a stable public target without publishing <code>192.168.x.x</code> addresses to Cloudflare.</p>

        <h5>Validation rules</h5>
        <ul>
            <li>Must be valid JSON array syntax.</li>
            <li>Each profile needs a unique non-empty <code>id</code>.</li>
            <li>Unknown <code>preset</code> values cause a save/runtime error.</li>
            <li><code>proto</code> must be <code>_tcp</code> or <code>_udp</code>.</li>
            <li>Duplicate <code>id</code> values are ignored (first wins).</li>
        </ul>

        <h5>Homelab defaults (prestonhager.com)</h5>
        <p>The shipped defaults auto-provision <strong>Minecraft Java</strong> and <strong>Factorio</strong> on install. Other profiles are available on the server DNS tab but not enabled automatically.</p>
        <p><code>generic-tcp</code> and <code>generic-udp</code> use <code>_game</code> as a placeholder service for custom games—change <code>service</code> to match your game’s SRV convention.</p>

        <h5>Common mistakes</h5>
        <ul>
            <li>Using a single object instead of an array — wrap profiles in <code>[ ... ]</code>.</li>
            <li>Setting a fixed <code>port</code> when Pterodactyl assigns dynamic ports — omit <code>port</code> so the primary allocation is used.</li>
            <li>Mixing Bedrock (<code>_udp</code>) and Java (<code>_tcp</code>) under one profile — use separate profiles.</li>
            <li>Trailing commas in JSON — invalid in strict JSON parsers.</li>
            <li>Expecting SRV alone without a hostname alias — the extension creates a CNAME to the node FQDN when provisioning.</li>
            <li>Creating A records with LAN IPs — use CNAME to the node FQDN or rely on SRV only.</li>
        </ul>
    </div>

    <div data-dns-help-panel="primary-domains">
        <h5>Purpose</h5>
        <p>Primary domains control which DNS zone apex is used for server vanity hostnames. Each game server gets a label (for example <code>ead</code>) appended to a primary domain, producing <code>ead.prestonhager.com</code>.</p>
        <p>You do <strong>not</strong> need to list your main zone here. The extension always exposes an implicit <code>default</code> domain from <strong>Base domain</strong> and <strong>Default zone ID</strong> above.</p>

        <h5>JSON structure</h5>
        <p>Enter a JSON <strong>array</strong> of additional domain objects. Use an empty array <code>[]</code> when every server should use only the base domain.</p>
        <pre>{{ $defaultDomainsJson !== '[]' ? $defaultDomainsJson : "[\n  {\n    \"id\": \"games\",\n    \"domain\": \"games.example.com\",\n    \"zone_id\": \"your-cloudflare-zone-id\",\n    \"client_selectable\": true\n  }\n]" }}</pre>

        <h5>Fields</h5>
        <table>
            <thead>
                <tr>
                    <th>Field</th>
                    <th>Required</th>
                    <th>Description</th>
                </tr>
            </thead>
            <tbody>
                <tr>
                    <td><code>id</code></td>
                    <td>No</td>
                    <td>Stable selector key for admins and API. Auto-generated from <code>domain</code> if omitted (slugified). Cannot be <code>default</code> — that id is reserved for the base domain.</td>
                </tr>
                <tr>
                    <td><code>domain</code></td>
                    <td>Yes</td>
                    <td>Zone apex or delegated hostname base, e.g. <code>prestonhager.com</code> or <code>games.example.com</code>. Trailing dots are stripped.</td>
                </tr>
                <tr>
                    <td><code>zone_id</code></td>
                    <td>No</td>
                    <td>Cloudflare zone ID for this domain. Defaults to <strong>Default zone ID</strong> when omitted. Required when the domain lives in a different Cloudflare zone than the base domain.</td>
                </tr>
                <tr>
                    <td><code>client_selectable</code></td>
                    <td>No</td>
                    <td>When <code>true</code>, clients can pick this domain when changing their vanity hostname (subject to client subdomain policy). Default <code>true</code>.</td>
                </tr>
            </tbody>
        </table>

        <h5>Implicit default domain</h5>
        <p>Always available without JSON configuration:</p>
        <ul>
            <li><code>id</code>: <code>default</code></li>
            <li><code>domain</code>: value of <strong>Base domain</strong> (e.g. <code>prestonhager.com</code>)</li>
            <li><code>zone_id</code>: value of <strong>Default zone ID</strong></li>
            <li><code>client_selectable</code>: <code>true</code></li>
        </ul>

        <h5>prestonhager.com homelab notes</h5>
        <ul>
            <li>Technitium authoritative zone and Cloudflare public zone both use <code>prestonhager.com</code> — set provider mode to <strong>Both</strong>.</li>
            <li>Game SRV targets often point at <code>game.prestonhager.com</code> (a CNAME to ace); that is the SRV <em>target host</em>, not a primary domain entry.</li>
            <li>Leave this array empty unless you operate additional hosted zones (e.g. a separate <code>games.example.com</code> zone).</li>
            <li>Technitium-only zones do not use Cloudflare <code>zone_id</code>; the extension uses <strong>Technitium default zone</strong> for Technitium writes.</li>
        </ul>

        <h5>Validation rules</h5>
        <ul>
            <li>Must be valid JSON array syntax.</li>
            <li>Each entry needs a non-empty <code>domain</code>.</li>
            <li>Duplicate <code>id</code> values are skipped (first wins).</li>
            <li>Reserved id <code>default</code> cannot appear in this list.</li>
        </ul>

        <h5>Common mistakes</h5>
        <ul>
            <li>Adding <code>prestonhager.com</code> here — it is already the implicit default; duplicate entries are unnecessary.</li>
            <li>Using a single hostname like <code>game.prestonhager.com</code> as a primary domain — primary domains must be zone apexes, not individual hostnames.</li>
            <li>Omitting <code>zone_id</code> for a domain in a different Cloudflare account/zone — records will be written to the wrong zone.</li>
            <li>Setting <code>client_selectable: false</code> but expecting clients to choose that domain — only admin-assigned servers can use it.</li>
        </ul>
    </div>
</div>
