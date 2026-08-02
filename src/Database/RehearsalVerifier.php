<?php
declare(strict_types=1);

namespace App\Database;

use PDO;
use RuntimeException;

final class RehearsalVerifier
{
    private const TABLES = ['import_files', 'payment_outbound', 'payment_mail_log', 'sharepoint_file_queue'];
    private const VIEWS = ['vw_import_report', 'v_tbpayin_from_payment_outbound'];

    public function __construct(private readonly PDO $pdo)
    {
    }

    public function verify(string $database, array $baseline): array
    {
        if (preg_match('/^D365_finance_prod_rehearsal_[A-Za-z0-9_]+$/', $database) !== 1) {
            throw new RuntimeException('Database name is not an approved Production rehearsal database.');
        }
        if (($baseline['database'] ?? null) !== 'D365_finance_prod') {
            throw new RuntimeException('Checkpoint baseline is not from D365_finance_prod.');
        }
        if (strcasecmp((string)$this->pdo->query('SELECT DATABASE()')->fetchColumn(), $database) !== 0) {
            throw new RuntimeException('Rehearsal verifier connected to the wrong database.');
        }

        $rowCounts = [];
        foreach (self::TABLES as $table) {
            $rowCounts[$table] = $this->countObject($database, $table);
            if (!isset($baseline['row_counts'][$table]) || $rowCounts[$table] !== $baseline['row_counts'][$table]) {
                throw new RuntimeException("Rehearsal row count differs from checkpoint: {$table}");
            }
        }

        $definitions = $this->viewDefinitions($database);
        $views = [];
        $liveReferences = 0;
        $livePattern = '/(?<![A-Za-z0-9_])`?D365_finance_prod`?(?![A-Za-z0-9_])\s*\./i';
        foreach ($definitions as $definition) {
            $liveReferences += preg_match_all($livePattern, (string)$definition['VIEW_DEFINITION']);
        }
        foreach (self::VIEWS as $view) {
            if (!isset($definitions[$view])) {
                throw new RuntimeException("Required rehearsal view not found: {$view}");
            }
            $security = strtoupper((string)$definitions[$view]['SECURITY_TYPE']);
            if ($security !== 'INVOKER') {
                throw new RuntimeException("Rehearsal view must use INVOKER: {$view}");
            }
            $rowCount = $this->countObject($database, $view);
            if (!isset($baseline['views'][$view]['row_count']) || $rowCount !== $baseline['views'][$view]['row_count']) {
                throw new RuntimeException("Rehearsal view row count differs from checkpoint: {$view}");
            }
            $views[$view] = ['row_count' => $rowCount, 'security_type' => $security];
        }
        if ($liveReferences !== 0) {
            throw new RuntimeException('Rehearsal view still references the Production database.');
        }

        return [
            'status' => 'VERIFIED',
            'database' => 'D365_finance_prod',
            'rehearsal_database' => $database,
            'row_counts' => $rowCounts,
            'views' => $views,
            'live_schema_reference_count' => 0,
        ];
    }

    public static function assertReadOnlyGrants(array $grants, string $database): void
    {
        $hasScopedSelect = false;
        $exactScope = strtoupper("`{$database}`.*");
        $patternScope = strtoupper('`D365\\_finance\\_prod\\_rehearsal\\_%`.*');
        foreach ($grants as $grant) {
            if (!is_string($grant)) {
                throw new RuntimeException('Rehearsal grant evidence is invalid.');
            }
            if (preg_match('/^GRANT\s+USAGE\s+ON\s+\*\.\*/i', $grant) === 1) {
                continue;
            }
            if (preg_match('/^GRANT\s+(.+?)\s+ON\s+(.+?)\s+TO\s+/i', $grant, $match) !== 1) {
                throw new RuntimeException('Rehearsal grant could not be parsed safely.');
            }
            $privileges = array_map(static fn (string $value): string => strtoupper(trim($value)), explode(',', $match[1]));
            foreach ($privileges as $privilege) {
                if (!in_array($privilege, ['SELECT', 'SHOW VIEW'], true)) {
                    throw new RuntimeException('Rehearsal grant contains write or administrative privileges.');
                }
            }
            $scope = strtoupper(trim($match[2]));
            if ($scope !== $exactScope && $scope !== $patternScope) {
                throw new RuntimeException('Rehearsal grant reaches an unapproved database scope.');
            }
            if (in_array('SELECT', $privileges, true)) {
                $hasScopedSelect = true;
            }
        }
        if (!$hasScopedSelect) {
            throw new RuntimeException('Rehearsal grant does not include scoped SELECT access.');
        }
    }

    private function countObject(string $database, string $object): int
    {
        return (int)$this->pdo->query(sprintf('SELECT COUNT(*) FROM `%s`.`%s`', $database, $object))->fetchColumn();
    }

    private function viewDefinitions(string $database): array
    {
        $statement = $this->pdo->prepare('SELECT TABLE_NAME, VIEW_DEFINITION, SECURITY_TYPE FROM information_schema.VIEWS WHERE TABLE_SCHEMA = :schema ORDER BY TABLE_NAME');
        $statement->execute(['schema' => $database]);
        $result = [];
        foreach ($statement->fetchAll(PDO::FETCH_ASSOC) as $row) {
            $result[(string)$row['TABLE_NAME']] = $row;
        }
        return $result;
    }
}
