#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
# Fails if a diff changes a line of a non-.md file that is not a comment (rename Stage 3 check).
# Usage: tools/check-comment-only.sh [git diff args]   (default: unstaged and staged changes against HEAD)
git diff -U0 "${@:-HEAD}" -- . ':!*.md' ':!tools/rename.py' | awk '
  /^\+\+\+|^---/ {next}
  /^[+-]/ { l=substr($0,2); if (l !~ /^[ \t]*(\/\/|#|\*|\/\*|--|;)/) { print FILENAME ": " $0; bad=1 } }
  END { exit bad }'
