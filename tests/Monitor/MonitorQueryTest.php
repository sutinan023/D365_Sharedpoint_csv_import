<?php

return [
    'monitor renders SharePoint queue queries and visibility fields' => function (): void {
        $monitor = file_get_contents(__DIR__ . '/../../monitor/index.php');

        assert(str_contains($monitor, 'FROM sharepoint_file_queue'));
        assert(str_contains($monitor, 'COUNT(*) AS total'));
        assert(str_contains($monitor, 'ORDER BY updated_at DESC'));
        assert(str_contains($monitor, "WHERE status IN ('IMPORT_ERROR', 'RECOVERY_ERROR', 'RECOVERY_DOWNLOADING')"));
        assert(str_contains($monitor, 'Oldest blocking queue row:'));
        assert(str_contains($monitor, "['status']"));
        assert(str_contains($monitor, "['attempt_count']"));
        assert(str_contains($monitor, "['last_error']"));
        assert(str_contains($monitor, "['updated_at']"));
    },
    'monitor queue queries run against queue schema' => function (): void {
        $pdo = new PDO('sqlite::memory:');
        $pdo->setAttribute(PDO::ATTR_ERRMODE, PDO::ERRMODE_EXCEPTION);
        $pdo->exec('CREATE TABLE sharepoint_file_queue (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            file_name TEXT,
            status TEXT,
            attempt_count INTEGER DEFAULT 0,
            last_error TEXT,
            downloaded_at TEXT,
            moved_at TEXT,
            imported_at TEXT,
            sharepoint_last_modified_at TEXT,
            updated_at TEXT
        )');
        $pdo->exec("INSERT INTO sharepoint_file_queue (file_name, status, last_error, sharepoint_last_modified_at, updated_at) VALUES ('bad.csv', 'IMPORT_ERROR', 'bad row', '2026-07-24 02:00:00', '2026-07-24 03:00:00')");
        $pdo->exec("INSERT INTO sharepoint_file_queue (file_name, status, last_error, sharepoint_last_modified_at, updated_at) VALUES ('recovery.csv', 'RECOVERY_ERROR', 'restore file', '2026-07-24 01:00:00', '2026-07-24 02:00:00')");
        $pdo->exec("INSERT INTO sharepoint_file_queue (file_name, status, last_error, sharepoint_last_modified_at, updated_at) VALUES ('recovery-downloading.csv', 'RECOVERY_DOWNLOADING', NULL, '2026-07-24 00:30:00', '2026-07-24 01:00:00')");

        $counts = $pdo->query("SELECT status, COUNT(*) AS total FROM sharepoint_file_queue GROUP BY status ORDER BY status")->fetchAll(PDO::FETCH_ASSOC);
        $oldest = $pdo->query("SELECT file_name, status, last_error, updated_at FROM sharepoint_file_queue WHERE status IN ('IMPORT_ERROR', 'RECOVERY_ERROR', 'RECOVERY_DOWNLOADING') ORDER BY sharepoint_last_modified_at ASC, id ASC LIMIT 1")->fetch(PDO::FETCH_ASSOC);

        assert($counts[0]['status'] === 'IMPORT_ERROR');
        assert($counts[1]['status'] === 'RECOVERY_DOWNLOADING');
        assert($counts[2]['status'] === 'RECOVERY_ERROR');
        assert($oldest['file_name'] === 'recovery-downloading.csv');
        assert($oldest['status'] === 'RECOVERY_DOWNLOADING');
    },
];
