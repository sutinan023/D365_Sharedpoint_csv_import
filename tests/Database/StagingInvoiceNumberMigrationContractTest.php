<?php

return [
    'staging invoice migration widens text without destructive SQL' => function (): void {
        $path = dirname(__DIR__, 2) . '/database/migrations/006_expand_stg_payment_before_post_invoice_number.sql';
        assert(is_file($path), 'Migration 006 is missing.');
        $sql = (string) file_get_contents($path);
        assert(preg_match('/ALTER\s+TABLE\s+`?stg_payment_before_post`?/i', $sql) === 1);
        assert(preg_match('/MODIFY\s+(?:COLUMN\s+)?`?invoice_number`?\s+VARCHAR\s*\(\s*255\s*\)\s+NULL/i', $sql) === 1);
        assert(preg_match('/\b(DROP|DELETE|TRUNCATE)\b/i', $sql) === 0);
        assert(preg_match('/ALTER\s+TABLE\s+`?payment_before_post`?/i', $sql) === 0);
        assert(preg_match('/D365_finance(?:_prod)?\s*\./i', $sql) === 0);
    },
];
