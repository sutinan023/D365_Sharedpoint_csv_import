<?php

namespace App\Config;

final class EnvironmentBanner
{
    public static function inject(string $html, string $appEnv, string $release): string
    {
        if (strtoupper($appEnv) !== 'UAT' || stripos($html, '<body') === false) {
            return $html;
        }

        $safeRelease = htmlspecialchars($release, ENT_QUOTES, 'UTF-8');
        $banner = '<div role="status" style="position:sticky;top:0;z-index:2147483647;'
            . 'background:#b42318;color:#fff;text-align:center;font:700 14px/32px Arial,sans-serif;'
            . 'letter-spacing:.08em">UAT &mdash; NOT PRODUCTION'
            . ' &middot; RELEASE ' . $safeRelease . '</div>';

        return preg_replace('/(<body\\b[^>]*>)/i', '$1' . $banner, $html, 1) ?? $html;
    }
}
