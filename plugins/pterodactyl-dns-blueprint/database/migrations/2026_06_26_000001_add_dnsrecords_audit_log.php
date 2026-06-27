<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

return new class extends Migration
{
    public function up(): void
    {
        Schema::create('dnsrecords_audit_log', function (Blueprint $table) {
            $table->id();
            $table->unsignedBigInteger('user_id')->nullable();
            $table->unsignedBigInteger('server_id')->nullable();
            $table->string('action', 64);
            $table->string('provider', 32);
            $table->string('record_name', 255);
            $table->json('details')->nullable();
            $table->timestamps();

            $table->index(['server_id', 'created_at']);
            $table->index('created_at');
        });
    }

    public function down(): void
    {
        Schema::dropIfExists('dnsrecords_audit_log');
    }
};
