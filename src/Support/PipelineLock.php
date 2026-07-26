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
            ftruncate($handle, 0);
            rewind($handle);
            fwrite($handle, (string) getmypid());

            return $callback();
        } finally {
            flock($handle, LOCK_UN);
            fclose($handle);
        }
    }
}
