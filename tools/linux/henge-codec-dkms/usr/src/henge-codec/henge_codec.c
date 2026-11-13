// SPDX-License-Identifier: GPL-2.0-or-later
/*
 * henge_codec: /dev/hvcodec for Henge's hvcodec DMA device (docs/guest-video-encode-plan.md, stage VE4).
 *
 * Each open file is one host codec context. HVCODEC_IOC_CALL pins the caller's buffers (the message, the raw data
 * to the host, the reply and the raw data from the host), puts their pages on the device's queue as one chain and
 * sleeps until the host answers. The host reads and writes the pages in place, so a frame crosses with no copy in
 * the guest. The module does not parse the messages; vcodec_dev.h has the device's ABI.
 */
#include <linux/kernel.h>
#include <linux/kref.h>
#include <linux/miscdevice.h>
#include <linux/mm.h>
#include <linux/module.h>
#include <linux/mutex.h>
#include <linux/refcount.h>
#include <linux/scatterlist.h>
#include <linux/slab.h>
#include <linux/uaccess.h>
#include <linux/virtio.h>
#include <linux/virtio_config.h>
#include <linux/workqueue.h>

#include "vcodec_dev.h"

#define HVC_BUFS 8 /* msg[3], in[2], reply, out[2] */

struct hvc_dev {
	struct kref ref; /* the probe's, and one for each open file */
	struct virtio_device *vdev;
	struct virtqueue *vq;
	struct mutex vq_mu; /* the virtqueue: adds and completions */
	struct work_struct done_work;
	struct miscdevice misc;
	bool dead;
	u32 max_segs, max_contexts;
	u64 max_message, max_data;
};

struct hvc_pin {
	struct page **pages;
	unsigned long n;
	struct sg_table sgt;
	bool write, used;
};

/* What the device reads and writes besides the caller's pages. */
struct hvc_dma {
	HvcdReq req;
	HvcdResp resp;
};

struct hvc_req {
	refcount_t ref; /* the caller's and the device's: a caller that is killed leaves it to the completion */
	struct completion done;
	struct hvc_dma *dma;
	struct hvc_pin pin[HVC_BUFS];
	bool failed; /* the device went away before it answered */
};

struct hvc_file {
	struct hvc_dev *d;
	struct mutex mu; /* one call at a time: the host serves a context in order */
	u32 ctx;
	bool open;
};

static struct hvc_dev *the_dev;
static DEFINE_MUTEX(the_dev_mu);

static void hvc_dev_free(struct kref *ref)
{
	kfree(container_of(ref, struct hvc_dev, ref));
}

static void hvc_unpin(struct hvc_pin *p)
{
	if (!p->used)
		return;
	sg_free_table(&p->sgt);
	if (p->write)
		unpin_user_pages_dirty_lock(p->pages, p->n, true);
	else
		unpin_user_pages(p->pages, p->n);
	kvfree(p->pages);
	p->used = false;
}

static void hvc_req_put(struct hvc_req *r)
{
	if (!refcount_dec_and_test(&r->ref))
		return;
	for (int i = 0; i < HVC_BUFS; i++)
		hvc_unpin(&r->pin[i]);
	kfree(r->dma);
	kfree(r);
}

static struct hvc_req *hvc_req_new(void)
{
	struct hvc_req *r = kzalloc(sizeof(*r), GFP_KERNEL);

	if (!r)
		return NULL;
	r->dma = kzalloc(sizeof(*r->dma), GFP_KERNEL);
	if (!r->dma) {
		kfree(r);
		return NULL;
	}
	refcount_set(&r->ref, 1);
	init_completion(&r->done);
	return r;
}

static int hvc_pin(struct hvc_pin *p, u64 addr, u64 len, bool write)
{
	unsigned long first, n;
	long got;
	int ret;

	if (!len)
		return 0;
	if (addr + len < addr || !access_ok(u64_to_user_ptr(addr), len))
		return -EFAULT;
	first = addr >> PAGE_SHIFT;
	n = ((addr + len - 1) >> PAGE_SHIFT) - first + 1;
	p->pages = kvmalloc_array(n, sizeof(*p->pages), GFP_KERNEL);
	if (!p->pages)
		return -ENOMEM;
	got = pin_user_pages_fast(addr & PAGE_MASK, n, write ? FOLL_WRITE : 0, p->pages);
	if (got != (long)n) {
		if (got > 0)
			unpin_user_pages(p->pages, got);
		kvfree(p->pages);
		return got < 0 ? got : -EFAULT;
	}
	/* pages that are next to each other become one segment */
	ret = sg_alloc_table_from_pages_segment(&p->sgt, p->pages, n, offset_in_page(addr), len,
						UINT_MAX & PAGE_MASK, GFP_KERNEL);
	if (ret) {
		unpin_user_pages(p->pages, n);
		kvfree(p->pages);
		return ret;
	}
	p->n = n;
	p->write = write;
	p->used = true;
	return 0;
}

