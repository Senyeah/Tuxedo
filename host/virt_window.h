#ifndef HV_VIRT_WINDOW_H
#define HV_VIRT_WINDOW_H

/* Mac only. A window for the virt board's display, with keyboard and mouse. Main thread; does not return. */
void hv_virt_window_run(unsigned width, unsigned height);
/* Set before the window runs: a click is one contact on the touchscreen, at the click's place, not the mouse. */
extern int hv_virt_window_touch;

/* In main.c. The window takes the lock around every call into the machine: a guest restart rebuilds it. */
void hv_virt_machine_lock(void);
void hv_virt_machine_unlock(void);
void hv_virt_quit(void);

#endif
