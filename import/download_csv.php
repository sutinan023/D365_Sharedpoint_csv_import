<?php

require __DIR__ . '/../vendor/autoload.php';

use Dotenv\Dotenv;

$dotenv = Dotenv::createImmutable(__DIR__ . '/../config');
$dotenv->load();

function graphToken()
{
    $url =
        "https://login.microsoftonline.com/" .
        $_ENV['TENANT_ID'] .
        "/oauth2/v2.0/token";

    $post = [
        'client_id' => $_ENV['CLIENT_ID'],
        'client_secret' => $_ENV['CLIENT_SECRET'],
        'scope' => 'https://graph.microsoft.com/.default',
        'grant_type' => 'client_credentials'
    ];

    $ch = curl_init($url);

    curl_setopt_array($ch, [
        CURLOPT_RETURNTRANSFER => true,
        CURLOPT_POST => true,
        CURLOPT_POSTFIELDS => http_build_query($post),
    ]);

    $response = curl_exec($ch);

    if (curl_errno($ch)) {
        die("TOKEN CURL ERROR: " . curl_error($ch));
    }

    curl_close($ch);

    $json = json_decode($response, true);

    if (!isset($json['access_token'])) {

        echo "TOKEN RESPONSE:\n";
        print_r($json);

        die("TOKEN ERROR\n");
    }

    return $json['access_token'];
}

function graphGet($url, $token)
{
    $ch = curl_init($url);

    curl_setopt_array($ch, [
        CURLOPT_RETURNTRANSFER => true,
        CURLOPT_HTTPHEADER => [
            "Authorization: Bearer $token"
        ]
    ]);

    $response = curl_exec($ch);

    if (curl_errno($ch)) {
        die("GRAPH CURL ERROR: " . curl_error($ch));
    }

    curl_close($ch);

    return json_decode($response, true);
}

echo "=========================\n";
echo "START DOWNLOAD CSV\n";
echo "=========================\n";

$token = graphToken();

echo "TOKEN OK\n";

$siteUrl =
    "https://graph.microsoft.com/v1.0/sites/" .
    $_ENV['SITE_HOST'] .
    ":" .
    $_ENV['SITE_PATH'];

$site = graphGet($siteUrl, $token);

if (!isset($site['id'])) {

    echo "SITE RESPONSE:\n";
    print_r($site);

    die("SITE ID NOT FOUND\n");
}

$siteId = $site['id'];

echo "SITE ID: $siteId\n";

$drives = graphGet(
    "https://graph.microsoft.com/v1.0/sites/$siteId/drives",
    $token
);

if (!isset($drives['value'])) {

    echo "DRIVE RESPONSE:\n";
    print_r($drives);

    die("DRIVE ERROR\n");
}

$driveId = null;

foreach ($drives['value'] as $drive) {

    if ($drive['name'] === $_ENV['LIBRARY']) {

        $driveId = $drive['id'];
        break;
    }
}

if (!$driveId) {

    echo "AVAILABLE DRIVES:\n";

    foreach ($drives['value'] as $d) {
        echo "- " . $d['name'] . "\n";
    }

    die("DRIVE NOT FOUND\n");
}

echo "DRIVE ID: $driveId\n";

$folder = $_ENV['CSV_FOLDER'];

$items = graphGet(
    "https://graph.microsoft.com/v1.0/drives/$driveId/root:/$folder:/children",
    $token
);

if (!isset($items['value'])) {

    echo "FOLDER RESPONSE:\n";
    print_r($items);

    die("FOLDER ERROR\n");
}

if (empty($items['value'])) {
    die("NO FILES FOUND\n");
}

$csvFiles = array_filter($items['value'], function ($item) {

    return isset($item['name']) &&
        strtolower(pathinfo($item['name'], PATHINFO_EXTENSION)) === 'csv';
});

if (empty($csvFiles)) {
    die("NO CSV FILE FOUND\n");
}

usort($csvFiles, function ($a, $b) {

    return strtotime($b['lastModifiedDateTime'])
        - strtotime($a['lastModifiedDateTime']);
});

$file = $csvFiles[0];

$fileName = $file['name'];

echo "LATEST FILE: $fileName\n";

$downloadUrl =
    "https://graph.microsoft.com/v1.0/drives/$driveId/items/" .
    $file['id'] .
    "/content";

$downloadDir = __DIR__ . '/../download';

if (!is_dir($downloadDir)) {
    mkdir($downloadDir, 0777, true);
}

$savePath =
    $downloadDir .
    '/' .
    $fileName;

$fp = fopen($savePath, 'w');

$ch = curl_init($downloadUrl);

curl_setopt_array($ch, [
    CURLOPT_HTTPHEADER => [
        "Authorization: Bearer $token"
    ],
    CURLOPT_FILE => $fp,
    CURLOPT_FOLLOWLOCATION => true
]);

curl_exec($ch);

if (curl_errno($ch)) {

    fclose($fp);

    die("DOWNLOAD ERROR: " . curl_error($ch));
}

curl_close($ch);

fclose($fp);

if (!file_exists($savePath)) {
    die("SAVE FILE FAILED\n");
}

echo "DOWNLOAD SUCCESS\n";
echo "SAVE PATH: $savePath\n";

echo "=========================\n";
echo "FINISH DOWNLOAD CSV\n";
echo "=========================\n";