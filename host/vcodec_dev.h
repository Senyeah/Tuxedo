/* The hvcodec DMA channel: the virtio device (devices/virtio_hvcodec.c), the guest's tux_codec module
   (tools/linux/tux-codec-dkms) and libhvcodec's /dev/hvcodec client. docs/guest-video-encode-plan.md has the design.

   The device carries hvcodec messages (vcodec_proto.h) and does not parse them. One request is one descriptor chain:
     readable: HvcdReq, the message (msg_len), the raw data to the host (in_len)
     writable: HvcdResp, the reply (reply_cap), the raw data from the host (out_len)
   The lengths must equal the chain's. A context is an open file on /dev/hvcodec: OPEN makes one, CLOSE ends it.
   A reply larger than reply_cap stays on the host; REST requests on the same context take the rest, and any other
   request drops it.

   Shared with the kernel module, so plain C with no host types. Little-endian, as the guest. */
#ifndef TUX_VCODEC_DEV_H
#define TUX_VCODEC_DEV_H

#ifdef __KERNEL__
#include <linux/types.h>
typedef __u32 hvcd_u32;
typedef __s32 hvcd_s32;
typedef __u64 hvcd_u64;
#else
#include <stdint.h>
typedef uint32_t hvcd_u32;
typedef int32_t hvcd_s32;
typedef uint64_t hvcd_u64;
#endif

/* Linux's virtio-pci binds 0x1040 to 0x107f, so 63 is its last type. VIRTIO 1.4 (and the draft after it) assigns up to
   50, Linux 6.12 names up to 48, and Tuxedo uses 1, 2, 4, 5, 16, 18 and 25. The module also checks HVCD_MAGIC. */
#define HVCD_DEVICE_ID 63
#define HVCD_MAGIC 0x44435648u /* "HVCD" */
#define HVCD_VERSION 1
#define HVCD_MAX_CONTEXTS 8
#define HVCD_MAX_MESSAGE ((128u << 20) + 16u) /* HV_VC_MAX_PAYLOAD and the header */
#define HVCD_MAX_DATA (256u << 20) /* each direction: planes with row padding */
#define HVCD_MAX_REPLY (256u << 20)
/* Descriptors in one chain: 256 MiB of data in each direction as 16 KB pages, and the rest. A 4 KB kernel joins pages. */
#define HVCD_MAX_SEGS (2u * 16384u + 512u)

/* Device configuration space. */
typedef struct {
    hvcd_u32 magic;
    hvcd_u32 version;
    hvcd_u32 max_segs;
    hvcd_u32 max_contexts;
    hvcd_u64 max_message;
    hvcd_u64 max_data;
} HvcdConfig;

enum { HVCD_OP_OPEN = 1, HVCD_OP_CLOSE = 2, HVCD_OP_MSG = 3, HVCD_OP_REST = 4 };

typedef struct {
    hvcd_u32 op;
    hvcd_u32 ctx; /* from OPEN's reply; 0 for OPEN */
    hvcd_u32 msg_len;
    hvcd_u32 in_len;
    hvcd_u32 reply_cap;
    hvcd_u32 out_len;
    hvcd_u32 reserved[2];
} HvcdReq;

enum {
    HVCD_S_OK = 0,
    HVCD_S_INVAL = 1, /* the request's lengths or fields */
    HVCD_S_NOCTX = 2, /* no such context */
    HVCD_S_LIMIT = 3, /* no context free, or no host memory for the reply */
    HVCD_S_FAULT = 4, /* an address outside guest RAM */
    HVCD_S_CLOSED = 5, /* the host closed the context after a message it could not parse */
};

typedef struct {
    hvcd_s32 status;
    hvcd_u32 ctx; /* OPEN: the new context */
    hvcd_u32 reply_len; /* bytes of the reply written */
    hvcd_u32 reply_total; /* MSG: the whole reply; REST: what was left before it */
} HvcdResp;

typedef char hvcd_check_req[sizeof(HvcdReq) == 32 ? 1 : -1];
typedef char hvcd_check_resp[sizeof(HvcdResp) == 16 ? 1 : -1];
typedef char hvcd_check_config[sizeof(HvcdConfig) == 32 ? 1 : -1];

/* ---- /dev/hvcodec, the module's character device. Each open file is one host context. ---- */
#if defined(__linux__) || defined(__KERNEL__)
#ifdef __KERNEL__
#include <linux/ioctl.h>
#else
#include <sys/ioctl.h>
#endif

struct hvcodec_buf {
    hvcd_u64 addr; /* a user address; len 0 for none */
    hvcd_u64 len;
};

/* One message and its reply. The module pins each buffer for the call; the host reads and writes them in place. */
struct hvcodec_call {
    struct hvcodec_buf msg[3]; /* the message, in parts: HvVcHeader and its payload */
    struct hvcodec_buf in[2]; /* raw data to the host (FRAME_UPLOAD_DMA's planes) */
    struct hvcodec_buf reply;
    struct hvcodec_buf out[2]; /* raw data from the host (FRAME_DOWNLOAD_DMA's planes) */
    hvcd_u32 reply_len; /* out: bytes of the reply written */
    hvcd_u32 reply_total; /* out: the whole reply; more than reply_len: HVCODEC_IOC_REST for the rest */
    hvcd_u32 reserved[2];
};

/* The rest of the last reply. */
struct hvcodec_rest {
    struct hvcodec_buf reply;
    hvcd_u32 reply_len; /* out: bytes written */
    hvcd_u32 reply_left; /* out: bytes left before this call */
};

#define HVCODEC_IOC_CALL _IOWR('H', 0x40, struct hvcodec_call)
#define HVCODEC_IOC_REST _IOWR('H', 0x41, struct hvcodec_rest)
#endif

#endif
