-- Add the PENDING_ARCHIVE import_files status used by the queue importer.
-- Safe to run more than once: if the enum already contains PENDING_ARCHIVE,
-- this migration performs a no-op SELECT.

SET @import_files_status_type := (
    SELECT column_type
    FROM information_schema.columns
    WHERE table_schema = DATABASE()
      AND table_name = 'import_files'
      AND column_name = 'status'
    LIMIT 1
);

SET @import_files_status_migration := IF(
    @import_files_status_type LIKE "%'PENDING_ARCHIVE'%",
    'SELECT ''import_files.status already supports PENDING_ARCHIVE'' AS migration_status',
    'ALTER TABLE import_files MODIFY status ENUM(''PROCESSING'',''PENDING_ARCHIVE'',''SUCCESS'',''ERROR'',''SKIPPED'') NOT NULL'
);

PREPARE import_files_status_stmt FROM @import_files_status_migration;
EXECUTE import_files_status_stmt;
DEALLOCATE PREPARE import_files_status_stmt;
