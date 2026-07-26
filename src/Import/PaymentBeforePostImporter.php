<?php

namespace App\Import;

use PDO;
use RuntimeException;

final class PaymentBeforePostImporter
{
    public function __construct(
        private readonly PDO $pdo,
        private readonly string $archiveDir,
        private readonly ?\Closure $archiveMover = null,
    ) {
    }

    public function isDuplicateHash(string $sha256): bool
    {
        $stmt = $this->pdo->prepare("SELECT COUNT(*) FROM import_files WHERE file_hash = :hash AND status = 'SUCCESS'");
        $stmt->execute([':hash' => $sha256]);

        return (int)$stmt->fetchColumn() > 0;
    }

    public function reconcileInterruptedImport(array $row): array
    {
        $localPath = (string) ($row['local_path'] ?? '');
        $fileName = basename($localPath);
        if ($fileName === '') {
            $fileName = basename((string) ($row['file_name'] ?? ''));
        }
        $sha256 = (string) ($row['local_sha256'] ?? '');
        $importStatus = $sha256 === '' ? null : $this->findImportStatus($sha256);

        if ($importStatus === 'SUCCESS') {
            return ['action' => 'IMPORTED', 'message' => null];
        }

        if ($importStatus === 'PENDING_ARCHIVE') {
            if ($localPath !== '' && is_file($localPath)) {
                $actualHash = hash_file('sha256', $localPath);
                if ($actualHash === false || $sha256 === '' || !hash_equals($sha256, $actualHash)) {
                    return [
                        'action' => 'BLOCKED',
                        'message' => 'Interrupted import is PENDING_ARCHIVE, but the local file hash cannot be verified',
                    ];
                }

                if (!is_dir($this->archiveDir)
                    && !mkdir($this->archiveDir, 0777, true)
                    && !is_dir($this->archiveDir)
                ) {
                    return [
                        'action' => 'BLOCKED',
                        'message' => "Interrupted import is PENDING_ARCHIVE, but the archive directory cannot be created: {$this->archiveDir}",
                    ];
                }

                $this->archiveFile($localPath, $fileName);
                $this->markImportSuccessful($sha256);

                return ['action' => 'IMPORTED', 'message' => null];
            }

            if ($this->findArchivedFile($fileName, $sha256) !== null) {
                $this->markImportSuccessful($sha256);

                return ['action' => 'IMPORTED', 'message' => null];
            }

            return [
                'action' => 'BLOCKED',
                'message' => "Interrupted import is PENDING_ARCHIVE, but the local CSV is missing and no matching archive was found for {$fileName}",
            ];
        }

        if ($localPath !== '' && is_file($localPath)) {
            $actualHash = hash_file('sha256', $localPath);
            if ($actualHash === false || $sha256 === '' || !hash_equals($sha256, $actualHash)) {
                return [
                    'action' => 'BLOCKED',
                    'message' => 'Interrupted import local file hash does not match the queued SHA-256',
                ];
            }

            return ['action' => 'RETRY', 'message' => null];
        }

        return [
            'action' => 'BLOCKED',
            'message' => "Interrupted import cannot be retried because the local CSV is missing: {$localPath}",
        ];
    }

