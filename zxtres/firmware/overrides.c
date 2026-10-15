/* DeMiSTify firmware hooks for PCAT-286 on the ZXTRES+.

   At start-up the machine is held in reset while the BIOS ROMs and the hard
   disk images are loaded from the root of the microSD card:

     PCAT286.ROM   system BIOS      (ioctl index 0)
     EGA.ROM       EGA BIOS         (ioctl index 3)
     PCAT286A.VHD  IDE 0-0
     PCAT286B.VHD  IDE 0-1

   Names are in 8.3 directory form: eight name characters padded with
   spaces, then the extension, no dot. */

#include "statusword.h"

int LoadROM(const char *fn);
int loadimage(char *filename, int unit);

static const char *bios_name = "PCAT286 ROM";
static const char *ega_name  = "EGA     ROM";
static char vhd0_name[] = "PCAT286AVHD";
static char vhd1_name[] = "PCAT286BVHD";

extern unsigned char romtype;
extern unsigned int statusword;

char *autoboot()
{
	statusword |= 1;          /* status bit 0: hold the machine in reset */
	sendstatus();

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
