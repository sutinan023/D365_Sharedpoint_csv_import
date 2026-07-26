<?php

use App\Support\PipelineLock;

return [
    'pipeline lock runs callback once and releases file' => function (): void {
        $lockFile = sys_get_temp_dir() . DIRECTORY_SEPARATOR . 'pipeline_lock_' . uniqid('', true) . '.lock';
        $lock = new PipelineLock($lockFile);
        $ran = false;

        $result = $lock->run(function () use (&$ran): string {
            $ran = true;
            return 'done';
        });

        assert($result === 'done');
        assert($ran === true);
        assert(!is_file($lockFile));
    },
    'pipeline lock rejects an overlapping run' => function (): void {
        $lockFile = sys_get_temp_dir() . DIRECTORY_SEPARATOR . 'pipeline_lock_' . uniqid('', true) . '.lock';
        $lock = new PipelineLock($lockFile);

        $lock->run(function () use ($lockFile): void {
            $handle = fopen($lockFile, 'c');
            assert($handle !== false);
            assert(flock($handle, LOCK_EX | LOCK_NB) === false);
            fclose($handle);
        });
    },
];
