---
title: FFMPEG-TUX
section: 7
header: Tuxedo
footer: tux-ffmpeg
---

# NAME

ffmpeg-tux - the device's hardware video codecs in ffmpeg, in a Tuxedo virtual machine

# DESCRIPTION

A Tuxedo virtual machine runs on an iPhone, an iPad or a Mac (the *device*). The
device has hardware video decoders and encoders. The **tux-ffmpeg** package
gives an **ffmpeg** that uses them.

The device decodes and encodes the video. The decoded frames stay on the
device, in the device's memory. The virtual machine sends the compressed input
and gets the compressed output. So a transcode uses almost no CPU in the
virtual machine, and its speed is the speed of the device's hardware.

The package installs these commands:

`/usr/local/bin/ffmpeg`, `/usr/local/bin/ffprobe`
:   Links to the Tuxedo build. The default `PATH` has `/usr/local/bin` before
    `/usr/bin`, so the command `ffmpeg` is the Tuxedo build. A shell that ran
    `ffmpeg` before the install needs `hash -r`.

`/usr/bin/ffmpeg`
:   Debian's own build, from Debian's **ffmpeg** package, if it is installed.
    The Tuxedo package does not change it. Run it by its full path.

`tux-codec-info`
:   Shows the codecs that this device has. See QUERYING THE DEVICE.

This page lists what the software supports. The device decides what is
available. An iPhone and a Mac have different codecs. **tux-codec-info**
gives the true list for this device.

# DECODING

`-hwaccel tux`
:   Decodes on the device. This works with FFmpeg's own **h264**, **hevc**,
    **av1** and **vp9** decoders. FFmpeg reads the stream and keeps the frame
    order. The device decodes each frame.

    If the device has no decoder for the stream, or refuses the stream, FFmpeg
    decodes it in software. You do not have to do anything. The log tells you.

`-hwaccel_output_format tux`
:   Keeps each decoded frame on the device as a **tux** frame. Use this for a
    transcode: the frame goes from the decoder to the encoder and never enters
    the virtual machine. Without it, each frame comes down to the virtual
    machine's memory, which is slow at 4K.

`-init_hw_device tux`
:   Opens the device before the input. **hwupload** needs this, because it
    needs the device before the decoder opens. **-hwaccel tux** then uses the
    same device.

    `-init_hw_device tux=NAME:ADDRESS` sets the address of the codec service:
    `/dev/hvcodec`, `unix:PATH`, `HOST:PORT` or `HOST` (port 8470). The default
    is the `TUX_VCODEC` environment variable, then `/dev/hvcodec` if it
    opens, then `10.0.2.4:8470`. `-v verbose` shows the one in use.

    On `/dev/hvcodec` (the **tux-codec-dkms** package), raw frames for
    **hwupload**, **hwdownload** and the encoders' own uploads cross with no
    copy in the guest. On TCP they are packed into messages, which is slow at
    4K, and **ffmpeg** writes a warning at the first one. Compressed data and
    frame handles are small on either channel.

The decoder holds a limited number of frames on the device (see LIMITS). If a
decoder stops at that limit, add `-threads 1` before `-i`.

# ENCODERS

Each encoder asks the device for its codec when it opens. If the device does
not have that codec, the encoder stops with a clear message, and
**tux-codec-info** shows what the device has.

Each encoder takes **tux** frames (from `-hwaccel tux` or **scale_tux**),
or these software frames, which it copies to the device first: **nv12**,
**p010le**, **nv16**, **p210le**, **nv24**, **p410le** and **bgra**.

`h264_tux`
:   H.264 on the device's hardware encoder. B-frames where the device permits
    them.

`hevc_tux`
:   HEVC on the device's hardware encoder. 8 bit and 10 bit, and 4:2:2 and
    4:4:4 where the device lists those profiles. HDR10 metadata passes through
    from the input. With **bgra** input and **-alpha_quality**, HEVC with an
    alpha channel.

`av1_tux`
:   AV1 on the device's hardware encoder, only if the device has one. A Mac
    with an M4 Pro has none: there this encoder stops with "This device has no
    av1 hardware encoder". **tux-codec-info** tells you if this device has
    one. There is no software AV1 encoder in this package.

`mjpeg_tux`
:   JPEG on the device's hardware encoder. One JPEG for each frame. No B-frames.

## The profile for each input format