static void hvc_done_work(struct work_struct *w)
{
	struct hvc_dev *d = container_of(w, struct hvc_dev, done_work);
	struct hvc_req *r;
	unsigned int len;

	mutex_lock(&d->vq_mu);
	do {
		virtqueue_disable_cb(d->vq);
		while ((r = virtqueue_get_buf(d->vq, &len))) {
			complete(&r->done);
			hvc_req_put(r);
		}
	} while (!virtqueue_enable_cb(d->vq));
	mutex_unlock(&d->vq_mu);
}

/* Interrupt context: the completions go to the work, where a request can unpin its pages. */
static void hvc_vq_done(struct virtqueue *vq)
{
	struct hvc_dev *d = vq->vdev->priv;

	schedule_work(&d->done_work);
}

static int hvc_status(s32 st)
{
	switch (st) {
	case HVCD_S_OK: return 0;
	case HVCD_S_NOCTX: return -EBADF;
	case HVCD_S_LIMIT: return -ENOBUFS;
	case HVCD_S_FAULT: return -EFAULT;
	case HVCD_S_CLOSED: return -EPIPE;
	default: return -EINVAL;
	}
}

/*
 * Puts the request on the queue and waits for the host. killable: a fatal signal ends the wait, and the request
 * stays pinned until the host gives it back.
 */
static int hvc_submit(struct hvc_dev *d, struct hvc_req *r, bool killable)
{
	struct scatterlist hdr, resp, *sgs[2 + HVC_BUFS];
	unsigned int nout = 0, nin = 0, segs = 2;
	int ret;

	sg_init_one(&hdr, &r->dma->req, sizeof(r->dma->req));
	sg_init_one(&resp, &r->dma->resp, sizeof(r->dma->resp));
	sgs[nout++] = &hdr;
	for (int i = 0; i < HVC_BUFS; i++)
		if (r->pin[i].used && !r->pin[i].write)
			sgs[nout++] = r->pin[i].sgt.sgl, segs += r->pin[i].sgt.orig_nents;
	sgs[nout + nin++] = &resp;
	for (int i = 0; i < HVC_BUFS; i++)
		if (r->pin[i].used && r->pin[i].write)
			sgs[nout + nin++] = r->pin[i].sgt.sgl, segs += r->pin[i].sgt.orig_nents;
	if (segs > d->max_segs)
		return -E2BIG;

	refcount_inc(&r->ref);
	mutex_lock(&d->vq_mu);
	ret = d->dead ? -ENODEV : virtqueue_add_sgs(d->vq, sgs, nout, nin, r, GFP_KERNEL);
	if (!ret)
		virtqueue_kick(d->vq);
	mutex_unlock(&d->vq_mu);
	if (ret) {
		refcount_dec(&r->ref);
		return ret == -ENOSPC ? -EAGAIN : ret;
	}
	if (killable) {
		ret = wait_for_completion_killable(&r->done);
		if (ret)
			return -EINTR;
	} else {
		wait_for_completion(&r->done);
	}
	return r->failed ? -ENODEV : 0;
}

/* OPEN and CLOSE wait to the end: a context the host made must not be lost. */
static int hvc_control(struct hvc_dev *d, u32 op, u32 ctx, u32 *out)
{
	struct hvc_req *r = hvc_req_new();
	int ret;

	if (!r)
		return -ENOMEM;
	r->dma->req.op = op;
	r->dma->req.ctx = ctx;
	ret = hvc_submit(d, r, false);
	if (!ret)
		ret = hvc_status(r->dma->resp.status);
	if (!ret && out)
		*out = r->dma->resp.ctx;
	hvc_req_put(r);
	return ret;
}

