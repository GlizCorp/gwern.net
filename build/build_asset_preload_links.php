<?php

echo "Building asset preload links...\n";

$static_root = __DIR__ . "/..";

$inlined_head_file_path = "{$static_root}/include/inlined-head.html";
$inlined_foot_file_path = "{$static_root}/include/inlined-foot.html";

$replaced_asset_link_patterns = [
	'/(?:<noscript>)?(<(?:link|script) .*? ?(?:href|src)="(\/static\/(?:css|js)\/.+?)".*?>)(?:<\/noscript>)?/'
];

## If the SSI includes aren’t already built, build them.
if (!file_exists($inlined_head_file_path))
	require_once("{$static_root}/build/build_head_includes.php");
if (!file_exists($inlined_foot_file_path))
	require_once("{$static_root}/build/build_versioned_includes.php");

## Store versioned asset pathnames, to build preload links later.
$versioned_asset_pathnames = [ ];

## Wrap specified assets in <noscript> tags.
file_put_contents($inlined_foot_file_path, 
 				  preg_replace_callback($replaced_asset_link_patterns, 
				  						function ($m) {
											global $versioned_asset_pathnames;
											$versioned_asset_pathnames[] = $m[2];

											return (str_contains($m[2], ".css")
													? "<noscript>{$m[1]}</noscript>"
													: $m[1]);
										}, 
										file_get_contents($inlined_foot_file_path)));

## Append preload links to <head> includes file.
file_put_contents($inlined_head_file_path,
				  trim(preg_replace('/<link rel="preload" .+? as=".+?" .+?>\n/', '', file_get_contents($inlined_head_file_path)))
				  . "\n"
				  . implode("\n", array_map(function ($pathname) {
				  		$as = str_contains($pathname, ".css") ? "style" : "script";
				  		$onload = str_contains($pathname, ".css")
				  				  ? "this.onload = null; this.rel = 'stylesheet'"
				  				  : "";
				  		return "<link rel=\"preload\" href=\"{$pathname}\" as=\"{$as}\" onload=\"{$onload}\">";
				  	}, $versioned_asset_pathnames))
				  . "\n");

?>
