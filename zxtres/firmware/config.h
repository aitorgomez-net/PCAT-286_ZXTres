/* DeMiSTify firmware configuration for PCAT-286 on the ZXTRES+.
   See DeMiSTify/templates/config.h for the full list of options. */

#ifndef CONFIG_H
#define CONFIG_H

/* The microSD card holds the ROMs and disk images. */
#undef CONFIG_WITHOUT_FILESYSTEM

/* The PS/2 mouse is wired to the core directly, which talks to it itself. */
#undef PS2_MOUSE
#undef PS2_MOUSE_WHEEL
#undef PS2_MOUSE_USERIO
#undef PS2_WRITE

#undef CONFIG_CD

/* Block devices for the core (user_io sd_*): units 0 and 1 are the hard
   disks, PCAT286A.VHD and PCAT286B.VHD, which zxtres_ide_store.sv serves to
   the machine's own IDE device; unit 2 is the CMOS file, PCAT286.CMS; units
   3 and 4 are floppy drives A and B, chosen from the OSD
   (zxtres_fdd_store.sv). The MiST IDE emulation (CONFIG_IDE) is not used:
   the machine has the AO486 IDE device, not the MiST one. DeMiSTify reads a
   unit number in two bits; build_firmware.sh stages diskimg.c with three. */
#define CONFIG_DISKIMG
#define CONFIG_DISKIMG_UNITS 5
#undef CONFIG_IDE

#define CONFIG_FILEBOOKMARKS 16

/* The PS/2 keyboard is wired to the core directly; the controller only
   reads it for the OSD and blocks it from the core while the OSD is open. */
#undef CONFIG_KEYBOARD_SET1
#undef CONFIG_JOYKEYS
#undef CONFIG_JOYKEYS_TOGGLE
#undef CONFIG_SENDKEYS

#define CONFIG_EXTJOYSTICK

/* ROMs and disks are loaded by autoboot() in overrides.c. */
#undef ROM_REQUIRED

#undef CONFIG_SETTINGS

/* The ZXTRES+ has no real-time clock for the controller. */
#undef CONFIG_RTC

/* PCAT uses more than 32 status bits. */
#define CONFIG_STATUSWORD_64BIT

#define CONFIG_AUTOCLOSE_OSD

#undef CONFIG_ARCFILE
#undef CONFIG_ARCFILE_SELECTOR

#undef CONFIG_AUTOSCANDOUBLER

#endif
