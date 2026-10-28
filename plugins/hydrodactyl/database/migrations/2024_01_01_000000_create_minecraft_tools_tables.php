<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

return new class extends Migration
{
    public function up(): void
    {
        Schema::dropIfExists('minecraft_tools_plugin_configs');
        Schema::dropIfExists('minecraft_tools_modpack_configs');
        Schema::dropIfExists('minecraft_tools_icon_history');
        Schema::dropIfExists('minecraft_tools_config_backups');
        Schema::dropIfExists('minecraft_tools_player_notes');

        Schema::create('minecraft_tools_plugin_configs', function (Blueprint $table) {
            $table->id();
            $table->unsignedInteger('server_id');
            $table->string('plugin_name');
            $table->json('config')->nullable();
            $table->timestamps();

            $table->unique(['server_id', 'plugin_name']);
            $table->foreign('server_id')->references('id')->on('servers')->onDelete('cascade');
        });

        Schema::create('minecraft_tools_modpack_configs', function (Blueprint $table) {
            $table->id();
            $table->unsignedInteger('server_id');
            $table->string('modpack_name');
            $table->json('config')->nullable();
            $table->timestamps();

            $table->unique(['server_id', 'modpack_name']);
            $table->foreign('server_id')->references('id')->on('servers')->onDelete('cascade');
        });

        Schema::create('minecraft_tools_icon_history', function (Blueprint $table) {
            $table->id();
            $table->unsignedInteger('server_id');
            $table->string('url');
            $table->unsignedBigInteger('size')->default(0);
            $table->timestamps();

            $table->foreign('server_id')->references('id')->on('servers')->onDelete('cascade');
        });

        Schema::create('minecraft_tools_config_backups', function (Blueprint $table) {
            $table->id();
            $table->unsignedInteger('server_id');
            $table->string('file');
            $table->text('content');
            $table->unsignedBigInteger('size')->default(0);
            $table->timestamps();

            $table->foreign('server_id')->references('id')->on('servers')->onDelete('cascade');
        });

        Schema::create('minecraft_tools_player_notes', function (Blueprint $table) {
            $table->id();
            $table->unsignedInteger('server_id');
            $table->string('username');
            $table->string('uuid')->nullable();
            $table->text('notes')->nullable();
            $table->string('display_name')->nullable();
            $table->timestamps();

            $table->unique(['server_id', 'username']);
            $table->foreign('server_id')->references('id')->on('servers')->onDelete('cascade');
        });
    }

    public function down(): void
    {
        Schema::dropIfExists('minecraft_tools_player_notes');
        Schema::dropIfExists('minecraft_tools_config_backups');
        Schema::dropIfExists('minecraft_tools_icon_history');
        Schema::dropIfExists('minecraft_tools_modpack_configs');
        Schema::dropIfExists('minecraft_tools_plugin_configs');
    }
};
