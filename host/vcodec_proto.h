/* The hvcodec protocol: a guest process asks the host's VideoToolbox to decode, encode and convert video.
   docs/guest-video-encode-plan.md has the design. The guest reaches it at 10.0.2.4:8470 (TCP through libslirp).

   Each message is a 16-byte header and a payload. All integers are little-endian. A reply has the request's type
   with HV_VC_REPLY set, the request's sequence number, and a status (0, or a negative HV_VC_E_*). An error reply's
   payload is a short text. A request the host cannot parse closes the connection.

   This header is shared with the guest tools (tools/linux/hvcodec), so it is plain C99 with no host types. */
#ifndef HENGE_VCODEC_PROTO_H
#define HENGE_VCODEC_PROTO_H

#include <stdint.h>

#define HV_VC_PORT 8470
#define HV_VC_VERSION 1

typedef struct {
    uint32_t type;
    uint32_t len; /* payload bytes after this header */
    uint32_t seq;
    int32_t status; /* 0 in a request */
} HvVcHeader;

#define HV_VC_REPLY 0x80000000u

enum {
    HV_VC_QUERY = 1,
    HV_VC_DEC_OPEN = 2,
    HV_VC_DEC_FRAME = 3,
    HV_VC_DEC_CLOSE = 4,
    HV_VC_ENC_OPEN = 5,
    HV_VC_ENC_FRAME = 6,
    HV_VC_ENC_PACKET = 7,
    HV_VC_ENC_CLOSE = 8,
    HV_VC_FRAME_FREE = 9,
    HV_VC_FRAME_ALLOC = 10,
    HV_VC_FRAME_UPLOAD = 11,
    HV_VC_FRAME_DOWNLOAD = 12,
    HV_VC_XFER = 13,
};

enum {
    HV_VC_OK = 0,
    HV_VC_E_INVAL = -1, /* a field out of range, or a length that does not agree */
    HV_VC_E_NOSUP = -2, /* no such codec, profile or format on this device */
    HV_VC_E_LIMIT = -3, /* sessions, frames, memory or queued packets at the limit */
    HV_VC_E_HANDLE = -4, /* no such session or frame in this connection */
    HV_VC_E_CODEC = -5, /* VideoToolbox refused; the text has its status */
    HV_VC_E_LOST = -6, /* the system stopped the session (on iOS: the app left the screen); open a new one */
    HV_VC_E_AGAIN = -7, /* ENC_PACKET: no packet yet */
    HV_VC_E_EOF = -8, /* ENC_PACKET: flushed, and no packet left */
    HV_VC_E_TIMEOUT = -9,
    HV_VC_E_NOMEM = -10,
};

/* Pixel formats. Planes are sent tightly packed (no row padding), in plane order. */
enum {
    HV_VC_FMT_NV12 = 1, /* 4:2:0 8 bit, Y then CbCr */
    HV_VC_FMT_P010 = 2, /* 4:2:0 10 bit in the high bits of 16 (FFmpeg p010le) */
    HV_VC_FMT_NV16 = 3, /* 4:2:2 8 bit */
    HV_VC_FMT_P210 = 4, /* 4:2:2 10 bit */
    HV_VC_FMT_NV24 = 5, /* 4:4:4 8 bit */
    HV_VC_FMT_P410 = 6, /* 4:4:4 10 bit */
    HV_VC_FMT_BGRA = 7,
    HV_VC_FMT_COUNT = 8,
};
#define HV_VC_FMT_BIT(f) (1u << (f))

/* Range, as FFmpeg's AVColorRange: 0 unspecified (video range), 1 video, 2 full. */
enum { HV_VC_RANGE_UNSPEC = 0, HV_VC_RANGE_VIDEO = 1, HV_VC_RANGE_FULL = 2 };

