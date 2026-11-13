// Crafted guest input to the VideoToolbox back end (tools/gfx/virglrenderer-videotoolbox.patch), called directly
// through virgl_video.h. Linked without the video frameworks: the library must name them itself.
#include <mach/mach.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "vrend/virgl_video.h"
#include "virgl_video_hw.h"

static int checks, failures;
static void check(const char *what, long long got, long long want) {
    checks++;
    if (got != want) failures++;
    printf("%s %s (got %lld, want %lld)\n", got == want ? "ok  " : "FAIL", what, got, want);
}

static unsigned frames;
static void done(struct virgl_video_codec *c, const struct virgl_video_dma_buf *d) { (void)c, (void)d, frames++; }
static struct virgl_video_callbacks cbs = {.decode_completed = done};

static long long footprint_mb(int peak) {
    task_vm_info_data_t v;
    mach_msg_type_number_t n = TASK_VM_INFO_COUNT;
    if (task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&v, &n) != KERN_SUCCESS) return -1;
    return (long long)((peak ? v.ledger_phys_footprint_peak : v.phys_footprint) >> 20);
}

static struct virgl_video_codec *codec(enum pipe_video_profile p, uint32_t w, uint32_t h, struct virgl_video_buffer **t) {
    struct virgl_video_create_codec_args a = {.profile = p, .entrypoint = PIPE_VIDEO_ENTRYPOINT_BITSTREAM, .width = w, .height = h};
    struct virgl_video_create_buffer_args b = {.format = PIPE_FORMAT_NV12, .width = w, .height = h};
    *t = virgl_video_create_buffer(&b);
    return virgl_video_create_codec(&a);
}

// 64x4 tiles, each the whole 16 MiB access unit: without a bound on their sum the sample is 4 GiB
static void av1_overlap(void) {
    struct virgl_video_buffer *t;
    struct virgl_video_codec *c = codec(PIPE_VIDEO_PROFILE_AV1_MAIN, 4096, 2304, &t);
    union virgl_picture_desc *u = calloc(1, sizeof(*u));
    struct virgl_av1_picture_desc *d = &u->av1;
    __typeof__(d->picture_parameter) *p = &d->picture_parameter;
    d->base.profile = PIPE_VIDEO_PROFILE_AV1_MAIN;
    p->frame_width = p->max_width = 4096;
    p->frame_height = p->max_height = 2304;
    p->order_hint_bits_minus_1 = 6;
    p->pic_info_fields.show_frame = 1; // a shown key frame
    p->primary_ref_frame = 7;
    p->base_qindex = 100;
    p->tile_cols = 64, p->tile_rows = 4;
    for (unsigned i = 0; i <= 64; i++) p->tile_col_start_sb[i] = i;
    for (unsigned i = 0; i <= 4; i++) p->tile_row_start_sb[i] = i * 9;
    uint32_t len = 16u << 20;
    d->slice_parameter.slice_count = 256;
    for (unsigned i = 0; i < 256; i++) {
        d->slice_parameter.slice_data_row[i] = (uint16_t)(i / 64), d->slice_parameter.slice_data_col[i] = (uint16_t)(i % 64);
        d->slice_parameter.slice_data_size[i] = len;
    }
    uint8_t *bs = malloc(len);
    memset(bs, 0x5a, len);
    const void *bufs[] = {bs};
    unsigned sizes[] = {len};
    check("AV1: the codec is created", c != NULL, 1);
    check("AV1: begin_frame", virgl_video_begin_frame(c, t), 0);
    check("AV1: the tiles are taken", virgl_video_decode_bitstream(c, t, u, 1, bufs, sizes), 0);
    check("AV1: overlapping tiles are refused", virgl_video_end_frame(c, t), -1);
    long long peak = footprint_mb(1);
    printf("     footprint %lld MB, peak %lld MB\n", footprint_mb(0), peak);
    check("AV1: the peak footprint stays under 256 MB", peak < 256, 1);
    virgl_video_destroy_codec(c);
    virgl_video_destroy_buffer(t);
    free(bs);
    free(u);
}

struct bits { uint8_t *p; unsigned n; };
static void put(struct bits *b, unsigned v, unsigned n) {
    while (n--) {
        if (v >> n & 1) b->p[b->n >> 3] |= (uint8_t)(0x80 >> (b->n & 7));
        b->n++;
    }
}

// A profile 0 key frame whose header codes cw x ch, sent with a 64x64 descriptor; returns decode_bitstream's status
static int vp9_size(unsigned cw, unsigned ch) {
    struct virgl_video_buffer *t;
    struct virgl_video_codec *c = codec(PIPE_VIDEO_PROFILE_VP9_PROFILE0, 64, 64, &t);
    union virgl_picture_desc *u = calloc(1, sizeof(*u));
    u->vp9.base.profile = PIPE_VIDEO_PROFILE_VP9_PROFILE0;
    u->vp9.picture_parameter.frame_width = 64, u->vp9.picture_parameter.frame_height = 64;
    u->vp9.picture_parameter.bit_depth = 8;
    static uint8_t hdr[4096];
    memset(hdr, 0, sizeof hdr);
    struct bits b = {hdr, 0};
    put(&b, 2, 2), put(&b, 0, 2), put(&b, 0, 1), put(&b, 0, 1), put(&b, 1, 1), put(&b, 0, 1); // marker, profile, key, shown
    put(&b, 0x498342, 24), put(&b, 2, 3), put(&b, 0, 1);                                        // sync code, colour
    put(&b, cw - 1, 16), put(&b, ch - 1, 16), put(&b, 0, 1);
    const void *bufs[] = {hdr};
    unsigned sizes[] = {sizeof hdr};
    int rc = virgl_video_begin_frame(c, t);
    if (!rc) rc = virgl_video_decode_bitstream(c, t, u, 1, bufs, sizes);
    if (!rc) virgl_video_end_frame(c, t); // the data after the header is junk: VideoToolbox may refuse it
    virgl_video_destroy_codec(c);
    virgl_video_destroy_buffer(t);
    free(u);
    return rc;
}

int main(void) {
    check("virgl_video_init", virgl_video_init(-1, &cbs, 0), 0);
    av1_overlap();
    check("VP9: a key frame of the descriptor's size is taken", vp9_size(64, 64), 0);
    check("VP9: a key frame that codes 8192x8192 is refused", vp9_size(8192, 8192), -1);
    check("VP9: a key frame that codes 128x64 is refused", vp9_size(128, 64), -1);
    printf("%d checks, %d failures\n", checks, failures);
    return failures != 0;
}
