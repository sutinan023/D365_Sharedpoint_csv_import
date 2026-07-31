<?php

namespace App\Database;

use JsonException;
use RuntimeException;

final class BackupCheckpointValidator
{
    private const COUNTS = ['import_files', 'payment_outbound', 'payment_mail_log', 'sharepoint_file_queue'];
    private const VIEWS = ['vw_import_report', 'v_tbpayin_from_payment_outbound'];
    private const ROOTS = [
        'C:\\xampp\\backups\\d365\\uat',
        'C:\\xampp\\backups\\d365\\prod',
        '\\\\100.1.1.166\\c$\\xampp\\backups\\d365\\uat',
        '\\\\100.1.1.166\\c$\\xampp\\backups\\d365\\prod',
    ];

    public static function validate(
        string $manifestPath,
        string $receiptPath,
        string $database,
        string $releaseId,
        ?string $localTestRoot = null
    ): array {
        $root = self::selectRoot($manifestPath, $localTestRoot);
        $manifestPath = self::trustedFile($manifestPath, $root);
        $receiptPath = self::trustedFile($receiptPath, $root);
        if ($localTestRoot === null) {
            self::assertProtectedAcl([$root, $manifestPath, $receiptPath]);
        }

        $manifestSnapshot = self::readJsonSnapshot($manifestPath, 'backup manifest');
        $manifest = $manifestSnapshot['value'];
        $segment = $database === 'D365_finance' ? 'uat' : ($database === 'D365_finance_prod' ? 'prod' : '');
        if ($segment === '' || strcasecmp((string)($manifest['database'] ?? ''), $database) !== 0
            || (string)($manifest['release_id'] ?? '') !== $releaseId
            || ($localTestRoot === null && strcasecmp(basename(str_replace('\\', '/', $root)), $segment) !== 0)) {
            throw new RuntimeException('Backup manifest database, release, or trusted environment segment is invalid.');
        }

        $backupPath = self::trustedFile(self::stringField($manifest, 'backup_file', 'backup manifest'), $root);
        $backup = self::readArtifactSnapshot($backupPath, 'backup');
        self::matchArtifact($backup, $manifest['sha256'] ?? null, $manifest['size_bytes'] ?? null, 'backup manifest');

        $receiptSnapshot = self::readJsonSnapshot($receiptPath, 'restore rehearsal receipt');
        $receipt = $receiptSnapshot['value'];
        if (($receipt['status'] ?? null) !== 'PASSED' || ($receipt['release_id'] ?? null) !== $releaseId
            || strcasecmp((string)($receipt['database'] ?? ''), $database) !== 0
            || trim((string)($receipt['approved_at'] ?? '')) === '' || trim((string)($receipt['approved_by'] ?? '')) === '') {
            throw new RuntimeException('Restore rehearsal receipt is legacy, incomplete, or mismatched.');
        }
        if (self::normalize(self::trustedFile(self::stringField($receipt, 'backup_path', 'receipt'), $root)) !== self::normalize($backupPath)) {
            throw new RuntimeException('Receipt backup path does not match the manifest.');
        }
        self::matchArtifact($backup, $receipt['backup_sha256'] ?? null, $receipt['backup_size_bytes'] ?? null, 'receipt backup');

        $auditPath = self::trustedFile(self::stringField($receipt, 'sanitizer_audit_path', 'receipt'), $root);
        $sanitizedPath = self::trustedFile(self::stringField($receipt, 'sanitized_path', 'receipt'), $root);
        $evidencePath = self::trustedFile(self::stringField($receipt, 'evidence_path', 'receipt'), $root);
        if ($localTestRoot === null) {
            self::assertProtectedAcl([$backupPath, $auditPath, $sanitizedPath, $evidencePath]);
        }
        $audit = self::readJsonSnapshot($auditPath, 'sanitizer audit');
        $sanitized = self::readArtifactSnapshot($sanitizedPath, 'sanitized backup');
        $evidence = self::readJsonSnapshot($evidencePath, 'restore evidence');
        self::matchArtifact($audit, $receipt['sanitizer_audit_sha256'] ?? null, $receipt['sanitizer_audit_size_bytes'] ?? null, 'receipt sanitizer audit');
        self::matchArtifact($sanitized, $receipt['sanitized_sha256'] ?? null, $receipt['sanitized_size_bytes'] ?? null, 'receipt sanitized backup');
        self::matchArtifact($evidence, $receipt['evidence_sha256'] ?? null, $receipt['evidence_size_bytes'] ?? null, 'receipt evidence');

        $auditValue = $audit['value'];
        if (self::normalize(self::trustedFile(self::stringField($auditValue, 'source_path', 'sanitizer audit'), $root)) !== self::normalize($backupPath)
            || self::normalize(self::trustedFile(self::stringField($auditValue, 'sanitized_path', 'sanitizer audit'), $root)) !== self::normalize($sanitizedPath)
            || ($auditValue['source_database'] ?? null) !== $database
            || !self::sameHash($auditValue['source_sha256'] ?? null, $backup['hash'])
            || !self::sameHash($auditValue['sanitized_sha256'] ?? null, $sanitized['hash'])) {
            throw new RuntimeException('Sanitizer audit does not bind the verified artifacts.');
        }
        self::nativeNonNegative($auditValue['sanitized_size_bytes'] ?? null, 'sanitizer audit size');
        if ($auditValue['sanitized_size_bytes'] !== $sanitized['size']) {
            throw new RuntimeException('Sanitizer audit size does not match.');
        }

        $proof = $evidence['value'];
        if (($proof['status'] ?? null) !== 'VERIFIED' || ($proof['release_id'] ?? null) !== $releaseId
            || strcasecmp((string)($proof['database'] ?? ''), $database) !== 0
            || !self::sameHash($proof['backup_sha256'] ?? null, $backup['hash'])
            || !self::sameHash($proof['sanitized_sha256'] ?? null, $sanitized['hash'])) {
            throw new RuntimeException('Restore evidence does not bind the verified artifacts.');
        }
        self::assertEvidence($proof);
        if (($receipt['rehearsal_database'] ?? null) !== $proof['rehearsal_database']
            || ($receipt['row_counts'] ?? null) !== $proof['row_counts']
            || ($receipt['views'] ?? null) !== $proof['views']
            || ($receipt['live_schema_reference_count'] ?? null) !== 0) {
            throw new RuntimeException('Restore receipt does not copy verified evidence exactly.');
        }
        return $manifest;
    }

