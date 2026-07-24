<?php

error_reporting(E_ALL);
ini_set('display_errors', 1);

require __DIR__ . '/../vendor/autoload.php';

use Dotenv\Dotenv;

$dotenv = Dotenv::createImmutable(__DIR__ . '/../config');
$dotenv->load();

echo "=========================\n";
echo "START IMPORT\n";
echo "=========================\n";

require __DIR__ . '/download_csv.php';

/* =====================================================
   Helper Functions
===================================================== */

function cleanValue($value)
{
    $value = trim((string)$value);
    return $value === '' ? null : $value;
}

function normalizeHeaderName($header)
{
    $header = (string)$header;

    $header = preg_replace('/^\xEF\xBB\xBF/', '', $header);
    $header = str_replace("\xEF\xBB\xBF", '', $header);

    $header = trim($header);
    $header = trim($header, "\"' ");
    $header = strtolower($header);

    $header = str_replace(['／', '\\'], '/', $header);
    $header = preg_replace('/\s+/', ' ', $header);

    $map = [
        'import/export reference' => 'import_export_reference',
        'import / export reference' => 'import_export_reference',

        'company' => 'company',
        'bank account code' => 'bank_account_code',
        'transaction date' => 'transaction_date',
        'cashflow' => 'cashflow',
        'journal batch' => 'journal_batch',
        'voucher number' => 'voucher_number',
        'description' => 'description',

        'vendor account' => 'vendor_account',
        'vendor name' => 'vendor_name',
        'e-mail address' => 'email_address',
        'email address' => 'email_address',
        'purchase order' => 'purchase_order',
        'invoice number' => 'invoice_number',

        'vendor bank account code' => 'vendor_bank_account_code',
        'vendor bank account number' => 'vendor_bank_account_number',
        'bank transaction type' => 'bank_transaction_type',
        'method of payment' => 'method_of_payment',

        'invoice amount' => 'invoice_amount',
        'currency' => 'currency',
        'exchange rate' => 'exchange_rate',
        'fee' => 'fee',
        'withholding tax amount' => 'withholding_tax_amount',
        'total amount' => 'total_amount',

        'workflow approval status' => 'workflow_approval_status',
        'comment' => 'comment'
    ];

    if (isset($map[$header])) {
        return $map[$header];
    }

    return trim(preg_replace('/[^a-z0-9]+/', '_', $header), '_');
}

function detectDelimiter($filePath)
{
    $handle = fopen($filePath, 'r');

    if (!$handle) {
        throw new Exception("Cannot open CSV file for delimiter detection");
    }

    $line = fgets($handle);
    fclose($handle);

    if ($line === false) {
        return ',';
    }

    $commaCount = substr_count($line, ',');
    $semicolonCount = substr_count($line, ';');

    return $semicolonCount > $commaCount ? ';' : ',';
}

function parseDateValue($value)
{
    $value = cleanValue($value);

    if (!$value) {
        return null;
    }

    foreach (['j/n/Y', 'd/m/Y', 'Y-m-d'] as $format) {
        $dt = DateTime::createFromFormat($format, $value);

        if ($dt) {
            return $dt->format('Y-m-d');
        }
    }

    return null;
}

function parseNumberValue($value)
{
    $value = cleanValue($value);

    if (!$value) {
        return 0;
    }

    $value = str_replace([',', ' '], '', $value);

    return is_numeric($value) ? $value : 0;
}

function getWorkflowPriority($status)
{
    $status = strtolower(trim((string)$status));

    $map = [
        'in review' => 1,
        'submitted' => 2,
        'approved' => 3
    ];

    return $map[$status] ?? 0;
}

function buildBusinessKey($data)
{
    return implode('|', [
        $data['company'],
        $data['journal_batch'],
        $data['voucher_number'],
        $data['invoice_number']
    ]);
}

function buildRowHash($data)
{
    ksort($data);

    return hash(
        'sha256',
        json_encode($data, JSON_UNESCAPED_UNICODE)
    );
}

function buildCsvRow($headers, $data)
{
    $headerCount = count($headers);
    $dataCount = count($data);

    if ($dataCount < $headerCount) {
        $data = array_pad($data, $headerCount, null);
    }

    if ($dataCount > $headerCount) {
        $data = array_slice($data, 0, $headerCount);
    }

    return array_combine($headers, $data);
}

