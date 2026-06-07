<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

return new class extends Migration
{
    public function up(): void
    {
        Schema::create('dnsrecords_settings', function (Blueprint $table) {
            $table->id();
            $table->string('key')->unique();
            $table->json('value')->nullable();
            $table->timestamps();
        });

        Schema::create('dnsrecords_data', function (Blueprint $table) {
            $table->id();
            $table->string('scope', 32);
            $table->unsignedBigInteger('subject_id');
            $table->string('key', 128);
            $table->json('value')->nullable();
            $table->timestamps();

            $table->unique(['scope', 'subject_id', 'key']);
            $table->index(['scope', 'subject_id']);
        });
    }

    public function down(): void
    {
        Schema::dropIfExists('dnsrecords_data');
        Schema::dropIfExists('dnsrecords_settings');
    }
};
