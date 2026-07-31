<?php

use App\Database\MigrationRunner;

return [
    'migration runner applies once and records checksum' => function (): void {
        $pdo = new PDO('sqlite::memory:');
        $directory = sys_get_temp_dir() . '/migration-runner-' . bin2hex(random_bytes(4));
        mkdir($directory);
        $migration = $directory . '/001_create_sample.sql';
        file_put_contents($migration, 'CREATE TABLE sample_records (id INTEGER PRIMARY KEY);');

        $runner = new MigrationRunner($pdo);
        $applied = $runner->applyDirectory('test_project', $directory, 'release-1', 'tester');
        assert($applied === ['001_create_sample.sql']);
        assert($runner->applyDirectory('test_project', $directory, 'release-1', 'tester') === []);

        $row = $pdo->query('SELECT project_name, version, checksum_sha256, release_id, applied_by, status FROM schema_migrations')->fetch();
        assert($row['project_name'] === 'test_project');
        assert($row['version'] === '001_create_sample.sql');
        assert($row['checksum_sha256'] === hash_file('sha256', $migration));
        assert($row['release_id'] === 'release-1');
        assert($row['applied_by'] === 'tester');
        assert($row['status'] === 'APPLIED');

        file_put_contents($migration, 'CREATE TABLE changed_records (id INTEGER PRIMARY KEY);');
        try {
            $runner->applyDirectory('test_project', $directory, 'release-1', 'tester');
        } catch (RuntimeException $exception) {
            assert(str_contains($exception->getMessage(), 'checksum'));
            unlink($migration);
            rmdir($directory);
            return;
        }

        throw new RuntimeException('Expected a changed applied migration to fail checksum validation');
    },
    'migration runner records failure and blocks automatic retry' => function (): void {
        $pdo = new PDO('sqlite::memory:');
        $directory = sys_get_temp_dir() . '/migration-runner-failure-' . bin2hex(random_bytes(4));
        mkdir($directory);
        $migration = $directory . '/001_invalid.sql';
        file_put_contents($migration, 'THIS IS NOT SQL;');
        $runner = new MigrationRunner($pdo);

        try {
            $runner->applyDirectory('test_project', $directory, 'release-1', 'tester');
            throw new RuntimeException('Expected migration failure');
        } catch (RuntimeException $exception) {
            assert(str_contains($exception->getMessage(), 'Migration failed'));
        }
        assert($pdo->query("SELECT status FROM schema_migrations")->fetchColumn() === 'FAILED');

        try {
            $runner->applyDirectory('test_project', $directory, 'release-1', 'tester');
        } catch (RuntimeException $exception) {
            assert(str_contains($exception->getMessage(), 'manual recovery'));
            unlink($migration);
            rmdir($directory);
            return;
        }
        throw new RuntimeException('Expected failed migration to require manual recovery');
    },
];