function buildCurrentData($row)
{
    return [
        'import_export_reference' => cleanValue($row['import_export_reference'] ?? null),

        'company' => cleanValue($row['company'] ?? null),
        'journal_batch' => cleanValue($row['journal_batch'] ?? null),
        'voucher_number' => cleanValue($row['voucher_number'] ?? null),
        'invoice_number' => cleanValue($row['invoice_number'] ?? null),

        'bank_account_code' => cleanValue($row['bank_account_code'] ?? null),
        'transaction_date' => parseDateValue($row['transaction_date'] ?? null),
        'cashflow' => cleanValue($row['cashflow'] ?? null),
        'description' => cleanValue($row['description'] ?? null),

        'vendor_account' => cleanValue($row['vendor_account'] ?? null),
        'vendor_name' => cleanValue($row['vendor_name'] ?? null),
        'email_address' => cleanValue($row['email_address'] ?? null),
        'purchase_order' => cleanValue($row['purchase_order'] ?? null),

        'vendor_bank_account_code' => cleanValue($row['vendor_bank_account_code'] ?? null),
        'vendor_bank_account_number' => cleanValue($row['vendor_bank_account_number'] ?? null),
        'bank_transaction_type' => cleanValue($row['bank_transaction_type'] ?? null),
        'method_of_payment' => cleanValue($row['method_of_payment'] ?? null),

        'invoice_amount' => parseNumberValue($row['invoice_amount'] ?? null),
        'currency' => cleanValue($row['currency'] ?? null),
        'exchange_rate' => parseNumberValue($row['exchange_rate'] ?? null),
        'fee' => parseNumberValue($row['fee'] ?? null),
        'withholding_tax_amount' => parseNumberValue($row['withholding_tax_amount'] ?? null),
        'total_amount' => parseNumberValue($row['total_amount'] ?? null),

        'workflow_approval_status' => cleanValue($row['workflow_approval_status'] ?? null),
        'comment' => cleanValue($row['comment'] ?? null)
    ];
}

function buildOldData($existing)
{
    return [
        'import_export_reference' => $existing['import_export_reference'],
        'company' => $existing['company'],
        'journal_batch' => $existing['journal_batch'],
        'voucher_number' => $existing['voucher_number'],
        'invoice_number' => $existing['invoice_number'],

        'bank_account_code' => $existing['bank_account_code'],
        'transaction_date' => $existing['transaction_date'],
        'cashflow' => $existing['cashflow'],
        'description' => $existing['description'],

        'vendor_account' => $existing['vendor_account'],
        'vendor_name' => $existing['vendor_name'],
        'email_address' => $existing['email_address'],
        'purchase_order' => $existing['purchase_order'],

        'vendor_bank_account_code' => $existing['vendor_bank_account_code'],
        'vendor_bank_account_number' => $existing['vendor_bank_account_number'],
        'bank_transaction_type' => $existing['bank_transaction_type'],
        'method_of_payment' => $existing['method_of_payment'],

        'invoice_amount' => $existing['invoice_amount'],
        'currency' => $existing['currency'],
        'exchange_rate' => $existing['exchange_rate'],
        'fee' => $existing['fee'],
        'withholding_tax_amount' => $existing['withholding_tax_amount'],
        'total_amount' => $existing['total_amount'],

        'workflow_approval_status' => $existing['workflow_approval_status'],
        'comment' => $existing['comment']
    ];
}

function isBetterCurrentRow($newData, $oldItem)
{
    $newPriority = getWorkflowPriority($newData['workflow_approval_status']);
    $oldPriority = $oldItem['priority'];

    if ($newPriority > $oldPriority) {
        return true;
    }

    if ($newPriority < $oldPriority) {
        return false;
    }

    $newRef = $newData['import_export_reference'] ?? '';
    $oldRef = $oldItem['data']['import_export_reference'] ?? '';

    return strcmp($newRef, $oldRef) > 0;
}

/* =====================================================
   Prepare File
===================================================== */

$downloadDir = __DIR__ . '/../download';
$archiveDir  = __DIR__ . '/../archive';

if (!is_dir($archiveDir)) {
    mkdir($archiveDir, 0777, true);
}

$files = glob($downloadDir . '/*.csv');

if (!$files) {
    die("NO CSV FILE FOUND\n");
}

usort($files, fn($a, $b) => filemtime($b) - filemtime($a));

$latestFile = $files[0];
$fileName = basename($latestFile);
$fileHash = hash_file('sha256', $latestFile);