/* Codecs are four-character codes, as VideoToolbox's CMVideoCodecType. */
#define HV_VC_FOURCC(a, b, c, d) (((uint32_t)(a) << 24) | ((uint32_t)(b) << 16) | ((uint32_t)(c) << 8) | (uint32_t)(d))
#define HV_VC_H264 HV_VC_FOURCC('a', 'v', 'c', '1')
#define HV_VC_HEVC HV_VC_FOURCC('h', 'v', 'c', '1')
#define HV_VC_HEVC_ALPHA HV_VC_FOURCC('m', 'u', 'x', 'a')
#define HV_VC_AV1 HV_VC_FOURCC('a', 'v', '0', '1')
#define HV_VC_VP9 HV_VC_FOURCC('v', 'p', '0', '9')
#define HV_VC_JPEG HV_VC_FOURCC('j', 'p', 'e', 'g')

/* Host limits. QUERY reports the values in use. */
#define HV_VC_MAX_SESSIONS 4
#define HV_VC_MAX_FRAMES 32
#define HV_VC_MAX_DIM 8192
#define HV_VC_MAX_AREA (8192u * 4352u)
#define HV_VC_MIN_DIM 16
#define HV_VC_MAX_PAYLOAD (128u << 20) /* an 8K P410 frame is 212 MB: larger frames are refused at FRAME_ALLOC */
#define HV_VC_MAX_BITSTREAM (32u << 20)
#define HV_VC_MAX_EXTRADATA (64u << 10)

/* ---- QUERY: no request payload. Reply: HvVcQueryHead, the encoders, the decoders. ---- */
typedef struct {
    uint32_t version;
    uint32_t n_encoders;
    uint32_t n_decoders;
    uint32_t max_sessions;
    uint32_t max_frames;
    uint32_t max_width;
    uint32_t max_height;
    uint32_t encoder_size; /* sizeof(HvVcEncoderInfo), so a newer host can add fields */
    uint64_t max_frame_bytes; /* all live frames of one connection */
    uint32_t decoder_size;
    uint32_t reserved;
} HvVcQueryHead;

#define HV_VC_MAX_PROFILES 64
typedef struct {
    char name[56]; /* VideoToolbox's ProfileLevel value, for ENC_OPEN */
    uint32_t formats; /* HV_VC_FMT_BIT of each input format a test frame encoded from */
    uint32_t out; /* hvcC of the test output: chroma format << 8 | luma bit depth, or 0 */
} HvVcProfileInfo;

enum {
    HV_VC_ENC_HW = 1, /* a session that requires hardware started */
    HV_VC_ENC_LISTED_HW = 2, /* the encoder list says hardware (the key can be absent on iOS) */
    HV_VC_ENC_REORDER = 4, /* B-frames */
    HV_VC_ENC_INSTANCE_LIMIT = 8,
};

typedef struct {
    uint32_t codec;
    uint32_t flags;
    uint32_t max_width; /* the largest of 1920x1080, 3840x2160 and 7680x4320 with a property list */
    uint32_t max_height;
    uint32_t n_profiles;
    uint32_t formats; /* with no profile set */
    uint32_t n_properties;
    uint32_t reserved;
    char encoder_id[128];
    char name[64];
    HvVcProfileInfo profiles[HV_VC_MAX_PROFILES];
} HvVcEncoderInfo;

enum { HV_VC_DEC_HW = 1, HV_VC_DEC_SUPPLEMENTAL = 2 /* hardware only after the supplemental registration */ };
typedef struct {
    uint32_t codec;
    uint32_t flags;
    uint32_t reserved[2];
} HvVcDecoderInfo;

/* ---- DEC_OPEN: HvVcDecOpen + extradata. Reply: HvVcOpenReply. ---- */
typedef struct {
    uint32_t codec; /* HV_VC_H264, HV_VC_HEVC, HV_VC_AV1, HV_VC_VP9 */
    uint32_t width, height;
    uint32_t format; /* output: HV_VC_FMT_NV12 (0 means this) or another */
    uint32_t range;
    uint32_t extradata_len; /* avcC, hvcC, av1C or vpcC as in MP4, or Annex B parameter sets */
} HvVcDecOpen;

typedef struct {
    uint32_t session;
    uint32_t flags; /* HV_VC_DEC_HW or HV_VC_ENC_HW: the session uses hardware */
} HvVcOpenReply;