If you do not set **-profile**, the encoder chooses the profile from the input
format. If the device does not list that profile, the encoder writes a
warning and lets the device choose. `-v verbose` shows the profile.

  Input       `hevc_tux`                      `h264_tux`
  ----------  --------------------------------  ---------------------------------
  nv12        Main                              High
  p010le      Main10                            High 10, else High (8 bit out)
  nv16        Main 4:2:2 10 (no 8-bit 4:2:2)    High 4:2:2
  p210le      Main 4:2:2 10                     High 4:2:2
  nv24        Main 4:4:4                        High 4:4:4 Predictive
  p410le      Main 4:4:4 10                     High 4:4:4 Predictive
  bgra        Main                              High
  tux       as its software format            as its software format

On a Mac with an M4 Pro, the H.264 output is 8 bit for each input.

## Size

The device's table gives a size for each encoder. That size is the largest of
three test sizes that the device accepted (1920x1080, 3840x2160 and
7680x4320). It is not a true limit. So the device decides. A larger size can
work: the M4 Pro's H.264 encoder lists 3840x2160 and encodes 4096x4096. When
the device refuses a size that is larger than its table, the error names the
size as the likely cause. The device's own text for that refusal can say that
the system stopped the session. Ignore that text.

# OPTIONS

## Options for each encoder

`-profile` *name*
:   The profile. **h264_tux**: `baseline`, `constrained_baseline`, `main`,
    `high`, `constrained_high`, `high10`, `high422`, `high444`.
    **hevc_tux**: `main`, `main10`, `mainstill`, `main42210`, `rext`
    (`main42210` and `rext` give 4:2:2 or 4:4:4 from the input). Default: from
    the input format (see the table above). The device must list the profile.

`-level` *value*
:   **h264_tux** only. The H.264 level: `1.3` (Baseline only), `3.0`, `3.1`,
    `3.2`, `4.0`, `4.1`, `4.2`, `5.0`, `5.1`, `5.2`. Default: 0, the
    encoder's choice.

`-constant_bit_rate` *bool*
:   **h264_tux** and **hevc_tux**. Requires a constant bit rate. Needs
    **-b:v**, and does not go with **-q:v** or **-maxrate**. Default: 0.

`-alpha_quality` *number*
:   **hevc_tux** only. 0.0 to 1.0. More than 0 with **bgra** input gives HEVC
    with alpha. Default: 0.0 (no alpha channel).

`-prio_speed` *bool*
:   All encoders. 1 tells the device to prefer speed over quality. Set the frame
    rate too (it comes from the input). On an M4 Pro Mac, the HEVC encoder then
    gives about 100 fps at 3840x2160, against about 60 without it. The H.264
    encoder did not change. Default: -1, the device's default.

`-realtime` *bool*
:   All encoders. 1 tells the device that the encode is in real time. Default: 0.

`-allow_sw` *bool*
:   All encoders. 1 permits a software encoder on the device when it has no
    hardware encoder for the codec. Default: 0.

## FFmpeg's own options that the encoders use

`-b:v` *rate*
:   The average bit rate. Default: 0, the device chooses.

`-q:v` *quality*
:   Constant quality, from 1 to 100. A higher number gives a better picture and
    a larger file. It replaces **-b:v**.

`-maxrate` *rate*
:   A data rate limit over each second.

`-g` *frames*
:   The key frame interval in frames. Default: a key frame each 2 seconds.

`-bf` *frames*
:   `-bf 0` turns B-frames off. Default: B-frames on where the device permits.

`-color_primaries`, `-color_trc`, `-colorspace`
:   The colour tags of the output. Default: those of the input.

`-tag:v hvc1`
:   For MP4 output from **hevc_tux**. FFmpeg writes `hev1` by default, which
    some players do not play.

# FILTERS

`scale_tux`
:   Scales and converts **tux** frames on the device, in one step. The frames
    stay on the device. Its options:

`w`, `h`
:   The output width and height, as for FFmpeg's **scale**. Default: `iw` and
    `ih`. `scale_tux=1920:1080` is the same as `scale_tux=w=1920:h=1080`.

`format`
:   The output pixel format: `nv12`, `p010le`, `nv16`, `p210le`, `nv24`,
    `p410le` or `bgra`. Default: the input's format.

`letterbox`
:   1 keeps the aspect ratio inside the output size. Default: 0.

`color_matrix`, `color_primaries`, `color_transfer`
:   The output colour tags, by FFmpeg's names (for example `bt709`, `bt2020nc`,
    `smpte2084`). Default: those of the input.

`hwdownload`, `hwupload`
:   Move frames between the device and the virtual machine. Use them for a
    software filter: `hwdownload,format=nv12,FILTER,hwupload`. Each frame then
    crosses twice. You can leave out the last **hwupload**, because the encoders
    copy **nv12** and the other software formats to the device themselves.

# LIMITS

