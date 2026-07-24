<?php

use App\Support\Logger;

return [
    'logger masks secrets and graph download urls' => function (): void {
        $logFile = sys_get_temp_dir() . DIRECTORY_SEPARATOR . 'queue_logger_test_' . uniqid('', true) . '.log';
        $logger = new Logger($logFile);

        $logger->info('CLIENT_SECRET=abc123 token=secret-token DB_PASS=database-secret ADMIN_PASSWORD=admin-secret password=plain-secret Authorization: Bearer bearer-secret https://contoso.sharepoint.com/download.aspx?authkey=secret');

        $content = file_get_contents($logFile);
        assert(str_contains($content, 'CLIENT_SECRET=[masked]'));
        assert(str_contains($content, 'token=[masked]'));
        assert(str_contains($content, 'https://contoso.sharepoint.com/[masked-url]'));
        assert(!str_contains($content, 'abc123'));
        assert(!str_contains($content, 'secret-token'));
        assert(!str_contains($content, 'database-secret'));
        assert(!str_contains($content, 'admin-secret'));
        assert(!str_contains($content, 'plain-secret'));
        assert(!str_contains($content, 'bearer-secret'));

        unlink($logFile);
    },
];