/* ---- DEC_FRAME: HvVcDecFrame + the compressed data of one frame. Reply: HvVcFrameReply. ---- */
typedef struct {
    uint32_t session;
    uint32_t flags;
    int64_t pts; /* passed back with the frame */
    int64_t duration;
} HvVcDecFrame;

enum { HV_VC_FRAME_NONE = 1 /* no picture out of this data (handle 0) */, HV_VC_FRAME_DROPPED = 2 };
typedef struct {
    uint32_t handle;
    uint32_t flags;
    uint32_t width, height;
    uint32_t format;
    uint32_t range;
    int64_t pts;
} HvVcFrameReply;

/* ---- ENC_OPEN: HvVcEncOpen. Reply: HvVcOpenReply. ---- */
enum {
    HV_VC_ENC_F_BFRAMES = 1,
    HV_VC_ENC_F_REALTIME = 2,
    HV_VC_ENC_F_CBR = 4, /* bitrate is constant, not average */
    HV_VC_ENC_F_SOFTWARE_OK = 8, /* allow a software encoder */
    HV_VC_ENC_F_SPEED = 16, /* prioritise speed over quality */
};
typedef struct {
    uint32_t codec;
    uint32_t width, height;
    uint32_t format; /* of the frames ENC_FRAME will give; others are converted by VideoToolbox */
    uint32_t range;
    uint32_t fps_num, fps_den; /* expected frame rate, 0 for none */
    uint32_t timescale; /* pts and duration units per second */
    uint32_t flags;
    uint32_t quality; /* 1 to 100 for constant quality; 0 for bitrate */
    uint64_t bitrate; /* bits per second; 0 for the encoder's choice */
    uint64_t max_bytes; /* data rate limit: at most max_bytes in max_window_ms (0 for none) */
    uint32_t max_window_ms;
    uint32_t keyint; /* frames between key frames, 0 for the encoder's choice */
    uint32_t keyint_ms; /* the same as a duration */
    uint32_t primaries, transfer, matrix; /* ITU-T H.273 code points (FFmpeg's values), 0 or 2 for none */
    uint32_t hdr_flags; /* 1: mastering is set, 2: light is set */
    char profile[56]; /* a name from QUERY, or empty for the default */
    uint8_t mastering[24]; /* HEVC SEI mastering_display_colour_volume, big-endian */
    uint8_t light[4]; /* HEVC SEI content_light_level_info, big-endian */
    uint32_t reserved;
} HvVcEncOpen;

/* ---- ENC_FRAME: HvVcEncFrame. Reply: no payload. The host keeps its own reference: free the handle at once if done. ---- */
enum { HV_VC_ENC_FRAME_KEY = 1, HV_VC_ENC_FRAME_EOS = 2 /* no frame: finish the stream */ };
typedef struct {
    uint32_t session;
    uint32_t handle;
    int64_t pts;
    int64_t duration;
    uint32_t flags;
    uint32_t reserved;
} HvVcEncFrame;

/* ---- ENC_PACKET: HvVcEncPacketReq. Reply: HvVcPacket + extradata + data, or E_AGAIN, or E_EOF. ---- */
enum { HV_VC_PACKET_WAIT = 1 /* wait up to timeout_ms for a packet */ };
typedef struct {
    uint32_t session;
    uint32_t flags;
    uint32_t timeout_ms; /* at most 10000 */
    uint32_t reserved;
} HvVcEncPacketReq;

enum { HV_VC_PACKET_KEY = 1, HV_VC_PACKET_HDR10 = 2 /* first packet: the encoder took the mastering display data */ };
typedef struct {
    uint32_t flags;
    uint32_t extradata_len; /* the first packet carries avcC or hvcC (MP4 form); the data is length-prefixed */
    int64_t pts, dts, duration;
} HvVcPacket;

/* ---- DEC_CLOSE, ENC_CLOSE: HvVcSession. FRAME_FREE, FRAME_DOWNLOAD: HvVcHandle. ---- */
typedef struct {
    uint32_t session;
    uint32_t reserved;
} HvVcSession;

