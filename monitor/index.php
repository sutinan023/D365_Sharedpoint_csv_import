<?php
session_start();

require __DIR__ . '/../vendor/autoload.php';

use Dotenv\Dotenv;

$dotenv = Dotenv::createImmutable(__DIR__ . '/../config');
$dotenv->load();

function db()
{
    return new PDO(
        "mysql:host={$_ENV['DB_HOST']};dbname={$_ENV['DB_NAME']};charset=utf8mb4",
        $_ENV['DB_USER'],
        $_ENV['DB_PASS'],
        [PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION]
    );
}

if (isset($_GET['logout'])) {
    session_destroy();
    header("Location: index.php");
    exit;
}

$error = null;

if ($_SERVER['REQUEST_METHOD'] === 'POST') {
    if (
        $_POST['username'] === $_ENV['ADMIN_USERNAME'] &&
        $_POST['password'] === $_ENV['ADMIN_PASSWORD']
    ) {
        $_SESSION['admin_logged_in'] = true;
        header("Location: index.php");
        exit;
    } else {
        $error = "Username หรือ Password ไม่ถูกต้อง";
    }
}

if (empty($_SESSION['admin_logged_in'])):
?>
<!doctype html>
<html lang="th">
<head>
    <meta charset="utf-8">
    <title>D365 Import Monitor</title>
    <link href="https://cdn.jsdelivr.net/npm/bootstrap@5.3.3/dist/css/bootstrap.min.css" rel="stylesheet">
</head>
<body class="bg-light">
<div class="container d-flex align-items-center justify-content-center" style="min-height:100vh;">
    <div class="card shadow-sm border-0" style="width:380px;">
        <div class="card-body p-4">
            <h4 class="mb-1">D365 Import Monitor</h4>
            <p class="text-muted small">Admin Login</p>

            <?php if ($error): ?>
                <div class="alert alert-danger py-2"><?= htmlspecialchars($error) ?></div>
            <?php endif; ?>

            <form method="post">
                <div class="mb-3">
                    <label class="form-label">Username</label>
                    <input name="username" class="form-control" required>
                </div>

                <div class="mb-3">
                    <label class="form-label">Password</label>
                    <input name="password" type="password" class="form-control" required>
                </div>

                <button class="btn btn-dark w-100">Login</button>
            </form>
        </div>
    </div>
</div>
</body>
</html>
<?php
exit;
endif;

$pdo = db();

