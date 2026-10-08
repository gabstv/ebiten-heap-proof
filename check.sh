#!/bin/sh
# Checks a report written by run.sh and prints a Markdown summary.
# EXPECTED_GRAPHICS is the graphics library every build must use (Metal by default).
# It fails if a build did not use the expected graphics library, if two builds rendered a different image for the same frame,
# if a patched build allocated per frame, or if an official build did not (which would mean the measurement is broken).
set -e
report=${1:-app/out/report.txt}
expected=${EXPECTED_GRAPHICS:-Metal}

awk -v expected="$expected" '
/ graphics=/ {
	split($2, g, "=")
	graphics[$1] = 1
	if (g[2] != expected) { printf "FAIL: %s used %s, not %s\n", $1, g[2], expected; bad = 1 }
}
/ sha256=/ {
	frame = $3; sha = $NF
	if (frame in hash && hash[frame] != sha) { printf "FAIL: %s rendered a different image for frame %s\n", $1, frame; bad = 1 }
	hash[frame] = sha
}
/ allocs\/frame=/ {
	for (i = 1; i <= NF; i++) {
		if ($i ~ /^allocs=/) { split($i, a, "="); allocs = a[2] }
		if ($i == "allocs/frame=") perframe = $(i+1)
		if ($i ~ /^GCs=/) { split($i, c, "="); gcs = c[2] }
		if ($i ~ /^frames=/) { split($i, f, "="); frames = f[2] }
	}
	if (!($1 in graphics)) { printf "FAIL: %s did not report its graphics library\n", $1; bad = 1 }
	if ($1 ~ /^pat/) npatched++; else nofficial++
	patched = ($1 ~ /^pat/)
	if (patched && perframe + 0 >= 1) { printf "FAIL: %s allocated %s times per frame\n", $1, perframe; bad = 1 }
	if (!patched && perframe + 0 < 1) { printf "FAIL: %s allocated %s times per frame; the official build should allocate, so the measurement looks wrong\n", $1, perframe; bad = 1 }
	rows = rows sprintf("| %s | %s | %s | %s | %s |\n", $1, frames, allocs, perframe, gcs)
}
END {
	if (npatched == 0 || nofficial == 0) { print "FAIL: the report has no results for official and patched builds"; bad = 1 }
	print "| build | frames | allocations in the whole run | per frame | GCs |"
	print "|---|---:|---:|---:|---:|"
	printf "%s", rows
	if (bad) exit 1
	print ""
	print "All checks passed: every build used " expected ", rendered the same frames, and the patched builds did not allocate per frame."
}' "$report"