typedef struct {
    uint32_t handle;
    uint32_t reserved;
} HvVcHandle;

/* ---- FRAME_ALLOC: HvVcFrameAlloc. Reply: HvVcFrameReply. ---- */
typedef struct {
    uint32_t width, height;
    uint32_t format;
    uint32_t range;
    uint32_t primaries, transfer, matrix; /* H.273 code points of the pixels the guest will upload, 0 for none */
    uint32_t reserved;
} HvVcFrameAlloc;

/* FRAME_UPLOAD: HvVcHandle + the planes (exactly hv_vc_frame_bytes). Reply: no payload.
   FRAME_DOWNLOAD reply: HvVcFrameReply + the planes. */

/* ---- XFER: HvVcXfer. Reply: HvVcFrameReply for a new frame. Scale, format and colour conversion. ---- */
typedef struct {
    uint32_t src;
    uint32_t width, height;
    uint32_t format;
    uint32_t range;
    uint32_t primaries, transfer, matrix; /* H.273 code points for the output, 0 to keep the source's */
    uint32_t flags; /* 1: keep the aspect ratio (letterbox), else stretch */
    uint32_t reserved;
} HvVcXfer;

/* The two sides must agree on these sizes (both are LP64). */
typedef char hv_vc_check_enc_open[sizeof(HvVcEncOpen) == 176 ? 1 : -1];
typedef char hv_vc_check_enc_info[sizeof(HvVcEncoderInfo) == 4320 ? 1 : -1];
typedef char hv_vc_check_frame_reply[sizeof(HvVcFrameReply) == 32 ? 1 : -1];
typedef char hv_vc_check_query[sizeof(HvVcQueryHead) == 48 ? 1 : -1];
typedef char hv_vc_check_alloc[sizeof(HvVcFrameAlloc) == 32 ? 1 : -1];
typedef char hv_vc_check_xfer[sizeof(HvVcXfer) == 40 ? 1 : -1];

/* Plane layout of a format. Returns the plane count, 0 for a bad format or size. */
static inline int hv_vc_planes(uint32_t fmt, uint32_t w, uint32_t h, uint32_t row[2], uint32_t rows[2]) {
    uint32_t cw = (w + 1) / 2, ch = (h + 1) / 2;
    if (w < HV_VC_MIN_DIM || h < HV_VC_MIN_DIM || w > HV_VC_MAX_DIM || h > HV_VC_MAX_DIM || (uint64_t)w * h > HV_VC_MAX_AREA) return 0;
    switch (fmt) {
    case HV_VC_FMT_NV12: row[0] = w, rows[0] = h, row[1] = cw * 2, rows[1] = ch; return 2;
    case HV_VC_FMT_P010: row[0] = w * 2, rows[0] = h, row[1] = cw * 4, rows[1] = ch; return 2;
    case HV_VC_FMT_NV16: row[0] = w, rows[0] = h, row[1] = cw * 2, rows[1] = h; return 2;
    case HV_VC_FMT_P210: row[0] = w * 2, rows[0] = h, row[1] = cw * 4, rows[1] = h; return 2;
    case HV_VC_FMT_NV24: row[0] = w, rows[0] = h, row[1] = w * 2, rows[1] = h; return 2;
    case HV_VC_FMT_P410: row[0] = w * 2, rows[0] = h, row[1] = w * 4, rows[1] = h; return 2;
    case HV_VC_FMT_BGRA: row[0] = w * 4, rows[0] = h, row[1] = 0, rows[1] = 0; return 1;
    default: return 0;
    }
}

static inline uint64_t hv_vc_frame_bytes(uint32_t fmt, uint32_t w, uint32_t h) {
    uint32_t row[2], rows[2];
    int n = hv_vc_planes(fmt, w, h, row, rows);
    uint64_t total = 0;
    for (int i = 0; i < n; i++) total += (uint64_t)row[i] * rows[i];
    return total;
}

#endif
