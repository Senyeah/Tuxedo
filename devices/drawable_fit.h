/* SPDX-License-Identifier: GPL-2.0-or-later */
#ifndef HV_DRAWABLE_FIT_H
#define HV_DRAWABLE_FIT_H
#import <QuartzCore/CAMetalLayer.h>
#include <math.h>

/* Drawable for a w x h scanout: its shape, no larger than the layer's pixels (bounds x contentsScale).
   One cap on the whole size, not per axis. An unsized layer uses cap_w x cap_h, 0 for none. */
static inline CGSize hv_drawable_fit(CAMetalLayer *layer, double w, double h, double cap_w, double cap_h) {
    CGSize b = layer.bounds.size;
    double s = layer.contentsScale, lw = b.width * s, lh = b.height * s, k = 1;
    if (lw >= 1 && lh >= 1) k = fmin(lw / w, lh / h);
    else if (cap_w >= 1 && cap_h >= 1) k = fmin(cap_w / w, cap_h / h);
    k = fmin(1, k);
    return CGSizeMake(fmax(1, round(w * k)), fmax(1, round(h * k)));
}

#endif