static long hvc_call(struct hvc_file *f, void __user *arg)
{
	struct hvc_dev *d = f->d;
	struct hvcodec_call c;
	struct hvc_req *r;
	u64 msg_len = 0, in_len = 0, out_len = 0;
	int ret = 0, k = 0;

	if (copy_from_user(&c, arg, sizeof(c)))
		return -EFAULT;
	for (int i = 0; i < 3; i++)
		msg_len += c.msg[i].len;
	for (int i = 0; i < 2; i++)
		in_len += c.in[i].len, out_len += c.out[i].len;
	/* each part is checked too, so a sum cannot wrap */
	for (int i = 0; i < 3; i++)
		if (c.msg[i].len > d->max_message)
			return -E2BIG;
	for (int i = 0; i < 2; i++)
		if (c.in[i].len > d->max_data || c.out[i].len > d->max_data)
			return -E2BIG;
	if (msg_len < 16 || msg_len > d->max_message || in_len > d->max_data || out_len > d->max_data ||
	    c.reply.len > HVCD_MAX_REPLY)
		return -E2BIG;

	r = hvc_req_new();
	if (!r)
		return -ENOMEM;
	for (int i = 0; i < 3 && !ret; i++)
		ret = hvc_pin(&r->pin[k++], c.msg[i].addr, c.msg[i].len, false);
	for (int i = 0; i < 2 && !ret; i++)
		ret = hvc_pin(&r->pin[k++], c.in[i].addr, c.in[i].len, false);
	if (!ret)
		ret = hvc_pin(&r->pin[k++], c.reply.addr, c.reply.len, true);
	for (int i = 0; i < 2 && !ret; i++)
		ret = hvc_pin(&r->pin[k++], c.out[i].addr, c.out[i].len, true);
	if (!ret) {
		HvcdReq *h = &r->dma->req;

		h->op = HVCD_OP_MSG;
		h->ctx = f->ctx;
		h->msg_len = (u32)msg_len;
		h->in_len = (u32)in_len;
		h->reply_cap = (u32)c.reply.len;
		h->out_len = (u32)out_len;
		ret = hvc_submit(d, r, true);
	}
	if (!ret) {
		ret = hvc_status(r->dma->resp.status);
		c.reply_len = r->dma->resp.reply_len;
		c.reply_total = r->dma->resp.reply_total;
		if (c.reply_len > c.reply.len)
			ret = -EIO;
		if (!ret && copy_to_user(arg, &c, sizeof(c)))
			ret = -EFAULT;
	}
	hvc_req_put(r);
	return ret;
}

static long hvc_rest(struct hvc_file *f, void __user *arg)
{
	struct hvcodec_rest c;
	struct hvc_req *r;
	int ret;

	if (copy_from_user(&c, arg, sizeof(c)))
		return -EFAULT;
	if (c.reply.len > HVCD_MAX_REPLY)
		return -E2BIG;
	r = hvc_req_new();
	if (!r)
		return -ENOMEM;
	ret = hvc_pin(&r->pin[0], c.reply.addr, c.reply.len, true);
	if (!ret) {
		r->dma->req.op = HVCD_OP_REST;
		r->dma->req.ctx = f->ctx;
		r->dma->req.reply_cap = (u32)c.reply.len;
		ret = hvc_submit(f->d, r, true);
	}
	if (!ret) {
		ret = hvc_status(r->dma->resp.status);
		c.reply_len = r->dma->resp.reply_len;
		c.reply_left = r->dma->resp.reply_total;
		if (c.reply_len > c.reply.len)
			ret = -EIO;
		if (!ret && copy_to_user(arg, &c, sizeof(c)))
			ret = -EFAULT;
	}
	hvc_req_put(r);
	return ret;
}

static long hvc_ioctl(struct file *file, unsigned int cmd, unsigned long arg)
{
	struct hvc_file *f = file->private_data;
	long ret;

	if (cmd != HVCODEC_IOC_CALL && cmd != HVCODEC_IOC_REST)
		return -ENOTTY;
	if (mutex_lock_killable(&f->mu))
		return -EINTR;
	if (f->d->dead || !f->open)
		ret = -ENODEV;
	else if (cmd == HVCODEC_IOC_CALL)
		ret = hvc_call(f, (void __user *)arg);
	else
		ret = hvc_rest(f, (void __user *)arg);
	mutex_unlock(&f->mu);
	return ret;
}

static int hvc_open(struct inode *inode, struct file *file)
{
	struct hvc_file *f;
	struct hvc_dev *d;
	int ret;

	mutex_lock(&the_dev_mu);
	d = the_dev;
	if (d)
		kref_get(&d->ref);
	mutex_unlock(&the_dev_mu);
	if (!d)
		return -ENODEV;
	f = kzalloc(sizeof(*f), GFP_KERNEL);
	if (!f) {
		kref_put(&d->ref, hvc_dev_free);
		return -ENOMEM;
	}
	f->d = d;
	mutex_init(&f->mu);
	ret = hvc_control(d, HVCD_OP_OPEN, 0, &f->ctx);
	if (ret) {
		kfree(f);
		kref_put(&d->ref, hvc_dev_free);
		return ret == -ENOBUFS ? -EBUSY : ret;
	}
	f->open = true;
	file->private_data = f;
	return 0;
}