- An **ffmpeg** process usually has one connection to the device: the decoder,
  the filters and the encoder share it. A connection has at most 4 decoder and
  encoder sessions, and at most 32 live frames on the device. The device takes
  at most 8 connections at the same time.
- The device also limits the frame memory, the queued packets and the sessions
  of all connections together. On an iPhone or an iPad: 512 MiB of frames,
  128 MiB of packets and 8 sessions. On a Mac: 2 GiB, 512 MiB and 16. At a
  limit, the encoder waits and tries again. After 20 seconds at a limit, it
  stops with the device's text.
- A frame is at most 8192 pixels wide or high, and at most 8192x4352 pixels in
  all. A frame that is larger than 128 MB, for example 8K 4:4:4 10 bit, cannot
  come down to the virtual machine, and the device refuses to make it.
- No ProRes.
- AV1 output only where the device's hardware encodes AV1. There is no software
  AV1 encoder.
- No encode while Tuxedo is not on the screen of an iPhone or an iPad. The
  system stops the session, and **ffmpeg** stops with an error.
- A software filter stops 4K at 60 fps: each frame then comes down to the
  virtual machine and goes up again, and the filter runs on the virtual
  machine's CPU.
- The codecs, the profiles, the sizes and the speed depend on the device.

# QUERYING THE DEVICE

`tux-codec-info`
:   Shows the device's live codec table: each encoder with its **ffmpeg**
    encoder, whether it is hardware, its profiles with their output, its input
    formats and its size; and each decoder. `--json` gives the same table to a
    script. `--addr ADDRESS` takes the address forms of **-init_hw_device**.

`ffmpeg -h encoder=hevc_tux`
:   Shows the options of an encoder.

`ffmpeg -hwaccels`
:   Shows `tux` in the list.

# EXAMPLES

A 4K60 transcode to HEVC, with the frames on the device:

    ffmpeg -hwaccel tux -hwaccel_output_format tux -i in.mkv \
           -c:v hevc_tux -b:v 20M -tag:v hvc1 -c:a copy out.mp4

The same, scaled to 1080p on the device:

    ffmpeg -hwaccel tux -hwaccel_output_format tux -i in.mkv \
           -vf scale_tux=1920:1080 -c:v hevc_tux -b:v 8M -c:a copy out.mp4

A software filter between the decoder and the encoder (slow at 4K):

    ffmpeg -init_hw_device tux -hwaccel tux -hwaccel_output_format tux \
           -i in.mkv -vf hwdownload,format=nv12,subtitles=in.srt,hwupload \
           -c:v hevc_tux -b:v 20M -c:a copy out.mp4

A 10-bit HDR10 source to Main10, with its HDR10 metadata:

    ffmpeg -hwaccel tux -hwaccel_output_format tux -i hdr.mkv \
           -c:v hevc_tux -profile:v main10 -b:v 30M -tag:v hvc1 out.mp4

Constant quality to H.264:

    ffmpeg -hwaccel tux -hwaccel_output_format tux -i in.mkv \
           -c:v h264_tux -q:v 65 -c:a copy out.mp4

Debian's own build, with no Tuxedo codecs:

    /usr/bin/ffmpeg -i in.mkv -c:v libx264 out.mp4

# ENVIRONMENT

`TUX_VCODEC`
:   The address of the codec service, when **-init_hw_device** gives none.
    `TUX_VCODEC=10.0.2.4:8470` keeps TCP when `/dev/hvcodec` is there.

# FILES

`/usr/local/bin/ffmpeg`, `/usr/local/bin/ffprobe`
:   Links that the package makes when it is installed, and removes when it is
    removed. The package does not replace a file there that it did not make.

`/usr/lib/tux/ffmpeg/bin/`
:   The Tuxedo **ffmpeg**, **ffprobe** and **tux-codec-info**.

`/usr/bin/ffmpeg`
:   Debian's **ffmpeg**, if it is installed.

`/dev/hvcodec`
:   The DMA channel, from the **tux-codec-dkms** package, for the group
    **video**. The machine must run with the codec device on. DKMS builds the
    module again after each kernel update; if a build fails, the device node is
    not there and all data goes over TCP to `10.0.2.4:8470`.

`/usr/share/man/man7/ffmpeg-tux.7.gz`
:   This page. **man** comes from Debian's **man-db** package, which
    **tux-ffmpeg** recommends.

`/usr/share/doc/tux-ffmpeg/`
:   The licence, the build manifest, and where to get the source.

# SEE ALSO

**ffmpeg**(1), **ffmpeg-codecs**(1), **ffmpeg-filters**(1)
