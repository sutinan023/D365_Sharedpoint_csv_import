<?php

require __DIR__ . '/bootstrap.php';

$files = [
    __DIR__ . '/Config/AppConfigTest.php',
    __DIR__ . '/Config/EnvironmentGuardTest.php',
    __DIR__ . '/Config/EnvironmentBannerTest.php',
    __DIR__ . '/Database/MigrationRunnerTest.php',
    __DIR__ . '/Database/FinanceViewMigrationContractTest.php',
    __DIR__ . '/Database/SchemaInventoryTest.php',
    __DIR__ . '/Database/CheckpointBaselineTest.php',
    __DIR__ . '/Database/RehearsalVerifierTest.php',
    __DIR__ . '/Database/BackupCheckpointValidatorTest.php',
    __DIR__ . '/Support/LoggerTest.php',
    __DIR__ . '/Queue/FileQueueRepositoryTest.php',
    __DIR__ . '/SharePoint/SharePointClientTest.php',
    __DIR__ . '/SharePoint/DownloadQueueTest.php',
    __DIR__ . '/Import/PaymentBeforePostImporterTest.php',
    __DIR__ . '/Import/ImportQueueTest.php',
    __DIR__ . '/Maintenance/DownloadCleanupTest.php',
    __DIR__ . '/Support/PipelineLockTest.php',
    __DIR__ . '/Monitor/MonitorQueryTest.php',
];

$passed = 0;

foreach ($files as $file) {
    $tests = require $file;
    foreach ($tests as $name => $test) {
        $test();
        echo "PASS {$name}\n";
        $passed++;
    }
}

echo "Tests passed: {$passed}\n";