    private static function selectRoot(string $manifestPath, ?string $localTestRoot): string
    {
        if ($localTestRoot !== null) {
            $root = realpath($localTestRoot);
            $temp = realpath(sys_get_temp_dir());
            if ($root === false || $temp === false || !is_dir($root) || !self::inside($root, $temp) || self::normalize($root) === self::normalize($temp)) {
                throw new RuntimeException('Local test root must be a dedicated directory under system temp.');
            }
            return $root;
        }
        foreach (self::ROOTS as $root) {
            if (is_dir($root) && self::inside($manifestPath, $root)) {
                return $root;
            }
        }
        throw new RuntimeException('Backup manifest is outside approved D365 backup roots.');
    }

    private static function trustedFile(string $path, string $root): string
    {
        if (preg_match('#(?:^|[\\\\/])(?:\.{1,2}|[^\\\\/]*~[0-9]+)(?:[\\\\/]|$)#i', $path)) {
            throw new RuntimeException('Artifact path aliases are not allowed.');
        }
        $real = realpath($path);
        if ($real === false || !is_file($real) || !self::inside($real, $root) || self::normalize($real) !== self::normalize($path)) {
            throw new RuntimeException('Artifact path is missing, aliased, reparsed, or outside the trusted root.');
        }
        for ($current = $real; self::inside($current, $root); $current = dirname($current)) {
            if (is_link($current)) {
                throw new RuntimeException('Artifact path contains a reparse component.');
            }
            if (self::normalize($current) === self::normalize($root)) {
                break;
            }
        }
        return $real;
    }

    private static function inside(string $path, string $root): bool
    {
        $path = self::normalize($path); $root = rtrim(self::normalize($root), '\\');
        return $path === $root || str_starts_with($path, $root . '\\');
    }

    private static function normalize(string $path): string
    {
        return strtolower(rtrim(str_replace('/', '\\', $path), '\\'));
    }

    private static function readArtifactSnapshot(string $path, string $label): array
    {
        $bytes = file_get_contents($path);
        if ($bytes === false) { throw new RuntimeException(ucfirst($label) . ' cannot be read.'); }
        return ['path' => $path, 'bytes' => $bytes, 'hash' => hash('sha256', $bytes), 'size' => strlen($bytes)];
    }

