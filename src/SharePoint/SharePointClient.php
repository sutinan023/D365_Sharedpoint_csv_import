<?php

namespace App\SharePoint;

use RuntimeException;

final class SharePointClient
{
    private $http;

    public function __construct(private readonly array $env, ?callable $http = null)
    {
        $this->http = $http ?? [$this, 'curlRequest'];
    }

    public static function fromEnv(array $env, ?callable $http = null): self
    {
        $client = new self($env, $http);
        $token = $client->requestAccessToken(
            $env['TENANT_ID'] ?? '',
            $env['CLIENT_ID'] ?? '',
            $env['CLIENT_SECRET'] ?? ''
        );
        $siteId = $client->resolveSiteId($env['SITE_HOST'] ?? '', $env['SITE_PATH'] ?? '', $token);
        $driveId = $client->resolveDriveId($siteId, $env['LIBRARY'] ?? '', $token);

        return new self(array_merge($env, [
            'ACCESS_TOKEN' => $token,
            'SITE_ID' => $siteId,
            'DRIVE_ID' => $driveId,
        ]), $http);
    }

    public function listCsvFiles(string $folderPath): array
    {
        $driveId = $this->env['DRIVE_ID'] ?? null;
        if ($driveId === null) {
            throw new RuntimeException('DRIVE_ID is required');
        }

        $encoded = implode('/', array_map('rawurlencode', explode('/', trim($folderPath, '/'))));
        $url = "https://graph.microsoft.com/v1.0/drives/{$driveId}/root:/{$encoded}:/children";
        $files = [];

        while ($url !== null) {
            [$status, , $body] = ($this->http)('GET', $url, $this->headers());
            if ($status < 200 || $status >= 300) {
                throw new RuntimeException("Graph list children failed with HTTP {$status}");
            }

            $json = json_decode($body, true, flags: JSON_THROW_ON_ERROR);
            foreach ($json['value'] ?? [] as $item) {
                $isFile = array_key_exists('file', $item);
                $isCsv = strcasecmp(pathinfo($item['name'] ?? '', PATHINFO_EXTENSION), 'csv') === 0;
                if ($isFile && $isCsv) {
                    $item['drive_id'] = $driveId;
                    $files[] = $item;
                }
            }
            $url = $json['@odata.nextLink'] ?? null;
        }

        return $files;
    }

    public function resolveFolderItemId(string $folderPath): string
    {
        $driveId = $this->env['DRIVE_ID'] ?? null;
        $encoded = implode('/', array_map('rawurlencode', explode('/', trim($folderPath, '/'))));
        $url = "https://graph.microsoft.com/v1.0/drives/{$driveId}/root:/{$encoded}";
        [$status, , $body] = ($this->http)('GET', $url, $this->headers());
        if ($status < 200 || $status >= 300) {
            throw new RuntimeException("Graph resolve folder failed with HTTP {$status}");
        }

        $json = json_decode($body, true, flags: JSON_THROW_ON_ERROR);
        return $json['id'];
    }

    public function downloadItem(string $driveId, string $itemId, string $targetPath): void
    {
        $url = "https://graph.microsoft.com/v1.0/drives/{$driveId}/items/{$itemId}/content";
        [$status, , $body] = ($this->http)('GET', $url, $this->headers());
        if ($status < 200 || $status >= 300) {
            throw new RuntimeException("Graph download failed with HTTP {$status}");
        }

        file_put_contents($targetPath, $body);
    }

    public function moveItem(string $driveId, string $itemId, string $processedFolderItemId): void
    {
        $url = "https://graph.microsoft.com/v1.0/drives/{$driveId}/items/{$itemId}";
        $body = json_encode(['parentReference' => ['id' => $processedFolderItemId]], JSON_THROW_ON_ERROR);
        [$status] = ($this->http)('PATCH', $url, array_merge($this->headers(), ['Content-Type: application/json']), $body);
        if ($status < 200 || $status >= 300) {
            throw new RuntimeException("Graph move failed with HTTP {$status}");
        }
    }

    private function headers(): array
    {
        $token = $this->env['ACCESS_TOKEN'] ?? '';
        return ['Authorization: Bearer ' . $token];
    }

    private function requestAccessToken(string $tenantId, string $clientId, string $clientSecret): string
    {
        if ($tenantId === '' || $clientId === '' || $clientSecret === '') {
            throw new RuntimeException('TENANT_ID, CLIENT_ID, and CLIENT_SECRET are required');
        }

        $url = "https://login.microsoftonline.com/{$tenantId}/oauth2/v2.0/token";
        $body = http_build_query([
            'client_id' => $clientId,
            'client_secret' => $clientSecret,
            'scope' => 'https://graph.microsoft.com/.default',
            'grant_type' => 'client_credentials',
        ]);

        [$status, , $response] = ($this->http)('POST', $url, ['Content-Type: application/x-www-form-urlencoded'], $body);
        if ($status < 200 || $status >= 300) {
            throw new RuntimeException("Graph token request failed with HTTP {$status}");
        }

        $json = json_decode($response, true, flags: JSON_THROW_ON_ERROR);
        return $json['access_token'];
    }

    private function resolveSiteId(string $siteHost, string $sitePath, string $token): string
    {
        if ($siteHost === '' || $sitePath === '') {
            throw new RuntimeException('SITE_HOST and SITE_PATH are required');
        }

        $url = 'https://graph.microsoft.com/v1.0/sites/' . rawurlencode($siteHost) . ':' . $sitePath;
        [$status, , $response] = ($this->http)('GET', $url, ['Authorization: Bearer ' . $token]);
        if ($status < 200 || $status >= 300) {
            throw new RuntimeException("Graph site resolve failed with HTTP {$status}");
        }

        $json = json_decode($response, true, flags: JSON_THROW_ON_ERROR);
        return $json['id'];
    }

    private function resolveDriveId(string $siteId, string $libraryName, string $token): string
    {
        if ($libraryName === '') {
            throw new RuntimeException('LIBRARY is required');
        }

        $url = "https://graph.microsoft.com/v1.0/sites/{$siteId}/drives";
        [$status, , $response] = ($this->http)('GET', $url, ['Authorization: Bearer ' . $token]);
        if ($status < 200 || $status >= 300) {
            throw new RuntimeException("Graph drive resolve failed with HTTP {$status}");
        }

        $json = json_decode($response, true, flags: JSON_THROW_ON_ERROR);
        foreach ($json['value'] ?? [] as $drive) {
            if (($drive['name'] ?? '') === $libraryName) {
                return $drive['id'];
            }
        }

        throw new RuntimeException("SharePoint library not found: {$libraryName}");
    }

    private function curlRequest(string $method, string $url, array $headers = [], ?string $body = null): array
    {
        $ch = curl_init($url);
        curl_setopt_array($ch, [
            CURLOPT_RETURNTRANSFER => true,
            CURLOPT_FOLLOWLOCATION => true,
            CURLOPT_CUSTOMREQUEST => $method,
            CURLOPT_HTTPHEADER => $headers,
        ]);
        if ($body !== null) {
            curl_setopt($ch, CURLOPT_POSTFIELDS, $body);
        }

        $responseBody = curl_exec($ch);
        if ($responseBody === false) {
            $error = curl_error($ch);
            curl_close($ch);
            throw new RuntimeException($error);
        }
        $status = (int) curl_getinfo($ch, CURLINFO_HTTP_CODE);
        curl_close($ch);

        return [$status, [], $responseBody];
    }
}
