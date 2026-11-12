#ifndef HV_VIRT_WINDOW_H
#define HV_VIRT_WINDOW_H

/* Mac only. A window for the virt board's display, with keyboard and mouse. Main thread; does not return. */
void hv_virt_window_run(unsigned width, unsigned height);

/* In main.c. The window takes the lock around every call into the machine: a guest restart rebuilds it. */
void hv_virt_machine_lock(void);
void hv_virt_machine_unlock(void);
void hv_virt_quit(void);

#endif
