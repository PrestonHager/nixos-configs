<?php

declare(strict_types=1);

namespace OCA\CloudMigrate\Migration;

use Closure;
use OCP\DB\ISchemaWrapper;
use OCP\Migration\SimpleMigrationStep;
use OCP\Migration\IOutput;

class Version1000Date20260627000000 extends SimpleMigrationStep {
	public function changeSchema(IOutput $output, Closure $schemaClosure, array $options): ?ISchemaWrapper {
		/** @var ISchemaWrapper $schema */
		$schema = $schemaClosure();
		if (!$schema->hasTable('cm_migrations')) {
			$table = $schema->createTable('cm_migrations');
			$table->addColumn('id', 'bigint', [
				'autoincrement' => true,
				'notnull' => true,
				'unsigned' => true,
			]);
			$table->addColumn('user_id', 'string', ['notnull' => true, 'length' => 64]);
			$table->addColumn('provider', 'string', ['notnull' => true, 'length' => 32]);
			$table->addColumn('status', 'string', ['notnull' => true, 'length' => 32]);
			$table->addColumn('source_path', 'string', ['notnull' => true, 'length' => 4000]);
			$table->addColumn('source_item_id', 'string', ['notnull' => true, 'length' => 256]);
			$table->addColumn('dest_path', 'string', ['notnull' => true, 'length' => 4000]);
			$table->addColumn('dry_run', 'boolean', ['notnull' => true, 'default' => false]);
			$table->addColumn('progress', 'integer', ['notnull' => true, 'default' => 0]);
			$table->addColumn('total_files', 'integer', ['notnull' => true, 'default' => 0]);
			$table->addColumn('copied_files', 'integer', ['notnull' => true, 'default' => 0]);
			$table->addColumn('error_message', 'text', ['notnull' => false]);
			$table->addColumn('created_at', 'bigint', ['notnull' => true, 'unsigned' => true]);
			$table->addColumn('updated_at', 'bigint', ['notnull' => true, 'unsigned' => true]);
			$table->setPrimaryKey(['id']);
			$table->addIndex(['user_id'], 'cm_migrations_user');
			$table->addIndex(['status'], 'cm_migrations_status');
		}
		return $schema;
	}
}
