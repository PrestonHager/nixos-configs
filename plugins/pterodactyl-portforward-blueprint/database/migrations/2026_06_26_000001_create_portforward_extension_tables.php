<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

return new class extends Migration
{
    public function up(): void
    {
        Schema::create('portforward_settings', function (Blueprint $table) {
            $table->id();
            $table->string('key')->unique();
            $table->json('value')->nullable();
            $table->timestamps();
        });

        Schema::create('portforward_data', function (Blueprint $table) {
            $table->id();
            $table->string('scope', 32);
            $table->unsignedBigInteger('subject_id');
            $table->string('key', 128);
            $table->json('value')->nullable();
            $table->timestamps();

            $table->unique(['scope', 'subject_id', 'key']);
            $table->index(['scope', 'subject_id']);
        });

        Schema::create('portforward_audit_log', function (Blueprint $table) {
            $table->id();
            $table->unsignedBigInteger('user_id')->nullable();
            $table->unsignedBigInteger('server_id')->nullable();
            $table->string('action', 64);
            $table->text('ios_commands')->nullable();
            $table->text('stdout')->nullable();
            $table->boolean('success')->default(false);
            $table->text('error_message')->nullable();
            $table->timestamps();

            $table->index(['server_id', 'created_at']);
        });
    }

    public function down(): void
    {
        Schema::dropIfExists('portforward_audit_log');
        Schema::dropIfExists('portforward_data');
        Schema::dropIfExists('portforward_settings');
    }
};
