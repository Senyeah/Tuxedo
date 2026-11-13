# DKMS runs this with KERNELRELEASE unset: make -C <kernel build dir> M=<here> modules.
obj-m := henge_codec.o

KVER ?= $(shell uname -r)
KDIR ?= /lib/modules/$(KVER)/build

all:
	$(MAKE) -C $(KDIR) M=$(CURDIR) modules

clean:
	$(MAKE) -C $(KDIR) M=$(CURDIR) clean