static int hvc_release(struct inode *inode, struct file *file)
{
	struct hvc_file *f = file->private_data;
	struct hvc_dev *d = f->d;

	if (f->open && !d->dead)
		hvc_control(d, HVCD_OP_CLOSE, f->ctx, NULL);
	kfree(f);
	kref_put(&d->ref, hvc_dev_free);
	return 0;
}

static const struct file_operations hvc_fops = {
	.owner = THIS_MODULE,
	.open = hvc_open,
	.release = hvc_release,
	.unlocked_ioctl = hvc_ioctl,
	.compat_ioctl = compat_ptr_ioctl,
	.llseek = noop_llseek,
};

static int hvc_probe(struct virtio_device *vdev)
{
	struct hvc_dev *d;
	u32 magic, version;
	int ret;

	magic = virtio_cread32(vdev, offsetof(HvcdConfig, magic));
	version = virtio_cread32(vdev, offsetof(HvcdConfig, version));
	if (magic != HVCD_MAGIC || version != HVCD_VERSION) {
		dev_warn(&vdev->dev, "not a Henge codec device (magic %#x, version %u)\n", magic, version);
		return -ENODEV;
	}
	mutex_lock(&the_dev_mu);
	if (the_dev) {
		mutex_unlock(&the_dev_mu);
		return -EBUSY;
	}
	d = kzalloc(sizeof(*d), GFP_KERNEL);
	if (!d) {
		mutex_unlock(&the_dev_mu);
		return -ENOMEM;
	}
	kref_init(&d->ref);
	d->vdev = vdev;
	mutex_init(&d->vq_mu);
	INIT_WORK(&d->done_work, hvc_done_work);
	d->max_segs = min_t(u32, virtio_cread32(vdev, offsetof(HvcdConfig, max_segs)), HVCD_MAX_SEGS);
	d->max_contexts = virtio_cread32(vdev, offsetof(HvcdConfig, max_contexts));
	d->max_message = min_t(u64, virtio_cread64(vdev, offsetof(HvcdConfig, max_message)), HVCD_MAX_MESSAGE);
	d->max_data = min_t(u64, virtio_cread64(vdev, offsetof(HvcdConfig, max_data)), HVCD_MAX_DATA);
	vdev->priv = d;
	d->vq = virtio_find_single_vq(vdev, hvc_vq_done, "requests");
	if (IS_ERR(d->vq)) {
		ret = PTR_ERR(d->vq);
		goto fail;
	}
	virtio_device_ready(vdev);
	d->misc.minor = MISC_DYNAMIC_MINOR;
	d->misc.name = "hvcodec";
	d->misc.fops = &hvc_fops;
	the_dev = d;
	ret = misc_register(&d->misc);
	if (ret) {
		the_dev = NULL;
		virtio_reset_device(vdev);
		vdev->config->del_vqs(vdev);
		goto fail;
	}
	mutex_unlock(&the_dev_mu);
	dev_info(&vdev->dev, "Henge codec device: /dev/hvcodec, %u segments, %u contexts\n", d->max_segs,
		 d->max_contexts);
	return 0;
fail:
	mutex_unlock(&the_dev_mu);
	kfree(d);
	return ret;
}

static void hvc_remove(struct virtio_device *vdev)
{
	struct hvc_dev *d = vdev->priv;
	struct hvc_req *r;
	unsigned int len;

	mutex_lock(&the_dev_mu);
	the_dev = NULL;
	mutex_unlock(&the_dev_mu);
	misc_deregister(&d->misc);
	/* the host lets the requests it is running finish, then drops the rest and every context */
	virtio_reset_device(vdev);
	flush_work(&d->done_work);
	mutex_lock(&d->vq_mu);
	d->dead = true;
	while ((r = virtqueue_get_buf(d->vq, &len))) {
		complete(&r->done);
		hvc_req_put(r);
	}
	while ((r = virtqueue_detach_unused_buf(d->vq))) {
		r->failed = true;
		complete(&r->done);
		hvc_req_put(r);
	}
	mutex_unlock(&d->vq_mu);
	vdev->config->del_vqs(vdev);
	kref_put(&d->ref, hvc_dev_free);
}

static const struct virtio_device_id hvc_ids[] = {
	{ HVCD_DEVICE_ID, VIRTIO_DEV_ANY_ID },
	{ 0 },
};
MODULE_DEVICE_TABLE(virtio, hvc_ids);

static struct virtio_driver hvc_driver = {
	.driver.name = KBUILD_MODNAME,
	.id_table = hvc_ids,
	.probe = hvc_probe,
	.remove = hvc_remove,
};
module_virtio_driver(hvc_driver);

MODULE_DESCRIPTION("Henge video codec channel (/dev/hvcodec)");
MODULE_LICENSE("GPL");
MODULE_VERSION("1.0.0");
