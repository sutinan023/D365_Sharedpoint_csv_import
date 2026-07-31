<?php

namespace App\Database;

use PDO;

final class SchemaInventory
{
    private array $warnings = [];

    public function __construct(private readonly PDO $pdo)
    {
    }

    public function collect(string $schema): array
    {
        $this->warnings = [];
        return [
            'schema' => $schema,
            'collected_at' => gmdate('c'),
            'tables' => $this->fetch(
                'SELECT TABLE_NAME, TABLE_TYPE, ENGINE, TABLE_COLLATION '
                . 'FROM information_schema.TABLES WHERE TABLE_SCHEMA = :schema ORDER BY TABLE_NAME',
                $schema
            ),
            'columns' => $this->fetch(
                'SELECT TABLE_NAME, ORDINAL_POSITION, COLUMN_NAME, COLUMN_TYPE, IS_NULLABLE, COLUMN_DEFAULT, EXTRA '
                . 'FROM information_schema.COLUMNS WHERE TABLE_SCHEMA = :schema '
                . 'ORDER BY TABLE_NAME, ORDINAL_POSITION',
                $schema
            ),
            'indexes' => $this->fetch(
                'SELECT TABLE_NAME, INDEX_NAME, NON_UNIQUE, SEQ_IN_INDEX, COLUMN_NAME, SUB_PART, INDEX_TYPE '
                . 'FROM information_schema.STATISTICS WHERE TABLE_SCHEMA = :schema '
                . 'ORDER BY TABLE_NAME, INDEX_NAME, SEQ_IN_INDEX',
                $schema
            ),
            'views' => $this->fetch(
                'SELECT TABLE_NAME, VIEW_DEFINITION, CHECK_OPTION, SECURITY_TYPE '
                . 'FROM information_schema.VIEWS WHERE TABLE_SCHEMA = :schema ORDER BY TABLE_NAME',
                $schema
            ),
            'routines' => $this->fetch(
                'SELECT ROUTINE_NAME, ROUTINE_TYPE, DATA_TYPE, SECURITY_TYPE, ROUTINE_DEFINITION '
                . 'FROM information_schema.ROUTINES WHERE ROUTINE_SCHEMA = :schema ORDER BY ROUTINE_NAME',
                $schema
            ),
            'triggers' => $this->fetch(
                'SELECT TRIGGER_NAME, EVENT_MANIPULATION, EVENT_OBJECT_TABLE, ACTION_TIMING, ACTION_STATEMENT '
                . 'FROM information_schema.TRIGGERS WHERE TRIGGER_SCHEMA = :schema ORDER BY TRIGGER_NAME',
                $schema
            ),
            'constraints' => $this->fetch(
                'SELECT tc.TABLE_NAME, tc.CONSTRAINT_NAME, tc.CONSTRAINT_TYPE, '
                . 'kcu.COLUMN_NAME, kcu.REFERENCED_TABLE_NAME, kcu.REFERENCED_COLUMN_NAME '
                . 'FROM information_schema.TABLE_CONSTRAINTS tc '
                . 'LEFT JOIN information_schema.KEY_COLUMN_USAGE kcu '
                . 'ON kcu.CONSTRAINT_SCHEMA = tc.CONSTRAINT_SCHEMA '
                . 'AND kcu.TABLE_NAME = tc.TABLE_NAME AND kcu.CONSTRAINT_NAME = tc.CONSTRAINT_NAME '
                . 'WHERE tc.CONSTRAINT_SCHEMA = :schema '
                . 'ORDER BY tc.TABLE_NAME, tc.CONSTRAINT_NAME, kcu.ORDINAL_POSITION',
                $schema
            ),
            'check_constraints' => $this->fetchOptional(
                'SELECT cc.CONSTRAINT_NAME, cc.CHECK_CLAUSE '
                . 'FROM information_schema.CHECK_CONSTRAINTS cc '
                . 'WHERE cc.CONSTRAINT_SCHEMA = :schema ORDER BY cc.CONSTRAINT_NAME',
                $schema,
                'CHECK_CONSTRAINTS is not available on this database version'
            ),
            'events' => $this->fetch(
                'SELECT EVENT_NAME, EVENT_DEFINITION, EVENT_TYPE, EXECUTE_AT, INTERVAL_VALUE, INTERVAL_FIELD, STATUS '
                . 'FROM information_schema.EVENTS WHERE EVENT_SCHEMA = :schema ORDER BY EVENT_NAME',
                $schema
            ),
            'warnings' => $this->warnings,
        ];
    }

    private function fetch(string $sql, string $schema): array
    {
        $statement = $this->pdo->prepare($sql);
        $statement->execute(['schema' => $schema]);
        return $statement->fetchAll(PDO::FETCH_ASSOC);
    }

    private function fetchOptional(string $sql, string $schema, string $warning): array
    {
        try {
            return $this->fetch($sql, $schema);
        } catch (\PDOException $exception) {
            $message = strtolower($exception->getMessage());
            if (
                $exception->getCode() !== '42S02'
                && !str_contains($message, 'unknown table')
                && !str_contains($message, 'no such table')
            ) {
                throw $exception;
            }
            $this->warnings[] = $warning;
            return [];
        }
    }
}