echo "LATEST FILE: {$fileName}\n";
echo "FILE HASH: {$fileHash}\n";

/* =====================================================
   DB Connect
===================================================== */

$pdo = new PDO(
    "mysql:host={$_ENV['DB_HOST']};dbname={$_ENV['DB_NAME']};charset=utf8mb4",
    $_ENV['DB_USER'],
    $_ENV['DB_PASS'],
    [PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION]
);

echo "DB CONNECTED\n";

/* =====================================================
   Skip Duplicate File
===================================================== */

$checkFile = $pdo->prepare("
    SELECT id
    FROM import_files
    WHERE file_hash = ?
    AND status = 'SUCCESS'
    LIMIT 1
");

$checkFile->execute([$fileHash]);

if ($checkFile->fetch()) {
    echo "THIS FILE HASH ALREADY IMPORTED - SKIPPED\n";
    exit;
}

/* =====================================================
   Main Import
===================================================== */

try {

    $pdo->beginTransaction();

    $pdo->exec("DELETE FROM stg_payment_before_post");

    $delimiter = detectDelimiter($latestFile);
    echo "CSV DELIMITER: {$delimiter}\n";

    $handle = fopen($latestFile, 'r');

    if (!$handle) {
        throw new Exception("Cannot open CSV file");
    }

    $headers = fgetcsv($handle, 0, $delimiter);

    if (!$headers) {
        throw new Exception("CSV header not found");
    }

    $headers = array_map('normalizeHeaderName', $headers);

    echo "CSV HEADERS FOUND: " . count($headers) . "\n";
    echo "NORMALIZED HEADERS:\n";
    print_r($headers);

    $insertStg = $pdo->prepare("
        INSERT INTO stg_payment_before_post (
            source_file_name,
            file_hash,
            import_export_reference,
            company,
            bank_account_code,
            transaction_date,
            cashflow,
            journal_batch,
            voucher_number,
            description,
            vendor_account,
            vendor_name,
            email_address,
            purchase_order,
            invoice_number,
            vendor_bank_account_code,
            vendor_bank_account_number,
            bank_transaction_type,
            method_of_payment,
            invoice_amount,
            currency,
            exchange_rate,
            fee,
            withholding_tax_amount,
            total_amount,
            workflow_approval_status,
            comment
        ) VALUES (
            ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?
        )
    ");

    $selectedRows = [];
    $stagingRowCount = 0;

    while (($data = fgetcsv($handle, 0, $delimiter)) !== false) {

        if (count(array_filter($data, fn($v) => trim((string)$v) !== '')) === 0) {
            continue;
        }

        $row = buildCsvRow($headers, $data);

        if (!$row) {
            continue;
        }

        $currentData = buildCurrentData($row);

        $insertStg->execute([
            $fileName,
            $fileHash,
            $currentData['import_export_reference'],
            $currentData['company'],
            $currentData['bank_account_code'],
            $currentData['transaction_date'],
            $currentData['cashflow'],
            $currentData['journal_batch'],
            $currentData['voucher_number'],
            $currentData['description'],
            $currentData['vendor_account'],
            $currentData['vendor_name'],
            $currentData['email_address'],
            $currentData['purchase_order'],
            $currentData['invoice_number'],
            $currentData['vendor_bank_account_code'],
            $currentData['vendor_bank_account_number'],
            $currentData['bank_transaction_type'],
            $currentData['method_of_payment'],
            $currentData['invoice_amount'],
            $currentData['currency'],
            $currentData['exchange_rate'],
            $currentData['fee'],
            $currentData['withholding_tax_amount'],
            $currentData['total_amount'],
            $currentData['workflow_approval_status'],
            $currentData['comment']
        ]);

        $businessKey = buildBusinessKey($currentData);
        $currentPriority = getWorkflowPriority($currentData['workflow_approval_status']);

        if (!isset($selectedRows[$businessKey])) {
            $selectedRows[$businessKey] = [
                'data' => $currentData,
                'priority' => $currentPriority
            ];
        } else {
            if (isBetterCurrentRow($currentData, $selectedRows[$businessKey])) {
                $selectedRows[$businessKey] = [
                    'data' => $currentData,
                    'priority' => $currentPriority
                ];
            }
        }

        $stagingRowCount++;
    }

    fclose($handle);

    /* =====================================================
       Prepare Main Statements
    ===================================================== */

    $selectMain = $pdo->prepare("
        SELECT *
        FROM payment_before_post
        WHERE company <=> ?
        AND journal_batch <=> ?
        AND voucher_number <=> ?
        AND invoice_number <=> ?
        LIMIT 1
    ");

    $insertMain = $pdo->prepare("
        INSERT INTO payment_before_post (
            source_file_name,
            file_hash,
            row_hash,
            first_seen_at,
            last_seen_at,
            last_changed_at,
            import_export_reference,
            company,
            bank_account_code,
            transaction_date,
            cashflow,
            journal_batch,
            voucher_number,
            description,
            vendor_account,
            vendor_name,
            email_address,
            purchase_order,
            invoice_number,
            vendor_bank_account_code,
            vendor_bank_account_number,
            bank_transaction_type,
            method_of_payment,
            invoice_amount,
            currency,
            exchange_rate,
            fee,
            withholding_tax_amount,
            total_amount,
            workflow_approval_status,
            comment
        ) VALUES (
            ?, ?, ?, NOW(), NOW(), NOW(),
            ?, ?, ?, ?, ?, ?, ?, ?,
            ?, ?, ?, ?, ?,
            ?, ?, ?, ?,
            ?, ?, ?, ?, ?, ?,
            ?, ?
        )
    ");

    $updateSeenOnly = $pdo->prepare("
        UPDATE payment_before_post
        SET
            source_file_name = ?,
            file_hash = ?,
            last_seen_at = NOW()
        WHERE id = ?
    ");

    $updateMain = $pdo->prepare("
        UPDATE payment_before_post
        SET
            source_file_name = ?,
            file_hash = ?,
            row_hash = ?,
            last_seen_at = NOW(),
            last_changed_at = NOW(),
            import_export_reference = ?,
            bank_account_code = ?,
            transaction_date = ?,
            cashflow = ?,
            description = ?,
            vendor_account = ?,
            vendor_name = ?,
            email_address = ?,
            purchase_order = ?,
            vendor_bank_account_code = ?,
            vendor_bank_account_number = ?,
            bank_transaction_type = ?,
            method_of_payment = ?,
            invoice_amount = ?,
            currency = ?,
            exchange_rate = ?,
            fee = ?,
            withholding_tax_amount = ?,
            total_amount = ?,
            workflow_approval_status = ?,
            comment = ?
        WHERE id = ?
    ");

    $insertHistory = $pdo->prepare("
        INSERT INTO payment_before_post_history (
            payment_id,
            source_file_name,
            import_export_reference,
            row_hash,
            action_type,
            old_data,
            new_data
        ) VALUES (?, ?, ?, ?, ?, ?, ?)
    ");

    $newCount = 0;
    $sameCount = 0;
    $updateCount = 0;

    foreach ($selectedRows as $item) {

        $currentData = $item['data'];
        $rowHash = buildRowHash($currentData);

        $selectMain->execute([
            $currentData['company'],
            $currentData['journal_batch'],
            $currentData['voucher_number'],
            $currentData['invoice_number']
        ]);

        $existing = $selectMain->fetch(PDO::FETCH_ASSOC);

        if (!$existing) {

            $insertMain->execute([
                $fileName,
                $fileHash,
                $rowHash,

                $currentData['import_export_reference'],
                $currentData['company'],
                $currentData['bank_account_code'],
                $currentData['transaction_date'],
                $currentData['cashflow'],
                $currentData['journal_batch'],
                $currentData['voucher_number'],
                $currentData['description'],

                $currentData['vendor_account'],
                $currentData['vendor_name'],
                $currentData['email_address'],
                $currentData['purchase_order'],
                $currentData['invoice_number'],

                $currentData['vendor_bank_account_code'],
                $currentData['vendor_bank_account_number'],
                $currentData['bank_transaction_type'],
                $currentData['method_of_payment'],

                $currentData['invoice_amount'],
                $currentData['currency'],
                $currentData['exchange_rate'],
                $currentData['fee'],
                $currentData['withholding_tax_amount'],
                $currentData['total_amount'],

                $currentData['workflow_approval_status'],
                $currentData['comment']
            ]);

            $paymentId = $pdo->lastInsertId();

            $insertHistory->execute([
                $paymentId,
                $fileName,
                $currentData['import_export_reference'],
                $rowHash,
                'INSERT',
                null,
                json_encode($currentData, JSON_UNESCAPED_UNICODE)
            ]);

            $newCount++;
        } else {

            if ($existing['row_hash'] === $rowHash) {

                $updateSeenOnly->execute([
                    $fileName,
                    $fileHash,
                    $existing['id']
                ]);

                $sameCount++;
            } else {

                $oldData = buildOldData($existing);

                $updateMain->execute([
                    $fileName,
                    $fileHash,
                    $rowHash,

                    $currentData['import_export_reference'],
                    $currentData['bank_account_code'],
                    $currentData['transaction_date'],
                    $currentData['cashflow'],
                    $currentData['description'],

                    $currentData['vendor_account'],
                    $currentData['vendor_name'],
                    $currentData['email_address'],
                    $currentData['purchase_order'],

                    $currentData['vendor_bank_account_code'],
                    $currentData['vendor_bank_account_number'],
                    $currentData['bank_transaction_type'],
                    $currentData['method_of_payment'],

                    $currentData['invoice_amount'],
                    $currentData['currency'],
                    $currentData['exchange_rate'],
                    $currentData['fee'],
                    $currentData['withholding_tax_amount'],
                    $currentData['total_amount'],

                    $currentData['workflow_approval_status'],
                    $currentData['comment'],

                    $existing['id']
                ]);

                $insertHistory->execute([
                    $existing['id'],
                    $fileName,
                    $currentData['import_export_reference'],
                    $rowHash,
                    'UPDATE',
                    json_encode($oldData, JSON_UNESCAPED_UNICODE),
                    json_encode($currentData, JSON_UNESCAPED_UNICODE)
                ]);

                $updateCount++;
            }
        }
    }

    /* =====================================================
       Import Log
    ===================================================== */

    $insertLog = $pdo->prepare("
        INSERT INTO import_files (
            source_file_name,
            file_type,
            local_file_name,
            file_hash,
            status,
            total_rows,
            message
        ) VALUES (?,'PAYMENT BEFORE POST', ?, ?, 'SUCCESS', ?, ?)
        ON DUPLICATE KEY UPDATE
            source_file_name = VALUES(source_file_name),
            file_type = VALUES(file_type),
            local_file_name = VALUES(local_file_name),
            status = VALUES(status),
            total_rows = VALUES(total_rows),
            message = VALUES(message),
            imported_at = CURRENT_TIMESTAMP
    ");

    $insertLog->execute([
        $fileName,
        $latestFile,
        $fileHash,
        $stagingRowCount,
        "Import completed | staging={$stagingRowCount}, selected=" . count($selectedRows) . ", new={$newCount}, updated={$updateCount}, same={$sameCount}"
    ]);

    $archivePath = $archiveDir . '/' . date('Ymd_His_') . $fileName;
    copy($latestFile, $archivePath);

    $pdo->commit();

    echo "STAGING ROWS: {$stagingRowCount}\n";
    echo "SELECTED CURRENT ROWS: " . count($selectedRows) . "\n";
    echo "NEW ROWS: {$newCount}\n";
    echo "UPDATED ROWS: {$updateCount}\n";
    echo "UNCHANGED ROWS: {$sameCount}\n";
    echo "IMPORT SUCCESS\n";
    echo "ARCHIVE: {$archivePath}\n";
} catch (Exception $e) {

    if (isset($handle) && is_resource($handle)) {
        fclose($handle);
    }

    if ($pdo->inTransaction()) {
        $pdo->rollBack();
    }

    try {
        $insertError = $pdo->prepare("
    INSERT INTO import_files (
        source_file_name,
        file_type,
        local_file_name,
        file_hash,
        status,
        total_rows,
        message
    ) VALUES (?, 'PAYMENT BEFORE POST', ?, ?, 'ERROR', 0, ?)
    ON DUPLICATE KEY UPDATE
        source_file_name = VALUES(source_file_name),
        file_type = VALUES(file_type),
        local_file_name = VALUES(local_file_name),
        status = VALUES(status),
        total_rows = VALUES(total_rows),
        message = VALUES(message),
        imported_at = CURRENT_TIMESTAMP
");

        $insertError->execute([
            $fileName,
            $latestFile,
            $fileHash,
            $e->getMessage()
        ]);
    } catch (Exception $logError) {
        echo "LOG ERROR: " . $logError->getMessage() . "\n";
    }

    die("IMPORT ERROR: " . $e->getMessage() . "\n");
}

echo "=========================\n";
echo "FINISH IMPORT\n";
echo "=========================\n";