    private static function readJsonSnapshot(string $path, string $label): array
    {
        $snapshot = self::readArtifactSnapshot($path, $label);
        $text = $snapshot['bytes'];
        if (!preg_match('//u', $text)) { throw new RuntimeException(ucfirst($label) . ' is not strict UTF-8.'); }
        if (str_starts_with($text, "\xEF\xBB\xBF")) { $text = substr($text, 3); }
        self::rejectDuplicateKeys($text, $label);
        try { $value = json_decode($text, true, 512, JSON_THROW_ON_ERROR); }
        catch (JsonException $exception) { throw new RuntimeException(ucfirst($label) . ' is not valid JSON.', 0, $exception); }
        if (!is_array($value) || array_is_list($value)) { throw new RuntimeException(ucfirst($label) . ' must be a JSON object.'); }
        $snapshot['value'] = $value;
        return $snapshot;
    }

    private static function rejectDuplicateKeys(string $json, string $label): void
    {
        $index = 0; self::scanValue($json, $index, $label); self::skipWhitespace($json, $index);
        if ($index !== strlen($json)) { throw new RuntimeException(ucfirst($label) . ' has trailing JSON content.'); }
    }

    private static function scanValue(string $json, int &$index, string $label): void
    {
        self::skipWhitespace($json, $index); $length = strlen($json);
        if ($index >= $length) { throw new RuntimeException(ucfirst($label) . ' ended unexpectedly.'); }
        if ($json[$index] === '{') { self::scanObject($json, $index, $label); return; }
        if ($json[$index] === '[') { self::scanArray($json, $index, $label); return; }
        if ($json[$index] === '"') { self::scanString($json, $index, $label); return; }
        if (preg_match('/\G(?:true|false|null|-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?)/', $json, $match, 0, $index) === 1) { $index += strlen($match[0]); return; }
        throw new RuntimeException(ucfirst($label) . ' contains an invalid JSON value.');
    }

    private static function scanObject(string $json, int &$index, string $label): void
    {
        $index++; self::skipWhitespace($json, $index); $keys = [];
        if (($json[$index] ?? '') === '}') { $index++; return; }
        while (true) {
            $key = self::scanString($json, $index, $label);
            if (array_key_exists($key, $keys)) { throw new RuntimeException(ucfirst($label) . " contains duplicate object key: $key"); }
            $keys[$key] = true; self::skipWhitespace($json, $index); self::expect($json, $index, ':', $label); self::scanValue($json, $index, $label); self::skipWhitespace($json, $index);
            if (($json[$index] ?? '') === '}') { $index++; return; }
            self::expect($json, $index, ',', $label);
        }
    }

    private static function scanArray(string $json, int &$index, string $label): void
    {
        $index++; self::skipWhitespace($json, $index); if (($json[$index] ?? '') === ']') { $index++; return; }
        while (true) { self::scanValue($json, $index, $label); self::skipWhitespace($json, $index); if (($json[$index] ?? '') === ']') { $index++; return; } self::expect($json, $index, ',', $label); }
    }

    private static function scanString(string $json, int &$index, string $label): string
    {
        self::skipWhitespace($json, $index); $start = $index; self::expect($json, $index, '"', $label); $length = strlen($json);
        while ($index < $length) {
            $byte = ord($json[$index++]);
            if ($byte === 34) {
                $token = substr($json, $start, $index - $start);
                try { return json_decode($token, true, 512, JSON_THROW_ON_ERROR); }
                catch (JsonException $exception) { throw new RuntimeException(ucfirst($label) . ' contains an invalid JSON string.', 0, $exception); }
            }
            if ($byte < 32) { throw new RuntimeException(ucfirst($label) . ' contains a control character.'); }
            if ($byte === 92) { if ($index >= $length) { throw new RuntimeException(ucfirst($label) . ' has an incomplete escape.'); } $escape = $json[$index++]; if (!str_contains('"\\/bfnrtu', $escape)) { throw new RuntimeException(ucfirst($label) . ' has an invalid escape.'); } if ($escape === 'u') { $hex = substr($json, $index, 4); if (strlen($hex) !== 4 || !ctype_xdigit($hex)) { throw new RuntimeException(ucfirst($label) . ' has an invalid Unicode escape.'); } $index += 4; } }
        }
        throw new RuntimeException(ucfirst($label) . ' has an unterminated string.');
    }

