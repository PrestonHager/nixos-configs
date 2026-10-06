<?php

return [
    'api' => [
        'spigot' => [
            'base_url' => env('MCT_SPIGOT_URL', 'https://api.spiget.org/v2'),
        ],
        'modrinth' => [
            'base_url' => env('MCT_MODRINTH_URL', 'https://api.modrinth.com/v2'),
        ],
        'curseforge' => [
            'base_url' => env('MCT_CURSEFORGE_URL', 'https://api.curseforge.com/v1'),
            'api_key' => env('MINECRAFT_TOOLS_CURSEFORGE_API_KEY'),
        ],
        'paper' => [
            'base_url' => env('MCT_PAPER_URL', 'https://api.papermc.io/v2'),
        ],
        'fabric' => [
            'base_url' => env('MCT_FABRIC_URL', 'https://meta.fabricmc.net'),
        ],
    ],

    'config_editor' => [
        'allowed_files' => [
            'server.properties',
            'spigot.yml',
            'bukkit.yml',
            'paper.yml',
            'pufferfish.yml',
            'purpur.yml',
            'fabric-server-launcher.properties',
            'forge-server.toml',
            'neoforge-server.toml',
        ],
    ],

    'icon' => [
        'max_size' => 1024 * 1024,
        'dimensions' => [64, 64],
        'history_limit' => 20,
    ],
];