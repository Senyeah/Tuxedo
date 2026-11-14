# Source from a build script. Sets GFX_ROOT (the main checkout's build/gfx, also from a worktree) and
# TUX_GFX=1 when the iOS and simulator graphics libraries are there; empty otherwise.
GFX_ROOT="$(dirname "$(git rev-parse --path-format=absolute --git-common-dir)")/build/gfx"
TUX_GFX=
[ -f "$GFX_ROOT/ios/lib/libvirglrenderer.a" ] && [ -f "$GFX_ROOT/sim/lib/libvirglrenderer.a" ] && TUX_GFX=1
export GFX_ROOT TUX_GFX
