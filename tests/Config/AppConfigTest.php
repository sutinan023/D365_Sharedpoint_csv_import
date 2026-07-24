<?php

use App\Config\AppConfig;

return [
    'app config reads queue defaults' => function (): void {
        $_ENV['CSV_FOLDER'] = 'PaymentBeforePost';
        $_ENV['CSV_DOWNLOADED_FOLDER'] = 'PaymentBeforePost_Downloaded';
        $_ENV['CSV_LOCAL_DOWNLOAD_DIR'] = 'download';
        $_ENV['CSV_LOCAL_ARCHIVE_DIR'] = 'archive';
        $_ENV['CSV_LOCAL_ERROR_DIR'] = 'error';
        $_ENV['GRAPH_RETRY_ATTEMPTS'] = '3';
        $_ENV['PIPELINE_LOCK_FILE'] = 'temp/pipeline.lock';

        $config = AppConfig::fromEnv(dirname(__DIR__, 2));

        assert($config->sourceFolder === 'PaymentBeforePost');
        assert($config->processedFolder === 'PaymentBeforePost_Downloaded');
        assert($config->retryAttempts === 3);
        assert(str_ends_with($config->downloadDir, DIRECTORY_SEPARATOR . 'download'));
        assert(str_ends_with($config->archiveDir, DIRECTORY_SEPARATOR . 'archive'));
        assert(str_ends_with($config->errorDir, DIRECTORY_SEPARATOR . 'error'));
        assert(str_ends_with($config->lockFile, DIRECTORY_SEPARATOR . 'temp' . DIRECTORY_SEPARATOR . 'pipeline.lock'));
    },
    'app config preserves POSIX absolute paths' => function (): void {
        $config = AppConfig::fromEnv(dirname(__DIR__, 2));

        assert($config->path('/var/lib/csv-import') === '/var/lib/csv-import');
        assert($config->path('/') === '/');
    },
];
