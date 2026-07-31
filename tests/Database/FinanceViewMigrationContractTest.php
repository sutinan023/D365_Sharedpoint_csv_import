<?php

$readMigration = static function (string $name): string {
    $path = dirname(__DIR__, 2) . '/database/migrations/' . $name;
    if (!is_file($path)) {
        throw new RuntimeException("Migration missing: {$name}");
    }
    $sql = file_get_contents($path);
    if ($sql === false || trim($sql) === '') {
        throw new RuntimeException("Migration unreadable: {$name}");
    }
    return $sql;
};

$assertEnvironmentSafe = static function (string $sql, string $view): void {
    assert(stripos($sql, 'CREATE OR REPLACE ALGORITHM=UNDEFINED SQL SECURITY INVOKER VIEW `' . $view . '`') !== false);
    assert(preg_match('/`?D365_finance(?:_prod)?`?\s*\./i', $sql) === 0);
    assert(stripos($sql, 'SQL SECURITY DEFINER') === false);
};

return [
    'vw import report migration is environment safe' => function () use ($readMigration, $assertEnvironmentSafe): void {
        $sql = $readMigration('004_create_vw_import_report.sql');
        $assertEnvironmentSafe($sql, 'vw_import_report');
        foreach (['`stg_payment_outbound`', '`stg_received_outbound`', '`effective_date`', '`source_type`', 'UNION ALL'] as $required) {
            assert(stripos($sql, $required) !== false);
        }
    },
    'payment advice migration is environment safe' => function () use ($readMigration, $assertEnvironmentSafe): void {
        $sql = $readMigration('005_create_v_tbpayin_from_payment_outbound.sql');
        $assertEnvironmentSafe($sql, 'v_tbpayin_from_payment_outbound');
        foreach (['`payment_outbound`', '`payment_mail_log`', '`fee_total`', '`tax_total`', '`sent_at`', '`recid`'] as $required) {
            assert(stripos($sql, $required) !== false);
        }
    },
];
