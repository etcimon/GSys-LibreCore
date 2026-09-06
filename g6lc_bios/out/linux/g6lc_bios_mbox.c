/* Generated g6lc_bios_mbox.c — Linux miscdriver for /dev/g6lc-bios */
/* Analog: mei / ipmi_si / AppleSMC. Never a network device. */
/* After NET-DELEGATE both KVM faces (SSH+HolyC, HTML+JS ToHtml) ride this mailbox. */
#include <linux/miscdevice.h>
#include <linux/interrupt.h>
#include <linux/io.h>
#include <linux/module.h>
#include <linux/of.h>
#include <linux/platform_device.h>
#include <linux/uaccess.h>
#include "g6lc_bios_mbox.h"

struct g6lc_bios {
	void __iomem *base;
	int irq;
	struct miscdevice misc;
};

static irqreturn_t g6lc_bios_irq(int irq, void *data)
{
	struct g6lc_bios *p = data;
	u32 st = readl(p->base + G6LC_MBOX_STATUS);
	if (!(st & G6LC_MBOX_ST_RSP))
		return IRQ_NONE;
	return IRQ_HANDLED;
}

static ssize_t g6lc_bios_read(struct file *f, char __user *buf, size_t n, loff_t *off)
{
	struct g6lc_bios *p = container_of(f->private_data, struct g6lc_bios, misc);
	u8 tmp[G6LC_MBOX_RSP_BYTES];
	u32 len;
	u32 i;
	(void)off;
	len = readl(p->base + G6LC_MBOX_LENGTH);
	if (len > G6LC_MBOX_RSP_BYTES)
		len = G6LC_MBOX_RSP_BYTES;
	if (n < len)
		len = (u32)n;
	for (i = 0; i < len; i++)
		tmp[i] = readb(p->base + G6LC_MBOX_RSP + i);
	if (copy_to_user(buf, tmp, len))
		return -EFAULT;
	writel(0, p->base + G6LC_MBOX_STATUS);
	return (ssize_t)len;
}

static ssize_t g6lc_bios_write(struct file *f, const char __user *buf, size_t n, loff_t *off)
{
	struct g6lc_bios *p = container_of(f->private_data, struct g6lc_bios, misc);
	u8 tmp[G6LC_MBOX_CMD_BYTES];
	u32 len = n > G6LC_MBOX_CMD_BYTES ? G6LC_MBOX_CMD_BYTES : (u32)n;
	u32 i;
	(void)off;
	if (copy_from_user(tmp, buf, len))
		return -EFAULT;
	for (i = 0; i < len; i++)
		writeb(tmp[i], p->base + G6LC_MBOX_CMD + i);
	writel(len, p->base + G6LC_MBOX_LENGTH);
	writel(1, p->base + G6LC_MBOX_DOORBELL);
	return (ssize_t)len;
}

static const struct file_operations g6lc_bios_fops = {
	.owner = THIS_MODULE,
	.read = g6lc_bios_read,
	.write = g6lc_bios_write,
};

static const struct of_device_id g6lc_bios_mbox_of[] = {
	{ .compatible = "gsys,g6lc-bios-mbox" },
	{ }
};
MODULE_DEVICE_TABLE(of, g6lc_bios_mbox_of);

static int g6lc_bios_probe(struct platform_device *pdev)
{
	struct g6lc_bios *p;
	struct resource *res;
	int ret;
	p = devm_kzalloc(&pdev->dev, sizeof(*p), GFP_KERNEL);
	if (!p)
		return -ENOMEM;
	res = platform_get_resource(pdev, IORESOURCE_MEM, 0);
	p->base = devm_ioremap_resource(&pdev->dev, res);
	if (IS_ERR(p->base))
		return PTR_ERR(p->base);
	p->irq = platform_get_irq(pdev, 0);
	if (p->irq < 0)
		return p->irq;
	ret = devm_request_irq(&pdev->dev, p->irq, g6lc_bios_irq, 0, "g6lc-bios", p);
	if (ret)
		return ret;
	writel(1, p->base + G6LC_MBOX_IRQ_EN);
	p->misc.minor = MISC_DYNAMIC_MINOR;
	p->misc.name = "g6lc-bios";
	p->misc.fops = &g6lc_bios_fops;
	platform_set_drvdata(pdev, p);
	return misc_register(&p->misc);
}

static void g6lc_bios_remove(struct platform_device *pdev)
{
	struct g6lc_bios *p = platform_get_drvdata(pdev);
	misc_deregister(&p->misc);
}

static struct platform_driver g6lc_bios_drv = {
	.probe = g6lc_bios_probe,
	.remove = g6lc_bios_remove,
	.driver = {
		.name = "g6lc-bios-mbox",
		.of_match_table = g6lc_bios_mbox_of,
	},
};

module_platform_driver(g6lc_bios_drv);
/* Dual MIT/GPL if built out-of-tree; this generated stub is MIT in-package. */
MODULE_LICENSE("Dual MIT/GPL");
MODULE_DESCRIPTION("GSys LibreCore BIOS mailbox (/dev/g6lc-bios, irq 3)");
