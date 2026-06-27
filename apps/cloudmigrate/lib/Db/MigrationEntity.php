<?php

declare(strict_types=1);

namespace OCA\CloudMigrate\Db;

use OCP\AppFramework\Db\Entity;

/**
 * @method int getId()
 * @method void setId(int $id)
 * @method string getUserId()
 * @method void setUserId(string $userId)
 * @method string getProvider()
 * @method void setProvider(string $provider)
 * @method string getStatus()
 * @method void setStatus(string $status)
 * @method string getSourcePath()
 * @method void setSourcePath(string $sourcePath)
 * @method string getSourceItemId()
 * @method void setSourceItemId(string $sourceItemId)
 * @method string getDestPath()
 * @method void setDestPath(string $destPath)
 * @method bool isDryRun()
 * @method void setDryRun(bool $dryRun)
 * @method int getProgress()
 * @method void setProgress(int $progress)
 * @method int getTotalFiles()
 * @method void setTotalFiles(int $totalFiles)
 * @method int getCopiedFiles()
 * @method void setCopiedFiles(int $copiedFiles)
 * @method string|null getErrorMessage()
 * @method void setErrorMessage(?string $errorMessage)
 * @method int getCreatedAt()
 * @method void setCreatedAt(int $createdAt)
 * @method int getUpdatedAt()
 * @method void setUpdatedAt(int $updatedAt)
 */
class MigrationEntity extends Entity {
	protected $userId;
	protected $provider;
	protected $status;
	protected $sourcePath;
	protected $sourceItemId;
	protected $destPath;
	protected $dryRun;
	protected $progress;
	protected $totalFiles;
	protected $copiedFiles;
	protected $errorMessage;
	protected $createdAt;
	protected $updatedAt;

	public function __construct() {
		$this->addType('dryRun', 'boolean');
		$this->addType('progress', 'integer');
		$this->addType('totalFiles', 'integer');
		$this->addType('copiedFiles', 'integer');
		$this->addType('createdAt', 'integer');
		$this->addType('updatedAt', 'integer');
	}
}
