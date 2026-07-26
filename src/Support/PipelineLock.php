<?php

namespace App\Support;

use RuntimeException;

final class PipelineLock
{
    public function __construct(private readonly string $lockFile)
    {
    }

    public function run(callable $callback): mixed
    {
        $dir = dirname($this->lockFile);
        if (!is_dir($dir)) {
            mkdir($dir, 0777, true);
        }

        $handle = fopen($this->lockFile, 'c');
        if ($handle === false) {
            throw new RuntimeException('Unable to open pipeline lock file');
        }

        if (!flock($handle, LOCK_EX | LOCK_NB)) {
            fclose($handle);
            throw new RuntimeException('Pipeline is already running');
        }

        try {
            fwrite($handle, (string) getmypid());
            $result = $callback();
            flock($handle, LOCK_UN);
            fclose($handle);
            unlink($this->lockFile);

            return $result;
        } catch (\Throwable $e) {
            flock($handle, LOCK_UN);
            fclose($handle);
            if (is_file($this->lockFile)) {
                unlink($this->lockFile);
            }
            throw $e;
        }
    }
}