    public function importFile(string $filePath, ?int $queueId = null): string
    {
        // Reserved for queue status updates when importer execution is linked to queue records.
        if (!is_file($filePath)) {
            throw new RuntimeException("CSV file not found: {$filePath}");
        }

        if (!is_dir($this->archiveDir) && !mkdir($this->archiveDir, 0777, true) && !is_dir($this->archiveDir)) {
            throw new RuntimeException("Unable to create archive directory: {$this->archiveDir}");
        }

        $fileName = basename($filePath);
        $fileHash = hash_file('sha256', $filePath);
        if ($fileHash === false) {
            throw new RuntimeException("Unable to hash CSV file: {$filePath}");
        }

        $handle = null;
        $transactionCommitted = false;

        try {
            $this->pdo->beginTransaction();
            $this->pdo->exec('DELETE FROM stg_payment_before_post');

            $delimiter = $this->detectDelimiter($filePath);
            echo "CSV DELIMITER: {$delimiter}\n";
            $handle = fopen($filePath, 'r');
            if ($handle === false) {
                throw new RuntimeException('Cannot open CSV file');
            }

            $headers = fgetcsv($handle, 0, $delimiter);
            if ($headers === false) {
                throw new RuntimeException('CSV header not found');
            }
            $headers = array_map($this->normalizeHeaderName(...), $headers);

            echo 'CSV HEADERS FOUND: ' . count($headers) . "\n";
            echo "NORMALIZED HEADERS:\n";
            print_r($headers);

            $insertStaging = $this->pdo->prepare(
                'INSERT INTO stg_payment_before_post (
                    source_file_name, file_hash, import_export_reference, company, bank_account_code,
                    transaction_date, cashflow, journal_batch, voucher_number, description, vendor_account,
                    vendor_name, email_address, purchase_order, invoice_number, vendor_bank_account_code,
                    vendor_bank_account_number, bank_transaction_type, method_of_payment, invoice_amount,
                    currency, exchange_rate, fee, withholding_tax_amount, total_amount,
                    workflow_approval_status, comment
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)'
            );

            $selectedRows = [];
            $stagingRowCount = 0;
            while (($data = fgetcsv($handle, 0, $delimiter)) !== false) {
                if (count(array_filter($data, static fn ($value): bool => trim((string)$value) !== '')) === 0) {
                    continue;
                }
                $row = $this->buildCsvRow($headers, $data);
                if ($row === null) {
                    continue;
                }
                $currentData = $this->buildCurrentData($row);
                $insertStaging->execute([
                    $fileName, $fileHash, $currentData['import_export_reference'], $currentData['company'],
                    $currentData['bank_account_code'], $currentData['transaction_date'], $currentData['cashflow'],
                    $currentData['journal_batch'], $currentData['voucher_number'], $currentData['description'],
                    $currentData['vendor_account'], $currentData['vendor_name'], $currentData['email_address'],
                    $currentData['purchase_order'], $currentData['invoice_number'],
                    $currentData['vendor_bank_account_code'], $currentData['vendor_bank_account_number'],
                    $currentData['bank_transaction_type'], $currentData['method_of_payment'],
                    $currentData['invoice_amount'], $currentData['currency'], $currentData['exchange_rate'],
                    $currentData['fee'], $currentData['withholding_tax_amount'], $currentData['total_amount'],
                    $currentData['workflow_approval_status'], $currentData['comment'],
                ]);

                $businessKey = $this->buildBusinessKey($currentData);
                $priority = $this->getWorkflowPriority($currentData['workflow_approval_status']);
                if (!isset($selectedRows[$businessKey]) || $this->isBetterCurrentRow($currentData, $selectedRows[$businessKey])) {
                    $selectedRows[$businessKey] = ['data' => $currentData, 'priority' => $priority];
                }
                $stagingRowCount++;
            }
            fclose($handle);
            $handle = null;

            $newCount = 0;
            $sameCount = 0;
            $updateCount = 0;
            if ($selectedRows !== []) {
                $statements = $this->prepareMainStatements();
                foreach ($selectedRows as $item) {
                    $currentData = $item['data'];
                    $rowHash = $this->buildRowHash($currentData);
                    $statements['select']->execute([
                        $currentData['company'], $currentData['journal_batch'],
                        $currentData['voucher_number'], $currentData['invoice_number'],
                    ]);
                    $existing = $statements['select']->fetch(PDO::FETCH_ASSOC);

                    if ($existing === false) {
                        $statements['insert']->execute($this->mainInsertValues($fileName, $fileHash, $rowHash, $currentData));
                        $paymentId = $this->pdo->lastInsertId();
                        $statements['history']->execute([
                            $paymentId, $fileName, $currentData['import_export_reference'], $rowHash, 'INSERT', null,
                            json_encode($currentData, JSON_UNESCAPED_UNICODE),
                        ]);
                        $newCount++;
                        continue;
                    }

                    if ($existing['row_hash'] === $rowHash) {
                        $statements['seen']->execute([$fileName, $fileHash, $existing['id']]);
                        $sameCount++;
                        continue;
                    }

                    $statements['update']->execute($this->mainUpdateValues($fileName, $fileHash, $rowHash, $currentData, $existing['id']));
                    $statements['history']->execute([
                        $existing['id'], $fileName, $currentData['import_export_reference'], $rowHash, 'UPDATE',
                        json_encode($this->buildOldData($existing), JSON_UNESCAPED_UNICODE),
                        json_encode($currentData, JSON_UNESCAPED_UNICODE),
                    ]);
                    $updateCount++;
                }
            }

            $message = 'Import completed | staging=' . $stagingRowCount . ', selected=' . count($selectedRows)
                . ", new={$newCount}, updated={$updateCount}, same={$sameCount}";
            $this->recordImport($fileName, $filePath, $fileHash, 'PENDING_ARCHIVE', $stagingRowCount, $message);

            $this->pdo->commit();
            $transactionCommitted = true;

            $archivePath = $this->archiveFile($filePath, $fileName);
            $this->recordImport($fileName, $filePath, $fileHash, 'SUCCESS', $stagingRowCount, $message);

            echo "STAGING ROWS: {$stagingRowCount}\n";
            echo 'SELECTED CURRENT ROWS: ' . count($selectedRows) . "\n";
            echo "NEW ROWS: {$newCount}\n";
            echo "UPDATED ROWS: {$updateCount}\n";
            echo "UNCHANGED ROWS: {$sameCount}\n";
            echo "IMPORT SUCCESS\n";
            echo "ARCHIVE: {$archivePath}\n";

            return $archivePath;
        } catch (\Throwable $exception) {
            if (is_resource($handle)) {
                fclose($handle);
            }
            if ($this->pdo->inTransaction()) {
                $this->pdo->rollBack();
            }

            if (!$transactionCommitted) {
                try {
                    $this->recordImport($fileName, $filePath, $fileHash, 'ERROR', 0, $exception->getMessage());
                } catch (\Throwable $logException) {
                    echo 'LOG ERROR: ' . $logException->getMessage() . "\n";
                }
            }

            throw $exception;
        }
    }

    private function archiveFile(string $filePath, string $fileName): string
    {
        $archivePath = rtrim($this->archiveDir, "\\/") . DIRECTORY_SEPARATOR . date('Ymd_His_') . $fileName;
        $moved = $this->archiveMover === null
            ? rename($filePath, $archivePath)
            : ($this->archiveMover)($filePath, $archivePath);

        if (!$moved) {
            throw new RuntimeException("Unable to archive CSV file: {$filePath}");
        }

        return $archivePath;
    }

    private function findImportStatus(string $sha256): ?string
    {
        $stmt = $this->pdo->prepare('SELECT status FROM import_files WHERE file_hash = :hash LIMIT 1');
        $stmt->execute([':hash' => $sha256]);
        $status = $stmt->fetchColumn();

        return $status === false ? null : (string) $status;
    }

    private function markImportSuccessful(string $sha256): void
    {
        $stmt = $this->pdo->prepare(
            "UPDATE import_files SET status = 'SUCCESS' WHERE file_hash = :hash AND status = 'PENDING_ARCHIVE'"
        );
        $stmt->execute([':hash' => $sha256]);
    }

    private function findArchivedFile(string $fileName, string $sha256): ?string
    {
        if ($fileName === '' || $sha256 === '' || !is_dir($this->archiveDir)) {
            return null;
        }

        foreach (scandir($this->archiveDir) ?: [] as $entry) {
            if ($entry === '.' || $entry === '..' || !str_ends_with($entry, '_' . $fileName)) {
                continue;
            }

            $candidate = rtrim($this->archiveDir, "\\/") . DIRECTORY_SEPARATOR . $entry;
            if (!is_file($candidate)) {
                continue;
            }

            $actualHash = hash_file('sha256', $candidate);
            if ($actualHash !== false && hash_equals($sha256, $actualHash)) {
                return $candidate;
            }
        }

        return null;
    }

    private function detectDelimiter(string $filePath): string
    {
        $handle = fopen($filePath, 'r');
        if ($handle === false) {
            throw new RuntimeException('Cannot open CSV file for delimiter detection');
        }
        $line = fgets($handle);
        fclose($handle);

        if ($line === false) {
            return ',';
        }

        return substr_count($line, ';') > substr_count($line, ',') ? ';' : ',';
    }

    private function normalizeHeaderName(string $header): string
    {
        $header = preg_replace('/^\xEF\xBB\xBF/', '', $header) ?? $header;
        $header = str_replace("\xEF\xBB\xBF", '', $header);
        $header = strtolower(trim(trim($header), "\"' "));
        $header = str_replace(['／', '\\'], '/', $header);
        $header = preg_replace('/\s+/', ' ', $header) ?? $header;

        $map = [
            'import/export reference' => 'import_export_reference',
            'import / export reference' => 'import_export_reference',
            'company' => 'company', 'bank account code' => 'bank_account_code',
            'transaction date' => 'transaction_date', 'cashflow' => 'cashflow',
            'journal batch' => 'journal_batch', 'voucher number' => 'voucher_number',
            'description' => 'description', 'vendor account' => 'vendor_account',
            'vendor name' => 'vendor_name', 'e-mail address' => 'email_address',
            'email address' => 'email_address', 'purchase order' => 'purchase_order',
            'invoice number' => 'invoice_number', 'vendor bank account code' => 'vendor_bank_account_code',
            'vendor bank account number' => 'vendor_bank_account_number',
            'bank transaction type' => 'bank_transaction_type', 'method of payment' => 'method_of_payment',
            'invoice amount' => 'invoice_amount', 'currency' => 'currency', 'exchange rate' => 'exchange_rate',
            'fee' => 'fee', 'withholding tax amount' => 'withholding_tax_amount',
            'total amount' => 'total_amount', 'workflow approval status' => 'workflow_approval_status',
            'comment' => 'comment',
        ];

        return $map[$header] ?? trim(preg_replace('/[^a-z0-9]+/', '_', $header) ?? '', '_');
    }

    private function buildCsvRow(array $headers, array $data): ?array
    {
        $data = array_slice(array_pad($data, count($headers), null), 0, count($headers));
        $row = array_combine($headers, $data);

        return $row === false ? null : $row;
    }

    private function buildCurrentData(array $row): array
    {
        return [
            'import_export_reference' => $this->cleanValue($row['import_export_reference'] ?? null),
            'company' => $this->cleanValue($row['company'] ?? null),
            'journal_batch' => $this->cleanValue($row['journal_batch'] ?? null),
            'voucher_number' => $this->cleanValue($row['voucher_number'] ?? null),
            'invoice_number' => $this->cleanValue($row['invoice_number'] ?? null),
            'bank_account_code' => $this->cleanValue($row['bank_account_code'] ?? null),
            'transaction_date' => $this->parseDateValue($row['transaction_date'] ?? null),
            'cashflow' => $this->cleanValue($row['cashflow'] ?? null),
            'description' => $this->cleanValue($row['description'] ?? null),
            'vendor_account' => $this->cleanValue($row['vendor_account'] ?? null),
            'vendor_name' => $this->cleanValue($row['vendor_name'] ?? null),
            'email_address' => $this->cleanValue($row['email_address'] ?? null),
            'purchase_order' => $this->cleanValue($row['purchase_order'] ?? null),
            'vendor_bank_account_code' => $this->cleanValue($row['vendor_bank_account_code'] ?? null),
            'vendor_bank_account_number' => $this->cleanValue($row['vendor_bank_account_number'] ?? null),
            'bank_transaction_type' => $this->cleanValue($row['bank_transaction_type'] ?? null),
            'method_of_payment' => $this->cleanValue($row['method_of_payment'] ?? null),
            'invoice_amount' => $this->parseNumberValue($row['invoice_amount'] ?? null),
            'currency' => $this->cleanValue($row['currency'] ?? null),
            'exchange_rate' => $this->parseNumberValue($row['exchange_rate'] ?? null),
            'fee' => $this->parseNumberValue($row['fee'] ?? null),
            'withholding_tax_amount' => $this->parseNumberValue($row['withholding_tax_amount'] ?? null),
            'total_amount' => $this->parseNumberValue($row['total_amount'] ?? null),
            'workflow_approval_status' => $this->cleanValue($row['workflow_approval_status'] ?? null),
            'comment' => $this->cleanValue($row['comment'] ?? null),
        ];
    }

    private function cleanValue(mixed $value): ?string
    {
        $value = trim((string)$value);

        return $value === '' ? null : $value;
    }

    private function parseDateValue(mixed $value): ?string
    {
        $value = $this->cleanValue($value);
        if ($value === null) {
            return null;
        }
        foreach (['j/n/Y', 'd/m/Y', 'Y-m-d'] as $format) {
            $date = \DateTime::createFromFormat($format, $value);
            if ($date !== false) {
                return $date->format('Y-m-d');
            }
        }

        return null;
    }

    private function parseNumberValue(mixed $value): int|string
    {
        $value = $this->cleanValue($value);
        if ($value === null) {
            return 0;
        }
        $value = str_replace([',', ' '], '', $value);

        return is_numeric($value) ? $value : 0;
    }

    private function buildBusinessKey(array $data): string
    {
        return implode('|', [$data['company'], $data['journal_batch'], $data['voucher_number'], $data['invoice_number']]);
    }

    private function getWorkflowPriority(?string $status): int
    {
        return match (strtolower(trim((string)$status))) {
            'in review' => 1,
            'submitted' => 2,
            'approved' => 3,
            default => 0,
        };
    }

    private function isBetterCurrentRow(array $newData, array $oldItem): bool
    {
        $newPriority = $this->getWorkflowPriority($newData['workflow_approval_status']);
        if ($newPriority !== $oldItem['priority']) {
            return $newPriority > $oldItem['priority'];
        }

        return strcmp($newData['import_export_reference'] ?? '', $oldItem['data']['import_export_reference'] ?? '') > 0;
    }

    private function buildRowHash(array $data): string
    {
        ksort($data);

        return hash('sha256', json_encode($data, JSON_UNESCAPED_UNICODE));
    }

    private function prepareMainStatements(): array
    {
        return [
            'select' => $this->pdo->prepare('SELECT * FROM payment_before_post WHERE company <=> ? AND journal_batch <=> ? AND voucher_number <=> ? AND invoice_number <=> ? LIMIT 1'),
            'insert' => $this->pdo->prepare(
                'INSERT INTO payment_before_post (
                    source_file_name, file_hash, row_hash, first_seen_at, last_seen_at, last_changed_at,
                    import_export_reference, company, bank_account_code, transaction_date, cashflow, journal_batch,
                    voucher_number, description, vendor_account, vendor_name, email_address, purchase_order,
                    invoice_number, vendor_bank_account_code, vendor_bank_account_number, bank_transaction_type,
                    method_of_payment, invoice_amount, currency, exchange_rate, fee, withholding_tax_amount,
                    total_amount, workflow_approval_status, comment
                ) VALUES (?, ?, ?, NOW(), NOW(), NOW(), ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)'
            ),
            'seen' => $this->pdo->prepare('UPDATE payment_before_post SET source_file_name = ?, file_hash = ?, last_seen_at = NOW() WHERE id = ?'),
            'update' => $this->pdo->prepare(
                'UPDATE payment_before_post SET
                    source_file_name = ?, file_hash = ?, row_hash = ?, last_seen_at = NOW(), last_changed_at = NOW(),
                    import_export_reference = ?, bank_account_code = ?, transaction_date = ?, cashflow = ?, description = ?,
                    vendor_account = ?, vendor_name = ?, email_address = ?, purchase_order = ?,
                    vendor_bank_account_code = ?, vendor_bank_account_number = ?, bank_transaction_type = ?,
                    method_of_payment = ?, invoice_amount = ?, currency = ?, exchange_rate = ?, fee = ?,
                    withholding_tax_amount = ?, total_amount = ?, workflow_approval_status = ?, comment = ?
                WHERE id = ?'
            ),
            'history' => $this->pdo->prepare(
                'INSERT INTO payment_before_post_history (
                    payment_id, source_file_name, import_export_reference, row_hash, action_type, old_data, new_data
                ) VALUES (?, ?, ?, ?, ?, ?, ?)'
            ),
        ];
    }

    private function mainInsertValues(string $fileName, string $fileHash, string $rowHash, array $data): array
    {
        return [
            $fileName, $fileHash, $rowHash,
            $data['import_export_reference'], $data['company'], $data['bank_account_code'], $data['transaction_date'],
            $data['cashflow'], $data['journal_batch'], $data['voucher_number'], $data['description'],
            $data['vendor_account'], $data['vendor_name'], $data['email_address'], $data['purchase_order'],
            $data['invoice_number'], $data['vendor_bank_account_code'], $data['vendor_bank_account_number'],
            $data['bank_transaction_type'], $data['method_of_payment'], $data['invoice_amount'], $data['currency'],
            $data['exchange_rate'], $data['fee'], $data['withholding_tax_amount'], $data['total_amount'],
            $data['workflow_approval_status'], $data['comment'],
        ];
    }

    private function mainUpdateValues(string $fileName, string $fileHash, string $rowHash, array $data, int|string $id): array
    {
        return [
            $fileName, $fileHash, $rowHash, $data['import_export_reference'], $data['bank_account_code'],
            $data['transaction_date'], $data['cashflow'], $data['description'], $data['vendor_account'],
            $data['vendor_name'], $data['email_address'], $data['purchase_order'], $data['vendor_bank_account_code'],
            $data['vendor_bank_account_number'], $data['bank_transaction_type'], $data['method_of_payment'],
            $data['invoice_amount'], $data['currency'], $data['exchange_rate'], $data['fee'],
            $data['withholding_tax_amount'], $data['total_amount'], $data['workflow_approval_status'], $data['comment'], $id,
        ];
    }

    private function buildOldData(array $existing): array
    {
        $columns = [
            'import_export_reference', 'company', 'journal_batch', 'voucher_number', 'invoice_number',
            'bank_account_code', 'transaction_date', 'cashflow', 'description', 'vendor_account', 'vendor_name',
            'email_address', 'purchase_order', 'vendor_bank_account_code', 'vendor_bank_account_number',
            'bank_transaction_type', 'method_of_payment', 'invoice_amount', 'currency', 'exchange_rate', 'fee',
            'withholding_tax_amount', 'total_amount', 'workflow_approval_status', 'comment',
        ];

        return array_combine($columns, array_map(static fn (string $column): mixed => $existing[$column], $columns));
    }

    private function recordImport(
        string $fileName,
        string $filePath,
        string $fileHash,
        string $status,
        int $totalRows,
        string $message,
    ): void {
        if ($this->pdo->getAttribute(PDO::ATTR_DRIVER_NAME) === 'sqlite') {
            $stmt = $this->pdo->prepare(
                "INSERT INTO import_files (
                    source_file_name, file_type, local_file_name, file_hash, status, total_rows, message
                ) VALUES (?, 'PAYMENT BEFORE POST', ?, ?, ?, ?, ?)
                ON CONFLICT(file_hash) DO UPDATE SET
                    source_file_name = excluded.source_file_name,
                    file_type = excluded.file_type,
                    local_file_name = excluded.local_file_name,
                    status = excluded.status,
                    total_rows = excluded.total_rows,
                    message = excluded.message,
                    imported_at = CURRENT_TIMESTAMP"
            );
            $stmt->execute([$fileName, $filePath, $fileHash, $status, $totalRows, $message]);

            return;
        }

        $stmt = $this->pdo->prepare(
            "INSERT INTO import_files (
                source_file_name, file_type, local_file_name, file_hash, status, total_rows, message
            ) VALUES (?, 'PAYMENT BEFORE POST', ?, ?, ?, ?, ?)
            ON DUPLICATE KEY UPDATE
                source_file_name = VALUES(source_file_name),
                file_type = VALUES(file_type),
                local_file_name = VALUES(local_file_name),
                status = VALUES(status),
                total_rows = VALUES(total_rows),
                message = VALUES(message),
                imported_at = CURRENT_TIMESTAMP"
        );
        $stmt->execute([$fileName, $filePath, $fileHash, $status, $totalRows, $message]);
    }
}
