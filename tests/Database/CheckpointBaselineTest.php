<?php

use App\Database\CheckpointBaseline;

function checkpointBaselineExpect(bool $condition, string $message): void
{
    if (!$condition) {
        throw new RuntimeException($message);
    }
}

return [
    'checkpoint baseline captures production counts and view contracts' => function (): void {
        $pdo = new PDO('sqlite::memory:');
        $pdo->exec("ATTACH DATABASE ':memory:' AS D365_finance_prod");
        $pdo->exec("ATTACH DATABASE ':memory:' AS information_schema");
        foreach (['import_files' => 2, 'payment_outbound' => 3, 'payment_mail_log' => 0, 'sharepoint_file_queue' => 1] as $table => $count) {
            $pdo->exec("CREATE TABLE D365_finance_prod.{$table} (id INTEGER)");
            for ($index = 0; $index < $count; $index++) {
                $pdo->exec("INSERT INTO D365_finance_prod.{$table} VALUES ({$index})");
            }
        }
        $pdo->exec('CREATE TABLE D365_finance_prod.vw_import_report (id INTEGER)');
        $pdo->exec('INSERT INTO D365_finance_prod.vw_import_report VALUES (1), (2)');
        $pdo->exec('CREATE TABLE D365_finance_prod.v_tbpayin_from_payment_outbound (id INTEGER)');
        $pdo->exec('INSERT INTO D365_finance_prod.v_tbpayin_from_payment_outbound VALUES (1)');
        $pdo->exec('CREATE TABLE information_schema.VIEWS (TABLE_SCHEMA TEXT, TABLE_NAME TEXT, VIEW_DEFINITION TEXT, SECURITY_TYPE TEXT)');
        $pdo->exec("INSERT INTO information_schema.VIEWS VALUES ('D365_finance_prod','vw_import_report','SELECT * FROM `D365_finance_prod`.`payment_outbound`','DEFINER')");
        $pdo->exec("INSERT INTO information_schema.VIEWS VALUES ('D365_finance_prod','v_tbpayin_from_payment_outbound','SELECT * FROM `D365_finance_prod`.`payment_outbound` JOIN `D365_finance_prod`.`import_files`','INVOKER')");

        $baseline = (new CheckpointBaseline($pdo))->capture('D365_finance_prod');
        checkpointBaselineExpect($baseline['database'] === 'D365_finance_prod', 'baseline database is wrong');
        checkpointBaselineExpect($baseline['row_counts'] === [
            'import_files' => 2,
            'payment_outbound' => 3,
            'payment_mail_log' => 0,
            'sharepoint_file_queue' => 1,
        ], 'baseline row counts are wrong');
        checkpointBaselineExpect($baseline['views']['vw_import_report'] === ['row_count' => 2, 'security_type' => 'DEFINER'], 'first view contract is wrong');
        checkpointBaselineExpect($baseline['views']['v_tbpayin_from_payment_outbound'] === ['row_count' => 1, 'security_type' => 'INVOKER'], 'second view contract is wrong');
        checkpointBaselineExpect($baseline['live_schema_reference_count'] === 3, 'live schema references are wrong');
        checkpointBaselineExpect($baseline['definer_count'] === 1, 'definer count is wrong');
        checkpointBaselineExpect($baseline['qualified_reference_count'] === 3, 'qualified reference count is wrong');
    },
    'checkpoint baseline rejects a non production database' => function (): void {
        $pdo = new PDO('sqlite::memory:');
        try {
            (new CheckpointBaseline($pdo))->capture('D365_finance');
            throw new RuntimeException('non-production database was accepted');
        } catch (RuntimeException $exception) {
            checkpointBaselineExpect(str_contains($exception->getMessage(), 'D365_finance_prod'), 'wrong database failure was unclear');
        }
    },
];
