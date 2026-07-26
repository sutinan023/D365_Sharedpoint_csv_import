<?php

use App\Support\PipelineLock;

return [
    'pipeline lock runs callback once and retains a stable lock file' => function (): void {
        $lockFile = sys_get_temp_dir() . DIRECTORY_SEPARATOR . 'pipeline_lock_' . uniqid('', true) . '.lock';
        $lock = new PipelineLock($lockFile);
        $ran = false;

        $result = $lock->run(function () use (&$ran): string {
            $ran = true;
            return 'done';
        });

        assert($result === 'done');
        assert($ran === true);
        assert(is_file($lockFile));
    },
    'pipeline lock rejects a second instance while the first callback is running' => function (): void {
        $lockFile = sys_get_temp_dir() . DIRECTORY_SEPARATOR . 'pipeline_lock_' . uniqid('', true) . '.lock';
        $firstLock = new PipelineLock($lockFile);
        $secondLock = new PipelineLock($lockFile);

        $firstLock->run(function () use ($secondLock): void {
            try {
                $secondLock->run(static fn (): null => null);
                assert(false, 'Expected the second lock instance to be rejected');
            } catch (RuntimeException $e) {
                assert($e->getMessage() === 'Pipeline is already running');
            }
        });
    },
    'pipeline lock releases after a callback throws' => function (): void {
        $lockFile = sys_get_temp_dir() . DIRECTORY_SEPARATOR . 'pipeline_lock_' . uniqid('', true) . '.lock';
        $firstLock = new PipelineLock($lockFile);
        $secondLock = new PipelineLock($lockFile);

        try {
            $firstLock->run(static function (): never {
                throw new RuntimeException('callback failed');
            });
            assert(false, 'Expected the callback exception to be rethrown');
        } catch (RuntimeException $e) {
            assert($e->getMessage() === 'callback failed');
        }

        assert($secondLock->run(static fn (): string => 'acquired') === 'acquired');
    },
];
