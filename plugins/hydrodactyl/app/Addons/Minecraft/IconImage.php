<?php

namespace Pterodactyl\Addons\Minecraft;

use Symfony\Component\HttpKernel\Exception\HttpException;

/**
 * server-icon.png helpers. Minecraft only accepts a 64x64 PNG, so uploads
 * are decoded and re-encoded with GD (which also strips anything that is not
 * an image).
 */
class IconImage
{
    public static function fromDataUri(string $uri): string
    {
        if (!preg_match('#^data:image/(png|jpe?g|gif|webp);base64,([A-Za-z0-9+/=\s]+)$#', $uri, $m)) {
            throw new HttpException(422, 'Upload a PNG, JPEG, GIF or WebP image.');
        }

        $source = @imagecreatefromstring((string) base64_decode($m[2], true));
        if ($source === false) {
            throw new HttpException(422, 'That file could not be read as an image.');
        }

        $icon = imagecreatetruecolor(64, 64);
        imagealphablending($icon, false);
        imagesavealpha($icon, true);
        imagefill($icon, 0, 0, imagecolorallocatealpha($icon, 0, 0, 0, 127));

        // Center-crop to a square, then scale.
        $w = imagesx($source);
        $h = imagesy($source);
        $side = min($w, $h);
        imagecopyresampled($icon, $source, 0, 0, intdiv($w - $side, 2), intdiv($h - $side, 2), 64, 64, $side, $side);

        return self::encode($icon);
    }

    /**
     * Up to four characters on a solid background, drawn with GD's built-in
     * bitmap font at 32x32 and scaled 2x for a blocky, Minecraft-ish look.
     */
    public static function generate(string $text, string $background, string $color): string
    {
        $small = imagecreatetruecolor(32, 32);
        [$br, $bg, $bb] = sscanf($background, '#%02x%02x%02x');
        [$fr, $fg, $fb] = sscanf($color, '#%02x%02x%02x');
        imagefill($small, 0, 0, imagecolorallocate($small, $br, $bg, $bb));

        // Built-in fonts are ASCII only; font 5 is 9px wide, font 3 is 7px.
        $text = strtoupper(substr(preg_replace('/[^\x20-\x7e]/', '', $text) ?: '?', 0, 4));
        $font = strlen($text) <= 3 ? 5 : 3;
        $x = intdiv(32 - imagefontwidth($font) * strlen($text), 2);
        $y = intdiv(32 - imagefontheight($font), 2);
        imagestring($small, $font, max(0, $x), max(0, $y), $text, imagecolorallocate($small, $fr, $fg, $fb));

        $icon = imagecreatetruecolor(64, 64);
        imagecopyresized($icon, $small, 0, 0, 0, 0, 64, 64, 32, 32);

        return self::encode($icon);
    }

    private static function encode(\GdImage $image): string
    {
        ob_start();
        imagepng($image, null, 9);

        return (string) ob_get_clean();
    }
}
