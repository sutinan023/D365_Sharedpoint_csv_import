<?php
declare(strict_types=1);

namespace App\Database;

use PDO;
use RuntimeException;

final class CheckpointBaseline
{
    private const DATABASE = 'D365_finance_prod';
    private const TABLES = ['import_files', 'payment_outbound', 'payment_mail_log', 'sharepoint_file_queue'];
    private const VIEWS = ['vw_import_report', 'v_tbpayin_from_payment_outbound'];

    public function __construct(private readonly PDO $pdo)
    {
    }

    public function capture(string $database): array
    {
        if ($database !== self::DATABASE) {
            throw new RuntimeException('Checkpoint baseline requires D365_finance_prod.');
        }

        $rowCounts = [];
        foreach (self::TABLES as $table) {
            $rowCounts[$table] = $this->countObject($database, $table);
        }

        $definitions = $this->viewDefinitions($database);
        $views = [];
        foreach (self::VIEWS as $view) {
            if (!isset($definitions[$view])) {
                throw new RuntimeException("Required Production view not found: {$view}");
            }
            $views[$view] = [
                'row_count' => $this->countObject($database, $view),
                'security_type' => strtoupper((string) $definitions[$view]['SECURITY_TYPE']),
            ];
        }

        $qualifiedPattern = '/`' . preg_quote($database, '/') . '`\s*\./i';
        $qualifiedReferences = 0;
        $definers = 0;
        foreach ($definitions as $definition) {
            $qualifiedReferences += preg_match_all($qualifiedPattern, (string) $definition['VIEW_DEFINITION']);
            if (strcasecmp((string) $definition['SECURITY_TYPE'], 'DEFINER') === 0) {
                $definers++;
            }
        }

        return [
            'database' => $database,
            'row_counts' => $rowCounts,
            'views' => $views,
            'live_schema_reference_count' => $qualifiedReferences,
            'definer_count' => $definers,
            'qualified_reference_count' => $qualifiedReferences,
        ];
    }

    private function countObject(string $database, string $object): int
    {
        $statement = $this->pdo->query(sprintf('SELECT COUNT(*) FROM `%s`.`%s`', $database, $object));
        if ($statement === false) {
            throw new RuntimeException("Unable to count {$object}.");
        }
        return (int) $statement->fetchColumn();
    }

    private function viewDefinitions(string $database): array
    {
        $statement = $this->pdo->prepare(
            'SELECT TABLE_NAME, VIEW_DEFINITION, SECURITY_TYPE FROM information_schema.VIEWS '
            . 'WHERE TABLE_SCHEMA = :schema ORDER BY TABLE_NAME'
        );
        $statement->execute(['schema' => $database]);
        $result = [];
        foreach ($statement->fetchAll(PDO::FETCH_ASSOC) as $row) {
            $result[(string) $row['TABLE_NAME']] = $row;
        }
        return $result;
    }
}
