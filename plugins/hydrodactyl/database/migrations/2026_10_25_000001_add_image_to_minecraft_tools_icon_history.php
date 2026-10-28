<?php

use Illuminate\Support\Facades\Schema;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Database\Migrations\Migration;

// Icon history now keeps the 64x64 PNG itself (data URI) so an old icon can
// be restored; the Blueprint stub only stored a URL string.
return new class extends Migration {
    public function up(): void
    {
        if (!Schema::hasColumn('minecraft_tools_icon_history', 'image')) {
            Schema::table('minecraft_tools_icon_history', function (Blueprint $table) {
                $table->longText('image')->nullable()->after('url');
            });
        }
    }

    public function down(): void
    {
        Schema::table('minecraft_tools_icon_history', function (Blueprint $table) {
            $table->dropColumn('image');
        });
    }
};
