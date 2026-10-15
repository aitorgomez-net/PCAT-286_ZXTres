/* DeMiSTify firmware hooks for PCAT-286 on the ZXTRES+.

   At start-up the machine is held in reset while the BIOS ROMs and the hard
   disk images are loaded from the root of the microSD card:

     PCAT286.ROM   system BIOS      (ioctl index 0)
     EGA.ROM       EGA BIOS         (ioctl index 3)
     PCAT286A.VHD  IDE 0-0
     PCAT286B.VHD  IDE 0-1

   PCAT286.CMS, a 512-byte file, is mounted first as block device 2: the
   core restores the CMOS from it before the BIOS runs and writes it back
   when the BIOS changes the CMOS (zxtres/rtl/zxtres_cmos_store.sv). Without
   the file the CMOS is not kept.

   Names are in 8.3 directory form: eight name characters padded with
   spaces, then the extension, no dot. */

#include "statusword.h"
#include "diskimg.h"

int LoadROM(const char *fn);
void OpenHardfile(const char *filename, int unit);

static const char *bios_name = "PCAT286 ROM";
static const char *ega_name  = "EGA     ROM";
static char vhd0_name[] = "PCAT286AVHD";
static char vhd1_name[] = "PCAT286BVHD";
static const unsigned char cmos_name[] = "PCAT286 CMS";

#define CMOS_UNIT 'M'
#define CMOS_DISKIMG 2

/* DeMiSTify requires this override when IDE and block devices are both
   enabled: '0'/'1' are the IDE units, CMOS_UNIT the CMOS file. */
int loadimage(char *filename, int unit)
{
	switch(unit)
	{
		case 0:
			return(LoadROM(filename));
		case '0':
		case '1':
			OpenHardfile(filename, unit - '0');
			return(1);
		case CMOS_UNIT:
			diskimg_mount(0, CMOS_DISKIMG);
			return(diskimg_mount((const unsigned char *)filename, CMOS_DISKIMG));
	}
	return(0);
}

extern unsigned char romtype;
extern unsigned int statusword;

char *autoboot()
{
	statusword |= 1;          /* status bit 0: hold the machine in reset */
	sendstatus();

	loadimage((char *)cmos_name, CMOS_UNIT);

	romtype = 0;
	LoadROM(bios_name);
	romtype = 3;
	LoadROM(ega_name);

	loadimage(vhd0_name, '0');
	loadimage(vhd1_name, '1');

	statusword &= ~1;
	sendstatus();
	return 0;
}
