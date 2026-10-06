<?php

declare(strict_types=1);

namespace OCA\CloudMigrate\Migration;

use Closure;
use OCP\DB\ISchemaWrapper;
use OCP\Migration\IOutput;
use OCP\Migration\SimpleMigrationStep;

class Version1001Date20260627120000 extends SimpleMigrationStep {
	public function changeSchema(IOutput $output, Closure $schemaClosure, array $options): ?ISchemaWrapper {
		/** @var ISchemaWrapper $schema */
		$schema = $schemaClosure();
		if (!$schema->hasTable('cm_migrations')) {
			return $schema;
		}
		$table = $schema->getTable('cm_migrations');
		if (!$table->hasColumn('status_text')) {
			$table->addColumn('status_text', 'text', ['notnull' => false]);
		}
		if (!$table->hasColumn('phase')) {
			$table->addColumn('phase', 'string', ['notnull' => false, 'length' => 32, 'default' => '']);
		}
		if (!$table->hasColumn('worker_pid')) {
			$table->addColumn('worker_pid', 'integer', ['notnull' => false, 'unsigned' => true]);
		}
		if (!$table->hasColumn('checkpoint')) {
			$table->addColumn('checkpoint', 'string', ['notnull' => false, 'length' => 4000]);
		}
		return $schema;
	}
}
