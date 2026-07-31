-- Repair the existing vw_import_report dependency without replacing UAT data.
SET @effective_date_exists := (
    SELECT COUNT(*)
    FROM information_schema.columns
    WHERE table_schema = DATABASE()
      AND table_name = 'stg_received_outbound'
      AND column_name = 'effective_date'
);

SET @effective_date_migration := IF(
    @effective_date_exists = 0,
    'ALTER TABLE stg_received_outbound ADD COLUMN effective_date DATE NULL AFTER transaction_date',
    'SELECT ''stg_received_outbound.effective_date already exists'' AS migration_status'
);

PREPARE effective_date_stmt FROM @effective_date_migration;
EXECUTE effective_date_stmt;
DEALLOCATE PREPARE effective_date_stmt;
