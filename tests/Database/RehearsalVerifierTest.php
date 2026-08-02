<?php

use App\Database\RehearsalVerifier;

function rehearsalVerifierExpect(bool $condition, string $message): void
{
    if (!$condition) {
        throw new RuntimeException($message);
    }
}

function rehearsalVerifierFixture(string $database): PDO
{
    $pdo = new PDO('sqlite::memory:');
    $pdo->sqliteCreateFunction('DATABASE', static fn (): string => $database);
    $pdo->exec("ATTACH DATABASE ':memory:' AS {$database}");
    $pdo->exec("ATTACH DATABASE ':memory:' AS information_schema");
    foreach (['import_files' => 2, 'payment_outbound' => 3, 'payment_mail_log' => 0, 'sharepoint_file_queue' => 1] as $table => $count) {
        $pdo->exec("CREATE TABLE {$database}.{$table} (id INTEGER)");
        for ($index = 0; $index < $count; $index++) {
            $pdo->exec("INSERT INTO {$database}.{$table} VALUES ({$index})");
        }
    }
    $pdo->exec("CREATE TABLE {$database}.vw_import_report (id INTEGER)");
    $pdo->exec("INSERT INTO {$database}.vw_import_report VALUES (1), (2)");
    $pdo->exec("CREATE TABLE {$database}.v_tbpayin_from_payment_outbound (id INTEGER)");
    $pdo->exec("INSERT INTO {$database}.v_tbpayin_from_payment_outbound VALUES (1)");
    $pdo->exec('CREATE TABLE information_schema.VIEWS (TABLE_SCHEMA TEXT, TABLE_NAME TEXT, VIEW_DEFINITION TEXT, SECURITY_TYPE TEXT)');
    $pdo->exec("INSERT INTO information_schema.VIEWS VALUES ('{$database}','vw_import_report','SELECT * FROM payment_outbound','INVOKER')");
    $pdo->exec("INSERT INTO information_schema.VIEWS VALUES ('{$database}','v_tbpayin_from_payment_outbound','SELECT * FROM import_files','INVOKER')");
    return $pdo;
}

$baseline = [
    'database' => 'D365_finance_prod',
    'row_counts' => ['import_files' => 2, 'payment_outbound' => 3, 'payment_mail_log' => 0, 'sharepoint_file_queue' => 1],
    'views' => [
        'vw_import_report' => ['row_count' => 2, 'security_type' => 'DEFINER'],
        'v_tbpayin_from_payment_outbound' => ['row_count' => 1, 'security_type' => 'INVOKER'],
    ],
];

return [
    'rehearsal verifier accepts an isolated matching restore' => function () use ($baseline): void {
        $database = 'D365_finance_prod_rehearsal_20260802_1';
        $result = (new RehearsalVerifier(rehearsalVerifierFixture($database)))->verify($database, $baseline);
        rehearsalVerifierExpect($result['status'] === 'VERIFIED', 'rehearsal was not verified');
        rehearsalVerifierExpect($result['row_counts'] === $baseline['row_counts'], 'rehearsal row counts differ');
        rehearsalVerifierExpect($result['views']['vw_import_report']['security_type'] === 'INVOKER', 'view is not invoker');
        rehearsalVerifierExpect($result['live_schema_reference_count'] === 0, 'live schema reference remained');
    },
    'rehearsal verifier rejects a production database name' => function () use ($baseline): void {
        try {
            (new RehearsalVerifier(new PDO('sqlite::memory:')))->verify('D365_finance_prod', $baseline);
            throw new RuntimeException('live Production database was accepted');
        } catch (RuntimeException $exception) {
            rehearsalVerifierExpect(str_contains($exception->getMessage(), 'rehearsal'), 'unsafe database failure was unclear');
        }
    },
    'rehearsal verifier rejects count drift' => function () use ($baseline): void {
        $database = 'D365_finance_prod_rehearsal_20260802_2';
        $pdo = rehearsalVerifierFixture($database);
        $pdo->exec("INSERT INTO {$database}.import_files VALUES (99)");
        try {
            (new RehearsalVerifier($pdo))->verify($database, $baseline);
            throw new RuntimeException('row-count drift was accepted');
        } catch (RuntimeException $exception) {
            rehearsalVerifierExpect(str_contains($exception->getMessage(), 'row count'), 'row drift failure was unclear');
        }
    },
    'rehearsal verifier rejects definer and live references' => function () use ($baseline): void {
        $database = 'D365_finance_prod_rehearsal_20260802_3';
        $pdo = rehearsalVerifierFixture($database);
        $pdo->exec("UPDATE information_schema.VIEWS SET SECURITY_TYPE='DEFINER', VIEW_DEFINITION='SELECT * FROM `D365_finance_prod`.`payment_outbound`' WHERE TABLE_NAME='vw_import_report'");
        try {
            (new RehearsalVerifier($pdo))->verify($database, $baseline);
            throw new RuntimeException('unsafe view was accepted');
        } catch (RuntimeException $exception) {
            rehearsalVerifierExpect(str_contains($exception->getMessage(), 'INVOKER') || str_contains($exception->getMessage(), 'Production'), 'view failure was unclear');
        }
    },
    'rehearsal verifier accepts only narrow read grants' => function (): void {
        RehearsalVerifier::assertReadOnlyGrants([
            "GRANT USAGE ON *.* TO `reader`@`localhost`",
            "GRANT SELECT ON `D365\\_finance\\_prod\\_rehearsal\\_%`.* TO `reader`@`localhost`",
        ], 'D365_finance_prod_rehearsal_20260802_1');
        foreach ([
            ["GRANT ALL PRIVILEGES ON *.* TO `reader`@`localhost`"],
            ["GRANT SELECT ON `D365_finance_prod`.* TO `reader`@`localhost`"],
            ["GRANT SELECT, INSERT ON `D365\\_finance\\_prod\\_rehearsal\\_%`.* TO `reader`@`localhost`"],
        ] as $grants) {
            try {
                RehearsalVerifier::assertReadOnlyGrants($grants, 'D365_finance_prod_rehearsal_20260802_1');
                throw new RuntimeException('unsafe grant was accepted');
            } catch (RuntimeException $exception) {
                rehearsalVerifierExpect(str_contains($exception->getMessage(), 'grant'), 'grant failure was unclear');
            }
        }
    },
];
