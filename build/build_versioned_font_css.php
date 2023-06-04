<?php

echo "Building versioned font CSS...\n";

## Paths

$static_root = __DIR__ . "/..";
$css_dir = "{$static_root}/css";

## Files

$font_files = [
	'fonts',
	'initial-fonts'
];

## Action

foreach ($font_files as $file) {
	$font_css = file_get_contents("{$css_dir}/{$file}-GENERATED.css");

	$versioned_font_css = preg_replace_callback('/\'\/static\/(.+?)\'/i', 'VersionAssetURL', $font_css);

	file_put_contents("{$css_dir}/{$file}-VERSIONED.css", $versioned_font_css);
}

## FUNCTIONS

function VersionAssetURL($m) {
	global $static_root;

	$file_path = "{$static_root}/{$m[1]}";
	$file_mod_time = filemtime($file_path);

	return "'/static/{$m[1]}?v={$file_mod_time}'";
}

?>