$lastImport = $pdo->query("
    SELECT *
    FROM import_files
    ORDER BY imported_at DESC
    LIMIT 1
")->fetch(PDO::FETCH_ASSOC);

$todaySummary = $pdo->query("
    SELECT
        COUNT(*) AS total_import,
        SUM(status = 'SUCCESS') AS success_import,
        SUM(status = 'ERROR') AS error_import
    FROM import_files
    WHERE DATE(imported_at) = CURDATE()
")->fetch(PDO::FETCH_ASSOC);

$queueStatusStmt = $pdo->query("
    SELECT status, COUNT(*) AS total
    FROM sharepoint_file_queue
    GROUP BY status
    ORDER BY status
");
$queueStatusCounts = $queueStatusStmt->fetchAll(PDO::FETCH_ASSOC);

$queueLatestStmt = $pdo->query("
    SELECT file_name, status, attempt_count, last_error, downloaded_at, moved_at, imported_at, updated_at
    FROM sharepoint_file_queue
    ORDER BY updated_at DESC
    LIMIT 20
");
$queueLatestFiles = $queueLatestStmt->fetchAll(PDO::FETCH_ASSOC);

$oldestImportErrorStmt = $pdo->query("
    SELECT file_name, last_error, updated_at
    FROM sharepoint_file_queue
    WHERE status = 'IMPORT_ERROR'
    ORDER BY sharepoint_last_modified_at ASC, id ASC
    LIMIT 1
");
$oldestImportError = $oldestImportErrorStmt->fetch(PDO::FETCH_ASSOC);

$workflowSummary = $pdo->query("
    SELECT
        workflow_approval_status,
        COUNT(*) AS total_items,
        SUM(total_amount) AS total_amount
    FROM payment_before_post
    GROUP BY workflow_approval_status
    ORDER BY
        CASE workflow_approval_status
            WHEN 'In review' THEN 1
            WHEN 'Submitted' THEN 2
            WHEN 'Approved' THEN 3
            ELSE 99
        END
")->fetchAll(PDO::FETCH_ASSOC);

$importHistory = $pdo->query("
    SELECT *
    FROM import_files
    ORDER BY imported_at DESC
    LIMIT 20
")->fetchAll(PDO::FETCH_ASSOC);

$changedToday = $pdo->query("
    SELECT *
    FROM payment_before_post_history
    WHERE DATE(changed_at) = CURDATE()
    ORDER BY changed_at DESC
    LIMIT 20
")->fetchAll(PDO::FETCH_ASSOC);

$duplicateVoucher = $pdo->query("
    SELECT voucher_number, COUNT(*) AS duplicate_count
    FROM payment_before_post
    WHERE voucher_number IS NOT NULL
      AND voucher_number <> ''
    GROUP BY voucher_number
    HAVING COUNT(*) > 1
    ORDER BY duplicate_count DESC
    LIMIT 20
")->fetchAll(PDO::FETCH_ASSOC);
?>
<!doctype html>
<html lang="th">
<head>
    <meta charset="utf-8">
    <meta http-equiv="refresh" content="60">
    <title>D365 Import Monitor</title>
    <link href="https://cdn.jsdelivr.net/npm/bootstrap@5.3.3/dist/css/bootstrap.min.css" rel="stylesheet">
    <style>
        body { background:#f6f7f9; }
        .page-title { font-weight:700; }
        .card { border:0; box-shadow:0 1px 8px rgba(0,0,0,.06); }
        .status-success { color:#198754; font-weight:700; }
        .status-error { color:#dc3545; font-weight:700; }
        .status-skipped { color:#6c757d; font-weight:700; }
        table { font-size:14px; }
    </style>
</head>
<body>

<nav class="navbar navbar-expand-lg bg-white border-bottom">
    <div class="container-fluid px-4">
        <span class="navbar-brand fw-bold">D365 Import Monitor</span>
        <div>
            <a href="?logout=1" class="btn btn-outline-dark btn-sm">Logout</a>
        </div>
    </div>
</nav>

<div class="container-fluid px-4 py-4">

    <div class="d-flex justify-content-between align-items-center mb-4">
        <div>
            <h3 class="page-title mb-1">Import Health Dashboard</h3>
            <div class="text-muted small">Auto refresh every 60 seconds</div>
        </div>
        <div class="text-end">
            <div class="small text-muted">Latest Status</div>
            <div class="<?= ($lastImport['status'] ?? '') === 'SUCCESS' ? 'status-success' : 'status-error' ?>">
                <?= htmlspecialchars($lastImport['status'] ?? 'NO DATA') ?>
            </div>
        </div>
    </div>

    <div class="row g-3 mb-4">
        <div class="col-md-3">
            <div class="card p-3">
                <div class="text-muted small">Last Import Time</div>
                <h5><?= htmlspecialchars($lastImport['imported_at'] ?? '-') ?></h5>
            </div>
        </div>
        <div class="col-md-3">
            <div class="card p-3">
                <div class="text-muted small">Latest File</div>
                <h6><?= htmlspecialchars($lastImport['source_file_name'] ?? '-') ?></h6>
            </div>
        </div>
        <div class="col-md-2">
            <div class="card p-3">
                <div class="text-muted small">Import Today</div>
                <h5><?= number_format($todaySummary['total_import'] ?? 0) ?></h5>
            </div>
        </div>
        <div class="col-md-2">
            <div class="card p-3">
                <div class="text-muted small">Success</div>
                <h5 class="status-success"><?= number_format($todaySummary['success_import'] ?? 0) ?></h5>
            </div>
        </div>
        <div class="col-md-2">
            <div class="card p-3">
                <div class="text-muted small">Error</div>
                <h5 class="status-error"><?= number_format($todaySummary['error_import'] ?? 0) ?></h5>
            </div>
        </div>
    </div>

    <?php if ($oldestImportError): ?>
        <div class="alert alert-danger">
            Oldest import error: <?= htmlspecialchars($oldestImportError['file_name']) ?>
            <?= htmlspecialchars($oldestImportError['last_error'] ?? '') ?>
        </div>
    <?php endif; ?>

    <div class="card p-3 mb-4">
        <h6 class="mb-3">SharePoint Queue</h6>
        <div class="d-flex flex-wrap gap-2 mb-3">
            <?php foreach ($queueStatusCounts as $row): ?>
                <span class="badge text-bg-secondary">
                    <?= htmlspecialchars($row['status']) ?>: <?= number_format($row['total']) ?>
                </span>
            <?php endforeach; ?>
            <?php if (!$queueStatusCounts): ?>
                <span class="text-muted small">No queue files</span>
            <?php endif; ?>
        </div>
        <div class="table-responsive">
            <table class="table table-hover table-sm align-middle mb-0">
                <thead>
                <tr>
                    <th>File</th>
                    <th>Status</th>
                    <th class="text-end">Attempts</th>
                    <th>Last Error</th>
                    <th>Downloaded</th>
                    <th>Moved</th>
                    <th>Imported</th>
                    <th>Updated</th>
                </tr>
                </thead>
                <tbody>
                <?php foreach ($queueLatestFiles as $row): ?>
                    <tr>
                        <td><?= htmlspecialchars($row['file_name']) ?></td>
                        <td><?= htmlspecialchars($row['status']) ?></td>
                        <td class="text-end"><?= number_format($row['attempt_count']) ?></td>
                        <td><?= htmlspecialchars($row['last_error'] ?? '-') ?></td>
                        <td><?= htmlspecialchars($row['downloaded_at'] ?? '-') ?></td>
                        <td><?= htmlspecialchars($row['moved_at'] ?? '-') ?></td>
                        <td><?= htmlspecialchars($row['imported_at'] ?? '-') ?></td>
                        <td><?= htmlspecialchars($row['updated_at'] ?? '-') ?></td>
                    </tr>
                <?php endforeach; ?>
                <?php if (!$queueLatestFiles): ?>
                    <tr><td colspan="8" class="text-muted text-center">No queue files</td></tr>
                <?php endif; ?>
                </tbody>
            </table>
        </div>
    </div>

    <div class="row g-3 mb-4">
        <div class="col-lg-5">
            <div class="card p-3">
                <h6 class="mb-3">Workflow Summary</h6>
                <table class="table table-sm align-middle">
                    <thead>
                    <tr>
                        <th>Status</th>
                        <th class="text-end">Items</th>
                        <th class="text-end">Total Amount</th>
                    </tr>
                    </thead>
                    <tbody>
                    <?php foreach ($workflowSummary as $row): ?>
                        <tr>
                            <td><?= htmlspecialchars($row['workflow_approval_status'] ?? '-') ?></td>
                            <td class="text-end"><?= number_format($row['total_items']) ?></td>
                            <td class="text-end"><?= number_format($row['total_amount'], 2) ?></td>
                        </tr>
                    <?php endforeach; ?>
                    </tbody>
                </table>
            </div>
        </div>

        <div class="col-lg-7">
            <div class="card p-3">
                <h6 class="mb-3">Last Import Message</h6>
                <div class="border rounded p-3 bg-light">
                    <?= htmlspecialchars($lastImport['message'] ?? '-') ?>
                </div>
                <div class="small text-muted mt-2">
                    File hash: <?= htmlspecialchars($lastImport['file_hash'] ?? '-') ?>
                </div>
            </div>
        </div>
    </div>

    <div class="card p-3 mb-4">
        <h6 class="mb-3">Import History</h6>
        <div class="table-responsive">
            <table class="table table-hover table-sm align-middle">
                <thead>
                <tr>
                    <th>Import Time</th>
                    <th>File</th>
                    <th>Status</th>
                    <th class="text-end">Rows</th>
                    <th>Message</th>
                </tr>
                </thead>
                <tbody>
                <?php foreach ($importHistory as $row): ?>
                    <tr>
                        <td><?= htmlspecialchars($row['imported_at']) ?></td>
                        <td><?= htmlspecialchars($row['source_file_name']) ?></td>
                        <td>
                            <span class="<?= $row['status'] === 'SUCCESS' ? 'status-success' : 'status-error' ?>">
                                <?= htmlspecialchars($row['status']) ?>
                            </span>
                        </td>
                        <td class="text-end"><?= number_format($row['total_rows']) ?></td>
                        <td><?= htmlspecialchars($row['message']) ?></td>
                    </tr>
                <?php endforeach; ?>
                </tbody>
            </table>
        </div>
    </div>

    <div class="row g-3">
        <div class="col-lg-7">
            <div class="card p-3">
                <h6 class="mb-3">Changed Records Today</h6>
                <div class="table-responsive">
                    <table class="table table-sm align-middle">
                        <thead>
                        <tr>
                            <th>Changed At</th>
                            <th>Action</th>
                            <th>Payment ID</th>
                            <th>File</th>
                        </tr>
                        </thead>
                        <tbody>
                        <?php foreach ($changedToday as $row): ?>
                            <tr>
                                <td><?= htmlspecialchars($row['changed_at']) ?></td>
                                <td><?= htmlspecialchars($row['action_type']) ?></td>
                                <td><?= htmlspecialchars($row['payment_id']) ?></td>
                                <td><?= htmlspecialchars($row['source_file_name']) ?></td>
                            </tr>
                        <?php endforeach; ?>

                        <?php if (!$changedToday): ?>
                            <tr>
                                <td colspan="4" class="text-muted text-center">No changed records today</td>
                            </tr>
                        <?php endif; ?>
                        </tbody>
                    </table>
                </div>
            </div>
        </div>

        <div class="col-lg-5">
            <div class="card p-3">
                <h6 class="mb-3">Duplicate Voucher Monitor</h6>
                <div class="table-responsive">
                    <table class="table table-sm align-middle">
                        <thead>
                        <tr>
                            <th>Voucher Number</th>
                            <th class="text-end">Count</th>
                        </tr>
                        </thead>
                        <tbody>
                        <?php foreach ($duplicateVoucher as $row): ?>
                            <tr>
                                <td><?= htmlspecialchars($row['voucher_number']) ?></td>
                                <td class="text-end"><?= number_format($row['duplicate_count']) ?></td>
                            </tr>
                        <?php endforeach; ?>

                        <?php if (!$duplicateVoucher): ?>
                            <tr>
                                <td colspan="2" class="text-muted text-center">No duplicate voucher</td>
                            </tr>
                        <?php endif; ?>
                        </tbody>
                    </table>
                </div>
            </div>
        </div>
    </div>

</div>
</body>
</html>
