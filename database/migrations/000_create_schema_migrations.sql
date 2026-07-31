CREATE TABLE IF NOT EXISTS schema_migrations (
    project_name VARCHAR(100) NOT NULL,
    version VARCHAR(255) NOT NULL,
    checksum_sha256 CHAR(64) NOT NULL,
    release_id VARCHAR(100) NOT NULL,
    applied_by VARCHAR(255) NOT NULL,
    status VARCHAR(16) NOT NULL DEFAULT 'APPLYING',
    started_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    finished_at TIMESTAMP NULL DEFAULT NULL,
    error_message TEXT NULL,
    PRIMARY KEY (project_name, version)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
