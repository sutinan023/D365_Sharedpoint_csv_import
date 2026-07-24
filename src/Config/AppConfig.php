<?php

namespace App\Config;

final class AppConfig
{
    public function __construct(
        public readonly string $rootDir,
        public readonly string $sourceFolder,
        public readonly string $processedFolder,
        public readonly string $downloadDir,
        public readonly string $archiveDir,
        public readonly string $errorDir,
        public readonly int $retryAttempts,
        public readonly string $lockFile,
    ) {
    }

    public static function fromEnv(string $rootDir): self
    {
        return new self(
            rtrim($rootDir, "\\/"),
            $_ENV['CSV_FOLDER'] ?? 'PaymentBeforePost',
            $_ENV['CSV_DOWNLOADED_FOLDER'] ?? 'PaymentBeforePost_Downloaded',
            self::resolvePath($rootDir, $_ENV['CSV_LOCAL_DOWNLOAD_DIR'] ?? 'download'),
            self::resolvePath($rootDir, $_ENV['CSV_LOCAL_ARCHIVE_DIR'] ?? 'archive'),
            self::resolvePath($rootDir, $_ENV['CSV_LOCAL_ERROR_DIR'] ?? 'error'),
            max(1, (int)($_ENV['GRAPH_RETRY_ATTEMPTS'] ?? 3)),
            self::resolvePath($rootDir, $_ENV['PIPELINE_LOCK_FILE'] ?? 'temp/pipeline.lock'),
        );
    }

    public function path(string $relativeOrAbsolute): string
    {
        return self::resolvePath($this->rootDir, $relativeOrAbsolute);
    }

    private static function resolvePath(string $rootDir, string $path): string
    {
        if ($path === '/') {
            return '/';
        }

        if (str_starts_with($path, '/')) {
            return rtrim($path, '/');
        }

        $path = str_replace(['/', '\\'], DIRECTORY_SEPARATOR, $path);

        if (preg_match('/^[A-Za-z]:[\\\\\\/]/', $path) === 1 || str_starts_with($path, '\\\\')) {
            return rtrim($path, "\\/");
        }

        return rtrim($rootDir, "\\/") . DIRECTORY_SEPARATOR . trim($path, "\\/");
    }
}
