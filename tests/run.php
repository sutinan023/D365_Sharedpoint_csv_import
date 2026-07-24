<?php

require __DIR__ . '/bootstrap.php';

$files = [
    __DIR__ . '/Config/AppConfigTest.php',
    __DIR__ . '/Support/LoggerTest.php',
    __DIR__ . '/Queue/FileQueueRepositoryTest.php',
    __DIR__ . '/SharePoint/SharePointClientTest.php',
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
