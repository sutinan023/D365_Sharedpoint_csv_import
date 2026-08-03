<?php
declare(strict_types=1);

namespace App\Import;

use InvalidArgumentException;
use Throwable;

final class FailedImportRetryCli
{
    public function run(array $options, callable $environmentLoader, callable $connector, callable $retry): array
    {
        try {
            $input = $this->input($options);
            $environment = $environmentLoader();
            if (($environment['APP_ENV'] ?? '') !== 'PRODUCTION'
                || ($environment['DB_NAME'] ?? '') !== 'D365_finance_prod') {
                throw new \RuntimeException('Failed-import retry requires the Production finance database.');
            }

            $connection = $connector($environment);
            if ($connection->query('SELECT DATABASE()')->fetchColumn() !== 'D365_finance_prod') {
                throw new \RuntimeException('Connected database is not the Production finance database.');
            }

            return [
                'exit' => 0,
                'stdout' => json_encode($retry($connection, ...$input), JSON_UNESCAPED_SLASHES) . PHP_EOL,
                'stderr' => '',
            ];
        } catch (InvalidArgumentException $exception) {
            return ['exit' => 2, 'stdout' => '', 'stderr' => $exception->getMessage() . PHP_EOL];
        } catch (Throwable) {
            return ['exit' => 1, 'stdout' => '', 'stderr' => 'Failed-import retry was not applied.' . PHP_EOL];
        }
    }

    private function input(array $options): array
    {
        foreach (['apply', 'id', 'file', 'sha256'] as $required) {
            if (!array_key_exists($required, $options) || $options[$required] === '') {
                throw new InvalidArgumentException("Missing required --{$required} option.");
            }
        }

        if (filter_var($options['id'], FILTER_VALIDATE_INT, ['options' => ['min_range' => 1]]) === false
            || preg_match('/^[a-f0-9]{64}$/i', (string) $options['sha256']) !== 1) {
            throw new InvalidArgumentException('Invalid retry identifier or SHA-256.');
        }

        return [(int) $options['id'], (string) $options['file'], strtolower((string) $options['sha256'])];
    }
}