    private static function skipWhitespace(string $json, int &$index): void { $length = strlen($json); while ($index < $length && str_contains(" \t\r\n", $json[$index])) { $index++; } }
    private static function expect(string $json, int &$index, string $expected, string $label): void { self::skipWhitespace($json, $index); if (($json[$index] ?? '') !== $expected) { throw new RuntimeException(ucfirst($label) . " expected $expected."); } $index++; }
    private static function matchArtifact(array $snapshot, mixed $hash, mixed $size, string $label): void { self::nativeNonNegative($size, "$label size"); if (!self::sameHash($hash, $snapshot['hash']) || $size !== $snapshot['size']) { throw new RuntimeException(ucfirst($label) . ' hash or size does not match.'); } }
    private static function sameHash(mixed $expected, string $actual): bool { return is_string($expected) && preg_match('/^[a-f0-9]{64}$/i', $expected) === 1 && hash_equals(strtolower($expected), strtolower($actual)); }
    private static function nativeNonNegative(mixed $value, string $label): void { if (!is_int($value) || $value < 0) { throw new RuntimeException(ucfirst($label) . ' must be a native nonnegative integer.'); } }
    private static function stringField(array $object, string $key, string $label): string { if (!isset($object[$key]) || !is_string($object[$key]) || trim($object[$key]) === '') { throw new RuntimeException(ucfirst($label) . " is missing $key."); } return $object[$key]; }
    private static function exactKeys(array $object, array $expected, string $label): void { $actual = array_keys($object); sort($actual); sort($expected); if ($actual !== $expected) { throw new RuntimeException(ucfirst($label) . ' has missing or extra keys.'); } }
    private static function assertEvidence(array $proof): void
    {
        $rehearsal = $proof['rehearsal_database'] ?? null;
        if (!is_string($rehearsal) || !preg_match('/^[A-Za-z0-9_]*rehearsal[A-Za-z0-9_]*$/i', $rehearsal) || strcasecmp($rehearsal, (string)($proof['database'] ?? '')) === 0) { throw new RuntimeException('Restore evidence rehearsal database is unsafe.'); }
        if (!is_array($proof['row_counts'] ?? null) || !is_array($proof['views'] ?? null)) { throw new RuntimeException('Restore evidence counts or views are invalid.'); }
        self::exactKeys($proof['row_counts'], self::COUNTS, 'row_counts'); foreach (self::COUNTS as $name) { self::nativeNonNegative($proof['row_counts'][$name], "row_counts.$name"); }
        self::exactKeys($proof['views'], self::VIEWS, 'views'); foreach (self::VIEWS as $name) { if (!is_array($proof['views'][$name])) { throw new RuntimeException("View $name is invalid."); } self::exactKeys($proof['views'][$name], ['row_count', 'security_type'], "views.$name"); self::nativeNonNegative($proof['views'][$name]['row_count'], "views.$name.row_count"); if ($proof['views'][$name]['security_type'] !== 'INVOKER') { throw new RuntimeException("View $name must use INVOKER."); } }
        self::nativeNonNegative($proof['live_schema_reference_count'] ?? null, 'live schema reference count'); if ($proof['live_schema_reference_count'] !== 0 || trim((string)($proof['verified_at'] ?? '')) === '' || trim((string)($proof['verified_by'] ?? '')) === '') { throw new RuntimeException('Restore evidence verification metadata is invalid.'); }
    }

    private static function assertProtectedAcl(array $paths): void
    {
        if (PHP_OS_FAMILY !== 'Windows' || !function_exists('exec')) { throw new RuntimeException('Trusted-root ACL validation is unavailable.'); }
        foreach (array_unique($paths) as $path) {
            $output = []; $code = 0; exec('icacls ' . escapeshellarg($path), $output, $code);
            if ($code !== 0) { throw new RuntimeException('Trusted-root ACL could not be verified.'); }
            $acl = implode("\n", $output);
            if (preg_match('/(?:Everyone|Authenticated Users|BUILTIN\\\\Users|S-1-1-0|S-1-5-11|S-1-5-32-545).*\((?:F|M|W|WD|AD|DC|WA|WEA)\)/i', $acl)) { throw new RuntimeException('Trusted-root ACL grants broad write access.'); }
        }
    }
}
