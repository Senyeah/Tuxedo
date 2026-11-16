/* SPDX-License-Identifier: GPL-2.0-or-later */
#ifndef TUXVM_ADDITIONS_H
#define TUXVM_ADDITIONS_H

#include <stddef.h>

/* Tuxedo Additions: the media (a reserved Read-only folder in tux-files), the job the app gives the guest's agent,
   and the events the agent sends back. The contract is docs/guest-additions-design.md, sections 5 and 7.
   Any thread may call these. Nothing here runs what it reads: a job and an event are JSON the host stores. */

#define HV_ADDITIONS_NAME "tux-additions"
#define HV_ADDITIONS_JOB_MAX (16 * 1024)
#define HV_ADDITIONS_EVENT_MAX (64 * 1024)
#define HV_ADDITIONS_EVENTS_KEPT 512
#define HV_ADDITIONS_EVENTS_BYTES (512 * 1024)

/* Inserts the media: dir becomes the Read-only entry tux-additions. Each call adds one to n, so the guest starts
   its agent again. Returns n (> 0), or -1 with errno (what the open of dir gave). */
int hv_additions_insert(const char *dir);
/* Takes the media out. A stored job is wiped (it may hold a password). The events, the taken id and the cancel stay
   until hv_additions_reset. 0. */
int hv_additions_eject(void);
/* Adds one to n with the media in place (the guest runs its launcher again). Returns n, or -1 (ENODEV) when the
   media is not in. */
int hv_additions_nudge(void);
/* The number of the last insert or nudge; 0 when the media is not in. */
int hv_additions_inserted(void);

/* The job for the agent: one JSON object, at most HV_ADDITIONS_JOB_MAX bytes, valid UTF-8, with a top-level string
   member "id" of 1 to 64 characters of A-Za-z0-9_-. It replaces the stored job (the old bytes are wiped); it does not
   touch the taken id or a cancel for another id. A cancel for the same id is dropped: a job set again is a new wish.
   0, or -1 with errno (EINVAL: not one valid JSON object, or no valid id; E2BIG). The caller wipes its own copy
   (hv_additions_wipe). */
int hv_additions_job_set(const char *json);
/* Cancels the job the app set last: cancel_job becomes the id of the stored job, else of the taken job (with
   neither, nothing changes). A stored job is wiped (the agent has not taken it); a taken job runs on until the
   agent sees cancel_job and stops. cancel_job stays until hv_additions_job_clear or reset, and a job with another id
   is not cancelled by it. */
int hv_additions_job_cancel(void);
/* Forgets everything about jobs: the stored job (bytes overwritten with zero), the taken id and cancel_job. */
void hv_additions_job_clear(void);

/* An event from the guest (POST /.tux/additions): one JSON object with a string member "t", at most
   HV_ADDITIONS_EVENT_MAX bytes. 0, or -1 with errno (EINVAL, E2BIG). Every accepted event is kept for the app. Two
   types also change the job, each by its string member "job" and only when it names a known id:
   "ack" with the stored job's id: the stored bytes are wiped and the id is remembered as taken;
   "done" with the stored job's id: the stored bytes are wiped; with the taken id: the taken id is forgotten.
   Any other id (a stale or forged event), or none, changes nothing. */
int hv_additions_post(const char *body, size_t len);

/* For GET /.tux/additions: {"inserted":B,"n":N,"cancel":B,"cancel_job":"id"|null,"job":OBJECT|null,"taken":"id"|null},
   malloc'd. cancel is true when cancel_job is not null; job is the stored job (null once taken); taken is the id of
   the job the agent acked. *seq (may be NULL) is the news count it belongs to. The caller wipes it with
   hv_additions_wipe before free: it may hold a password. */
char *hv_additions_guest_json(unsigned long *seq);
/* For the app: {"inserted":B,"n":N,"seq":S,"gap":B,"events":[{"k":K,"e":OBJECT},...]} with each event whose k is
   greater than since, malloc'd. *seq (may be NULL) gets S. since is a k, not a count: the app keeps the last k it
   has seen for this call and S for hv_additions_wait. k starts at 1 and does not restart in a new machine, so a
   since from an older machine still works. gap is true when events after since were dropped for the limits, and when
   since is greater than any k (an older process): the call then returns every kept event. */
char *hv_additions_events_json(unsigned long since, unsigned long *seq);
/* Waits up to ms for the count to pass since (a change of media, a job, a cancel, an event). Returns the count. A
   since that is not the count of this process returns at once. */
unsigned long hv_additions_wait(unsigned long since, int ms);

/* A new machine: no media, no job (stored, taken or cancelled), no events. Also clears the reserved folder entry. hv_vm_create does this; a
   session view that opens later does not, so it sees the events the guest sent before it looked. */
void hv_additions_reset(void);

/* A JSON text is one object (RFC 8259 syntax, depth at most 8, no trailing bytes, valid UTF-8). The server uses
   this for jobs and events; it is here so tests and the app's bridge can use it too. Returns 1 when it is, else 0.
   Depth counts the object and array levels: the top object is 1. Spaces, tabs and line ends may follow the object.
   An escape for half of a UTF-16 pair is refused. */
int hv_json_object_valid(const char *s, size_t len);

/* Added by the engine part (small things the contract did not name). */
/* The count now (what hv_additions_wait compares), for the answer to a POST. */
unsigned long hv_additions_seq(void);
/* Overwrites n bytes with zero in a way the compiler keeps. */
void hv_additions_wipe(void *p, size_t n);
/* Called on the thread of each accepted event, with no lock held. json is one line and ends at len. NULL: none. */
typedef void (*HvAdditionsHook)(unsigned long k, const char *json, size_t len, void *user);
void hv_additions_set_hook(HvAdditionsHook hook, void *user);
/* For tests: the host's own job buffer (HV_ADDITIONS_JOB_MAX + 1 bytes), to see that it is zero after a wipe. */
const char *hv_additions_test_job_buffer(size_t *size);

#endif
