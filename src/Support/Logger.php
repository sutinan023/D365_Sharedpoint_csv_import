<?php

namespace App\Support;

final class Logger
{
    public function __construct(private readonly string $logFile)
    {
        $dir = dirname($this->logFile);
        if (!is_dir($dir)) {
            mkdir($dir, 0777, true);
        }
    }

    public function info(string $message): void
    {
        $this->write('INFO', $message);
    }

    public function error(string $message): void
    {
        $this->write('ERROR', $message);
    }

    private function write(string $level, string $message): void
    {
        $line = sprintf("[%s] %s %s\n", date('Y-m-d H:i:s'), $level, self::sanitize($message));
        file_put_contents($this->logFile, $line, FILE_APPEND);
    }

    public static function sanitize(string $message): string
    {
        $message = preg_replace(
            '/"(CLIENT_SECRET|DB_PASS(?:WORD)?|ADMIN_PASSWORD|PASSWORD|ACCESS[_-]?TOKEN|TOKEN)"\\s*:\\s*(?:"[^"]*"|\'[^\']*\'|[^\\s,;}]+)/i',
            '"$1":"[masked]"',
            $message,
        );
        $message = preg_replace(
            '/\\b(CLIENT_SECRET|DB_PASS(?:WORD)?|ADMIN_PASSWORD|PASSWORD|ACCESS[_-]?TOKEN|TOKEN)\\s*=\\s*(?:"[^"]*"|\'[^\']*\'|[^\\s,;]+)/i',
            '$1=[masked]',
            $message,
        );
        $message = preg_replace('/Authorization\\s*:\\s*Bearer\\s+[^\\s,;]+/i', 'Authorization: Bearer [masked]', $message);
        $message = preg_replace('/https:\\/\\/[^\\s]*sharepoint\\.com\\/\\S+/i', 'https://contoso.sharepoint.com/[masked-url]', $message);

        return $message;
    }
}
