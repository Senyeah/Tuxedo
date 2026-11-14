#ifndef TUXVM_SAFE_PATH_H
#define TUXVM_SAFE_PATH_H

#include <stddef.h>
#include <sys/stat.h>
#include <sys/types.h>

/* Paths below a shared folder's directory descriptor that nothing can take out of it: no symbolic link in any
   part (the last one too) is followed, and a part that is "." or ".." is refused. share.c uses these; so can a
   file server for picked folders (docs/files-mount-plan.md, FM2).

   A path is its parts with '/' between them: leading, trailing and repeated slashes are ignored, and no parts
   is the folder itself. Failures are -1 with errno: EINVAL for a bad part, ELOOP (or ENOTCAPABLE) for a link,
   else what the open gave. */

/* The folder's descriptor, which the other calls take as rootfd. */
int safe_root_open(const char *folder);

/* 1 for one usable path part: not empty, ".", "..", too long, and no '/'. */
int safe_name_ok(const char *name);

/* openat below rootfd. A link as the last part fails, as with O_NOFOLLOW. */
int safe_open(int rootfd, const char *path, int flags, mode_t mode);

/* The directory that holds the path's last part (a descriptor to close), and that part in leaf. The folder
   itself has no parent: EINVAL. */
int safe_parent(int rootfd, const char *path, char *leaf, size_t cap);

/* lstat below rootfd. */
int safe_stat(int rootfd, const char *path, struct stat *st);

/* 1 when the path is the folder itself. */
int safe_is_root(const char *path);

/* 1 when dir is the directory st, or below it, between it and rootfd; also 1 when that can't be told. */
int safe_below(int rootfd, int dir, const struct stat *st);

/* Removes name in dir and, for a directory, all in it. A link is removed, never followed. */
int safe_remove(int dir, const char *name);

/* Copies from in fromdir to to in todir, a directory with all in it. A link in it is copied as a link
   (a clone) or left out (a copy), never followed. */
int safe_copy(int fromdir, const char *from, int todir, const char *to);

/* 1 when opens use O_NOFOLLOW_ANY and O_RESOLVE_BENEATH, 0 when they walk the path a part at a time. */
int safe_path_beneath(void);

/* For tests: walk every path, and copy without clonefile. */
void safe_path_force(int walk, int no_clone);

#endif
