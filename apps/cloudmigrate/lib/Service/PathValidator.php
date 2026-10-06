<?php

declare(strict_types=1);

namespace OCA\CloudMigrate\Service;

class PathValidator {
	/**
	 * Normalize and validate a Nextcloud files path (no leading slash, no traversal).
	 */
	public static function normalizeDestPath(string $base, string $subpath = ''): string {
		$parts = [];
		foreach ([$base, $subpath] as $segment) {
			foreach (explode('/', trim($segment, '/')) as $part) {
				if ($part === '' || $part === '.') {
					continue;
				}
				if ($part === '..') {
					throw new \InvalidArgumentException('Destination path must not contain ..');
				}
				self::assertSegment($part);
				$parts[] = $part;
			}
		}
		if ($parts === []) {
			throw new \InvalidArgumentException('Destination path is required');
		}
		return implode('/', $parts);
	}

	/**
	 * Validate a OneDrive path for Graph API lookup (relative to drive root).
	 */
	public static function normalizeOneDrivePath(string $path): string {
		$path = trim(str_replace('\\', '/', $path), '/');
		if ($path === '') {
			return '';
		}
		$parts = [];
		foreach (explode('/', $path) as $part) {
			if ($part === '' || $part === '.') {
				continue;
			}
			if ($part === '..') {
				throw new \InvalidArgumentException('Source path must not contain ..');
			}
			self::assertSegment($part);
			$parts[] = $part;
		}
		return implode('/', $parts);
	}

	private static function assertSegment(string $part): void {
		if (preg_match('/[\x00-\x1f:*?"<>|]/', $part)) {
			throw new \InvalidArgumentException('Path contains invalid characters');
		}
	}
}
