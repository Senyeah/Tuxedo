#ifndef HV_VIRT_WINDOW_H
#define HV_VIRT_WINDOW_H

/* Mac only. A window for the virt board's display, with keyboard and mouse. Main thread; does not return. */
void hv_virt_window_run(unsigned width, unsigned height);

#endif
