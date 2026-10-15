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

/* Floppy images: not yet (see zxtres/PORT.md). */
#undef CONFIG_DISKIMG

/* Hard disks: MiST IDE emulation from VHD files, two units (0-0, 0-1). */
#define CONFIG_IDE
#define CONFIG_IDE_UNITS 2
#define CONFIG_IDE_PC_HD

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
