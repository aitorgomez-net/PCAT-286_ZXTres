/* DeMiSTify firmware hooks for PCAT-286 on the ZXTRES+.

   The core's own files live in the folder PCAT286 at the root of the
   microSD card, or in the root itself when there is no such folder:

     PCAT286.ROM   system BIOS      (ioctl index 0)
     EGA.ROM       EGA BIOS         (ioctl index 3)

   Those two are the defaults: the OSD page BIOS chooses any other file of
   the card for either, which the machine takes at once (it is reset), and
   PCAT286.CFG keeps the choice.
     PCAT286.CMS   the CMOS
     PCAT286.CFG   the saved settings

   The default ROMs are also looked for in the root. At start-up the machine
   is held in reset while they are loaded.

   PCAT286.CMS, a 512-byte file, is mounted first as block device 2: the
   core restores the CMOS from it before the BIOS runs and writes it back
   when the BIOS changes the CMOS (zxtres/rtl/zxtres_cmos_store.sv). Without
   the file the CMOS is not kept.

   Disk images are chosen from the OSD, from any folder of the card: "S0" and
   "S1" are the hard disks, block devices 0 and 1 (zxtres/rtl/
   zxtres_ide_store.sv), "S3" and "S4" the floppy drives A and B, block
   devices 3 and 4 (zxtres/rtl/zxtres_fdd_store.sv). The machine needs a
   reset for the BIOS to detect a new hard disk. The drives start empty.

   PCAT286.CFG, a 512-byte file, keeps the OSD settings and the path of the
   image in each drive: the OSD page Settings saves them there and the
   start-up loads them. The file has to exist (the firmware cannot create
   files); without it, or with its sector zeroed, the defaults of the OSD
   apply.

   Names are in 8.3 directory form: eight name characters padded with
   spaces, then the extension, no dot. */

#include <string.h>

#include "statusword.h"
#include "diskimg.h"
#include "minfat.h"
#include "swap_le.h"
#include "menu.h"
#include "osd.h"
#include "timer.h"

int LoadROM(const char *fn);

extern unsigned int statusword;
extern unsigned int statusword_high;
extern unsigned char romtype;
extern uint32_t root_directory_cluster;
extern struct menu_entry menu[];
extern int menupage;
extern int menuindex;
void buildmenu(int set);
void cycle(int row);
void toggle(int row);

static const char bios_name[] = "PCAT286 ROM";
static const char ega_name[]  = "EGA     ROM";
static const char home_name[] = "PCAT286    ";
static const unsigned char cmos_name[] = "PCAT286 CMS";
static const char cfg_name[] = "PCAT286 CFG";

#define CMOS_UNIT 'M'
#define BIOS_UNIT 'B'           /* system BIOS and EGA BIOS, chosen from the OSD */
#define EGA_UNIT 'E'
#define RESET_BIT 1             /* status bit 0: hold the machine in reset */
#define CMOS_DISKIMG 2
#define FLOPPY_DISKIMG 3        /* block device of unit '3'; '4' follows */

/* The folder of the core's files: its cluster, 0 for the root. */
static unsigned int homedir;

/* Names of the images mounted on units '0'..'4', and of the BIOS files
   (slots 5 and 6), shown by the menu after the label of each file selector
   entry ("NAME.EXT", empty when nothing is mounted). */
#define SLOTS 7
static char imgnames[SLOTS][13];

/* The same, as mounted: the 8.3 name, empty when the drive is, and the
   directory it came from, for PCAT286.CFG. Slot 2 is not used. */
static char mountname[SLOTS][12];
static unsigned int mountdir[SLOTS];

/* 1 while autoboot() loads the files, with the machine held in reset. */
static int booting;

/* The slot of a unit, -1 for none. */
static int slot_of(int unit)
{
	if(unit >= '0' && unit <= '4')
		return(unit - '0');
	return(unit == BIOS_UNIT ? 5 : unit == EGA_UNIT ? 6 : -1);
}

/* Append an 8.3 name to d as NAME.EXT; returns the new end. */
static char *put83(char *d, const char *name)
{
	int i;

	for(i = 0; i < 8 && name[i] != ' '; ++i)
		*d++ = name[i];
	if(name[8] != ' ')
	{
		*d++ = '.';
		for(i = 8; i < 11 && name[i] != ' '; ++i)
			*d++ = name[i];
	}
	*d = 0;
	return(d);
}

static void setimagename(int unit, const char *name, int mounted)
{
	int u = slot_of(unit);

	imgnames[u][0] = 0;
	if(name && mounted)
		put83(imgnames[u], name);
}

/* Called by the menu for the S entries: the text to show after the label. */
const char *imagename(int unit)
{
	int u = slot_of(unit);

	if(u < 0)
		return(0);
	return(imgnames[u][0] ? imgnames[u] : "(none)");
}

/* '0' and '1' are the hard disks, CMOS_UNIT the CMOS file, '3' and '4' the
   floppy drives. The unit is dismounted first, as the menu does; a name of
   zero leaves it empty. BIOS_UNIT and EGA_UNIT are the ROM files: they load
   in place of the current ones, so a name of zero (the menu dismounting the
   unit) changes nothing; the machine is reset around the transfer, unless
   autoboot() is loading, which holds it already. */
int loadimage(char *filename, int unit)
{
	int size;

	switch(unit)
	{
		case 0:
			return(LoadROM(filename));
		case '0':
		case '1':
		case '3':
		case '4':
		{
			int u = unit - '0';
			int dev = (unit < '3') ? u : FLOPPY_DISKIMG + unit - '3';

			diskimg_mount(0, dev);
			size = filename ? diskimg_mount((const unsigned char *)filename, dev) : 0;
			setimagename(unit, filename, size);
			mountname[u][0] = 0;
			if(size)
			{
				memcpy(mountname[u], filename, 11);
				mountname[u][11] = 0;
				mountdir[u] = CurrentDirectory();
			}
			return(size);
		}
		case BIOS_UNIT:
		case EGA_UNIT:
		{
			int u = slot_of(unit);

			if(!filename)
				return(0);
			if(!booting)
			{
				statusword |= RESET_BIT;
				sendstatus();
			}
			romtype = unit == BIOS_UNIT ? 0 : 3;
			size = LoadROM(filename);
			if(!booting)
			{
				statusword &= ~RESET_BIT;
				sendstatus();
			}
			if(size)
			{
				setimagename(unit, filename, 1);
				memcpy(mountname[u], filename, 11);
				mountname[u][11] = 0;
				mountdir[u] = CurrentDirectory();
			}
			return(size);
		}
		case CMOS_UNIT:
			diskimg_mount(0, CMOS_DISKIMG);
			return(diskimg_mount((const unsigned char *)filename, CMOS_DISKIMG));
	}
	return(0);
}

/* Paths of images, as PCAT286.CFG keeps them: the folders from the root and
   the file, as NAME.EXT separated by '/' ("DOS/DOS622.IMG"). */

#define PATH_SIZE 80            /* PCAT286.CFG version 3; version 2 had 112 */
#define PATH_SIZE_V2 112
#define PATH_DEPTH 6

/* Length of the NAME.EXT form of an 8.3 name. */
static int len83(const char *name)
{
	char tmp[14];

	return((int)(put83(tmp, name) - tmp));
}

static unsigned int entry_cluster(DIRENTRY *p)
{
	unsigned int cluster = ConvBB_LE(p->StartCluster);

	if(fat32)
		cluster |= (ConvBB_LE(p->HighCluster) & 0x0FFF) << 16;
	return(cluster == root_directory_cluster ? 0 : cluster);
}

/* Find folder dir in its parent: copy its 8.3 name to name and return the
   parent's cluster (0 for the root), or -1 if it cannot be traced. */
static int parent_of(unsigned int dir, char *name)
{
	DIRENTRY *p = 0;
	unsigned int parent;

	ChangeDirectoryByCluster(dir);
	while((p = NextDirEntry(p == 0, 0)))
		if((p->Attributes & ATTR_DIRECTORY) && !strncmp((const char *)p->Name, "..         ", 11))
			break;
	if(!p)
		return(-1);
	parent = entry_cluster(p);
	ChangeDirectoryByCluster(parent);
	p = 0;
	while((p = NextDirEntry(p == 0, 0)))
		if((p->Attributes & ATTR_DIRECTORY) && p->Name[0] != '.' && entry_cluster(p) == dir)
		{
			memcpy(name, p->Name, 11);
			return(parent);
		}
	return(-1);
}

/* The path of the image in unit u, empty when there is none or it cannot be
   traced. Changes the current directory. */
static void image_path(int u, char *path)
{
	char names[PATH_DEPTH][11];
	unsigned int dir = mountdir[u];
	int depth = 0;
	int parent;
	int length;

	path[0] = 0;
	if(!mountname[u][0])
		return;
	while(dir)
	{
		if(depth == PATH_DEPTH || (parent = parent_of(dir, names[depth])) < 0)
			return;
		++depth;
		dir = parent;
	}
	/* Whatever does not fit in PATH_SIZE is not kept. */
	length = len83(mountname[u]) + 1;
	for(parent = 0; parent < depth; ++parent)
		length += len83(names[parent]) + 1;
	if(length > PATH_SIZE)
		return;
	while(depth--)
	{
		path = put83(path, names[depth]);
		*path++ = '/';
	}
	put83(path, mountname[u]);
}

/* The 8.3 form of the path element at s, up to '/' or the end; returns what
   follows it. */
static const char *get83(const char *s, char *name)
{
	int i = 0;

	memset(name, ' ', 11);
	name[11] = 0;
	for(; *s && *s != '/' && *s != '.'; ++s)
		if(i < 8)
			name[i++] = *s;
	if(*s == '.')
		for(i = 8, ++s; *s && *s != '/'; ++s)
			if(i < 11)
				name[i++] = *s;
	return(s);
}

/* Mount a unit from a path (1 if it was); an empty path or one that is not
   on the card leaves the unit empty (the BIOS files, the ones it had). Either way the core is told, which the hard disk
   store needs for both its units before it answers the BIOS. */
static int mount_path(int unit, const char *path)
{
	char name[12];
	DIRENTRY *p;

	ChangeDirectoryByCluster(0);
	while(*path)
	{
		path = get83(path, name);
		if(!*path)
		{
			if(loadimage(name, unit))
				return(1);
			break;
		}
		++path;
		if(!(p = GetDirEntry(name)) || !(p->Attributes & ATTR_DIRECTORY))
			break;
		ChangeDirectory(p);
	}
	loadimage(0, unit);
	return(0);
}

/* PCAT286.CFG, one sector:
     0   "PCAT"
     4   version (3; version 2 had no BIOS paths and 112-byte paths)
     8   status word, low 32 bits (little endian)
     12  status word, high 32 bits
     32  path of the image in hard disk 0 (PATH_SIZE bytes, ending in a zero;
         empty for none), then hard disk 1, floppy A, floppy B, system BIOS
         and EGA BIOS */

#define CFG_SIZE 512
#define CFG_VERSION 3
#define CFG_PATHS 32
#define CFG_UNITS 6

static const char cfg_units[CFG_UNITS] = { '0', '1', '3', '4', BIOS_UNIT, EGA_UNIT };

static fileTYPE cfgfile;
static unsigned int cfg_words[CFG_SIZE / 4];
#define cfg_bytes ((unsigned char *)cfg_words)
static int cfg_state;           /* 0 no file, 1 file without settings, 2 settings saved */

static void put32(unsigned char *p, unsigned int v)
{
	p[0] = v;
	p[1] = v >> 8;
	p[2] = v >> 16;
	p[3] = v >> 24;
}

static unsigned int get32(const unsigned char *p)
{
	return((unsigned int)p[0] | ((unsigned int)p[1] << 8)
		| ((unsigned int)p[2] << 16) | ((unsigned int)p[3] << 24));
}

/* Read PCAT286.CFG into cfg_bytes; 1 if it holds settings. */
static int cfg_load(void)
{
	int i;

	ChangeDirectoryByCluster(homedir);
	cfg_state = 0;
	if(FileOpen(&cfgfile, cfg_name) && FileReadSector(&cfgfile, cfg_bytes))
	{
		cfg_state = 1;
		if(!memcmp(cfg_bytes, "PCAT", 4) && cfg_bytes[4] == 2)
		{
			/* The older layout: four longer paths. Those that do not fit in
			   the new ones are lost; the BIOS files were not kept. */
			for(i = 0; i < 4; ++i)
			{
				unsigned char *from = cfg_bytes + CFG_PATHS + i * PATH_SIZE_V2;
				unsigned char *to = cfg_bytes + CFG_PATHS + i * PATH_SIZE;
				int n = 0;
				int j;

				from[PATH_SIZE_V2 - 1] = 0;
				while(from[n])
					++n;
				if(n >= PATH_SIZE)
					n = -1;
				for(j = 0; j <= n; ++j)       /* the zero too; to is never after from */
					to[j] = from[j];
				if(n < 0)
					to[0] = 0;
			}
			for(i = CFG_PATHS + 4 * PATH_SIZE; i < CFG_SIZE; ++i)
				cfg_bytes[i] = 0;
			cfg_bytes[4] = CFG_VERSION;
		}
		if(!memcmp(cfg_bytes, "PCAT", 4) && cfg_bytes[4] == CFG_VERSION)
		{
			for(i = 0; i < CFG_UNITS; ++i)
				cfg_bytes[CFG_PATHS + (i + 1) * PATH_SIZE - 1] = 0;
			cfg_state = 2;
		}
	}
	return(cfg_state == 2);
}

/* Write the current settings, or a blank sector to forget them. */
static int cfg_store(int blank)
{
	unsigned int dir = CurrentDirectory();
	int ok = 0;
	int i;

	memset(cfg_bytes, 0, CFG_SIZE);
	if(!blank)
	{
		memcpy(cfg_bytes, "PCAT", 4);
		cfg_bytes[4] = CFG_VERSION;
		put32(cfg_bytes + 8, statusword & ~RESET_BIT);
		put32(cfg_bytes + 12, statusword_high);
		for(i = 0; i < CFG_UNITS; ++i)
			image_path(slot_of(cfg_units[i]), (char *)cfg_bytes + CFG_PATHS + i * PATH_SIZE);
	}
	ChangeDirectoryByCluster(homedir);
	if(FileOpen(&cfgfile, cfg_name) && FileWriteSector(&cfgfile, cfg_bytes))
	{
		ok = 1;
		cfg_state = blank ? 1 : 2;
	}
	ChangeDirectoryByCluster(dir);
	return(ok);
}

/* A default ROM (BIOS_UNIT or EGA_UNIT) from the folder of the core's files,
   else from the root. */
static void load_rom(const char *name, int unit)
{
	ChangeDirectoryByCluster(homedir);
	if(!loadimage((char *)name, unit) && homedir)
	{
		ChangeDirectoryByCluster(0);
		loadimage((char *)name, unit);
	}
}

char *autoboot()
{
	DIRENTRY *p;
	int i;

	booting = 1;
	statusword |= RESET_BIT;  /* hold the machine in reset */
	sendstatus();

	ChangeDirectoryByCluster(0);
	p = GetDirEntry(home_name);
	homedir = (p && (p->Attributes & ATTR_DIRECTORY)) ? entry_cluster(p) : 0;

	ChangeDirectoryByCluster(homedir);
	loadimage((char *)cmos_name, CMOS_UNIT);

	if(cfg_load())
	{
		statusword = get32(cfg_bytes + 8) | RESET_BIT;
		statusword_high = get32(cfg_bytes + 12);
		sendstatus();
	}

	/* The BIOS files kept in the settings, else the default ones. */
	for(i = 4; i < CFG_UNITS; ++i)
		if(!mount_path(cfg_units[i],
				cfg_state == 2 ? (const char *)cfg_bytes + CFG_PATHS + i * PATH_SIZE : ""))
			load_rom(cfg_units[i] == BIOS_UNIT ? bios_name : ega_name, cfg_units[i]);

	for(i = 0; i < 4; ++i)
		mount_path(cfg_units[i],
			cfg_state == 2 ? (const char *)cfg_bytes + CFG_PATHS + i * PATH_SIZE : "");
	ChangeDirectoryByCluster(0);

	booting = 0;
	statusword &= ~RESET_BIT;
	sendstatus();
	buildmenu(1);             /* init() drew it before the images and settings */
	return 0;
}

/* Settings page: "T1" saves the settings and "T2" returns to the defaults.
   Both ask first, on a page of their own (MENUPAGE_CONFIRM, built here and
   selected by a hook in main.c, see expand_demistify_osd.py). */

#define SAVE_BIT 1
#define DEFAULTS_BIT 2
#define MENUPAGE_CONFIRM 27     /* the same value as in main.c */

static int confirm_bit;

/* The rows of the confirmation page; returns how many. */
int confirm_page(struct menu_entry *m)
{
	void confirm_yes(int row);
	void confirm_no(int row);

	strcpy(m[0].label, confirm_bit == SAVE_BIT ? "Save settings now?" : "Reset all settings?");
	m[0].action = 0;
	strcpy(m[1].label, "Yes");
	m[1].action = MENU_ACTION(&confirm_yes);
	strcpy(m[2].label, "No");
	m[2].action = MENU_ACTION(&confirm_no);
	return(3);
}

static void confirm_close(char *message)
{
	menupage = 0;
	buildmenu(1);
	Menu_Message(message, 1500);
}

void confirm_no(int row)
{
	menupage = 0;
	buildmenu(1);
}

/* ESC, as on MiSTer: out of a page to the main page, from the main page it
   closes the OSD. Called by Menu_Run() (see expand_demistify_osd.py). */
void osd_escape(void)
{
	if(menupage)
	{
		menupage = 0;
		menuindex = 0;
		buildmenu(1);
	}
	else
		Menu_ShowHide(0);
}

void confirm_yes(int row)
{
	unsigned int t;

	if(confirm_bit == SAVE_BIT)
	{
		confirm_close(cfg_store(0) ? "Settings saved" : "Cannot write PCAT286.CFG");
		return;
	}

	/* Defaults: every option back to its first value, forget the saved
	   file, and reset the machine so that they all apply. */
	statusword = RESET_BIT;
	statusword_high = 0;
	sendstatus();
	cfg_store(1);
	booting = 1;              /* the machine is held already */
	load_rom(bios_name, BIOS_UNIT);
	load_rom(ega_name, EGA_UNIT);
	booting = 0;
	t = GetTimer(200);
	while(!CheckTimer(t))
		;
	statusword &= ~RESET_BIT;
	sendstatus();
	confirm_close("Defaults restored");
}

/* Triggers: the Settings entries open the confirmation page, any other
   trigger (Reset) is the standard one. */
void toggle(int row)
{
	int bit = menu[row].u.opt.shift;

	if(bit == SAVE_BIT || bit == DEFAULTS_BIT)
	{
		confirm_bit = bit;
		menupage = MENUPAGE_CONFIRM;
		buildmenu(1);
		return;
	}
	cycle(row);
	cycle(row);
	Menu_ShowHide(0);
}

/* The look of the menu.

   The menu entries come from main.c; the row kinds are told by their actions
   (cycle for an option, toggle for a trigger, submenu for a page,
   fileselector for an image, ...) and drawn here: icons, colours, the value
   column, the information and help lines. A code of 1-8 inside a label
   selects the colour of what follows (8 is white) and takes no column; a
   label starting with a code of 88h or more starts with an icon.

   The columns: 0 icon or blank, 1-15 name, 16 the left arrow of the row under
   the cursor, 17-30 value, then the right arrow. */

#define C_CYAN 1
#define C_YELLOW 2
#define C_GREEN 3
#define C_RED 4
#define C_ORANGE 5
#define C_GREY 6
#define C_LBLUE 7
#define C_WHITE 8

#define ICON_LEFT 0x80
#define ICON_RIGHT 0x81
#define ICON_CHECK 0x84
#define ICON_CROSS 0x85
#define ICON_ELLIPSIS 0x87
#define ICON_RULE 0x88
#define ICON_FLOPPY 0x89
#define ICON_DISK 0x8A
#define ICON_SPEAKER 0x8B
#define ICON_MONITOR 0x8C
#define ICON_JOYSTICK 0x8D
#define ICON_GEAR 0x8F
#define ICON_INFO 0x90
#define ICON_FOLDER 0x91
#define ICON_FILE 0x92

#define OPT_POSITION 11         /* status bits 11-13: where the box sits */
#define OPT_CPU 57              /* the options shown on the information line */
#define OPT_RAM 46              /* 3 bits: 4, 8, 16, 1, 2 MB */
#define OPT_MONITOR 44

#define MENUPAGE_INFO 26        /* the same value as in main.c */

extern int menu_message;
void submenu(int row);
void fileselector(int row);
void selectrom(int row);
void selectdir(int row);
void confirm_yes(int row);
void confirm_no(int row);

static int rowcol;

static void pc(unsigned char c)
{
	OsdPutChar(c);
	if(c > C_WHITE)
		++rowcol;
}

static void ps(const char *s)
{
	while(*s)
		pc(*s++);
}

static void psn(const char *s, int n)
{
	while(*s && n-- > 0)
		pc(*s++);
}

static void pad(int col)
{
	while(rowcol < col)
		pc(' ');
}

/* Columns a string takes: the colour codes take none. */
static int visible(const char *s)
{
	int n = 0;

	while(*s)
		if((unsigned char)*s++ > C_WHITE)
			++n;
	return(n);
}

/* "Name: value" of an option row. */
static void draw_option(const char *l, int sel)
{
	const char *v = l;

	while(*v && !(v[0] == ':' && v[1] == ' '))
		++v;
	pc(' ');
	if(!*v)
	{
		ps(l);
		return;
	}
	psn(l, (int)(v - l));
	pad(16);
	if(sel)
	{
		pc(C_LBLUE);
		pc(ICON_LEFT);
	}
	else
		pc(' ');
	pc(C_CYAN);
	psn(v + 2, 13);
	if(sel)
	{
		pc(' ');
		pc(C_LBLUE);
		pc(ICON_RIGHT);
	}
}

/* A trigger (Reset, Save settings, ...) is a word in a colour. */
static void draw_trigger(const char *l, int bit)
{
	pc(bit == SAVE_BIT ? C_YELLOW : C_RED);
	pc(' ');
	ps(l);
}

/* A page: icon, title, arrow at the right edge. */
static void draw_page(const char *l, int page)
{
	pc(C_LBLUE);
	pc(page == 1 ? ICON_MONITOR : page == 2 ? ICON_SPEAKER : page == 3 ? ICON_GEAR
		: page == 4 ? ICON_JOYSTICK : page == MENUPAGE_INFO ? ICON_INFO : ICON_FOLDER);
	while(*l && !(l[0] == ' ' && (unsigned char)l[1] == ICON_RIGHT))
		pc(*l++);
	pad(31);
	pc(ICON_RIGHT);
}

/* An image: "Floppy A: NAME.EXT >" with the name in the value column. */
static void draw_image(const char *l, int unit)
{
	const char *v = l;
	int none;

	pc(C_ORANGE);
	pc(unit == '0' || unit == '1' ? ICON_DISK : unit == '3' || unit == '4' ? ICON_FLOPPY : ICON_FILE);
	pc(C_WHITE);
	while(*v && *v != ':')
		++v;
	if(*v)
		++v;
	psn(l, (int)(v - l));
	while(*v == ' ')
		++v;
	pad(17);
	none = v[0] == '(';
	pc(none ? C_GREY : C_GREEN);
	while(*v && !(v[0] == ' ' && (unsigned char)v[1] == ICON_RIGHT) && rowcol < 30)
		pc(*v++);
	pad(31);
	pc(C_LBLUE);
	pc(ICON_RIGHT);
}

/* "L,Title;" of the configuration string: a rule with the title. */
static void draw_rule(const char *t)
{
	pc(C_GREY);
	pc(ICON_RULE);
	pc(ICON_RULE);
	pc(' ');
	ps(t);
	pc(' ');
	while(rowcol < 32)
		pc(ICON_RULE);
}

/* The last row: the way out, or a message. */
static void draw_footer(const char *l)
{
	if(menu_message)
	{
		int bad = 0, busy = 0, n = 0;
		const char *s;

		for(s = l; *s; ++s, ++n)
		{
			if((s[0] == 'a' && s[1] == 'i' && s[2] == 'l') || (s[0] == 'a' && s[1] == 'n' && s[2] == 'n'))
				bad = 1;
			if(s[0] == '.' && s[1] == '.' && s[2] == '.')
				busy = 1;
		}
		if(!busy)
			n += 2;
		pad((32 - n) / 2);
		pc(bad ? C_RED : busy ? C_YELLOW : C_GREEN);
		if(!busy)
		{
			pc(bad ? ICON_CROSS : ICON_CHECK);
			pc(' ');
		}
		ps(l);
	}
	else if(menupage)
	{
		pc(C_GREY);
		pc(ICON_LEFT);
		ps(" Back");
	}
	else
	{
		pc(C_ORANGE);
		pc(ICON_CROSS);
		ps(" Exit");
	}
}

void Menu_DrawRow(int row, int selected, struct menu_entry *m)
{
	const char *l = m->label ? m->label : "";
	long a = m->action;

	OsdWriteStart(row, selected, 0);
	rowcol = 0;
	if(row == OSDNLINE - 1)
		draw_footer(l);
	else if(!*l)
		;
	else if(a == MENU_ACTION(&cycle))
		draw_option(l, selected);
	else if(a == MENU_ACTION(&toggle))
		draw_trigger(l, m->u.opt.shift);
	else if(a == MENU_ACTION(&submenu))
		draw_page(l, m->u.menu.page);
	else if(a == MENU_ACTION(&fileselector))
		draw_image(l, m->u.file.unit);
	else if(a == MENU_ACTION(&confirm_yes))
	{
		pc(C_GREEN);
		pc(ICON_CHECK);
		pc(' ');
		ps(l);
	}
	else if(a == MENU_ACTION(&confirm_no))
	{
		pc(C_RED);
		pc(ICON_CROSS);
		pc(' ');
		ps(l);
	}
	else if(!a && (unsigned char)l[0] == ICON_RULE)
		draw_rule(l + 1);
	else
	{
		if((unsigned char)l[0] < ICON_RULE)
			pc(' ');
		ps(l);
	}
	OsdWriteEnd();
}

/* Left and right change the option under the cursor. */
static void statusword_put(unsigned int shift, unsigned int mask, unsigned int v)
{
	if(shift >= 32)
		statusword_high = (statusword_high & ~(mask << (shift - 32))) | (v << (shift - 32));
	else
		statusword = (statusword & ~(mask << shift)) | (v << shift);
}

int Menu_AdjustRow(int row, int dir)
{
	unsigned int shift, mask, limit, v;

	if(menu[row].action != MENU_ACTION(&cycle))
		return(0);
	shift = menu[row].u.opt.shift;
	mask = menu[row].u.opt.val;
	limit = menu[row].u.opt.limit;
	v = statusword_get(shift, mask);
	if(dir > 0)
		v = (v + 1 >= limit) ? 0 : v + 1;
	else
		v = v ? v - 1 : limit - 1;
	statusword_put(shift, mask, v);
	sendstatus();
	buildmenu(0);
	return(1);
}

static const char *const cpu_names[8] = {"MAX", "6 MHz", "8 MHz", "10 MHz", "12.5 MHz", "16 MHz", "20 MHz", "25 MHz"};
static const char *const monitor_names[3] = {"CGA", "ECD", "MDA"};
static const char *const monitor_models[3] = {"5153/CGA", "5154/ECD", "5151/MDA"};

static const char *cpu_name(void)
{
	return(cpu_names[statusword_get(OPT_CPU, 7)]);
}

static const char *const ram_names[5] = {"4 MB", "8 MB", "16 MB", "1 MB", "2 MB"};

static const char *ram_name(void)
{
	int v = statusword_get(OPT_RAM, 7);

	return(ram_names[v > 4 ? 0 : v]);
}

static int monitor_index(void)
{
	int v = statusword_get(OPT_MONITOR, 3);

	return(v > 2 ? 0 : v);
}

static void centre_row(int row, const char *text)
{
	OsdWriteStart(row, 0, 0);
	rowcol = 0;
	pad((32 - visible(text)) / 2);
	ps(text);
	OsdWriteEnd();
}

/* The box position, the information line under the title, and the help line
   at the foot. */
void Menu_DrawExtras(int selected, struct menu_entry *m)
{
	char text[48];
	const struct menu_entry *e = &m[selected];
	long a = e->action;
	const char *help = "";
	int pos = statusword_get(OPT_POSITION, 7);

	OsdSetPosition(pos > 4 ? 0 : pos);

	strcpy(text, "\006CPU \001");
	strcat(text, cpu_name());
	strcat(text, "\006  RAM \001");
	strcat(text, ram_name());
	strcat(text, "\006  \001");
	strcat(text, monitor_names[monitor_index()]);
	centre_row(OSDNLINE, text);

	if(menu_message)
		help = "";
	else if(selected == OSDNLINE - 1)
		help = menupage ? "\006Enter: back" : "\006Enter: close";
	else if(a == MENU_ACTION(&cycle))
		help = "\002\200\201\006 change   Enter: next";
	else if(a == MENU_ACTION(&toggle) || a == MENU_ACTION(&confirm_yes) || a == MENU_ACTION(&confirm_no))
		help = "\006Enter: confirm";
	else if(a == MENU_ACTION(&submenu))
		help = "\006Enter: open";
	else if(a == MENU_ACTION(&fileselector))
		help = "\006Enter: choose a file";
	else if(a == MENU_ACTION(&selectdir))
		help = "\006Enter: open the folder";
	else if(a == MENU_ACTION(&selectrom))
		help = "\006Enter: load";
	centre_row(OSDNLINE + 1, help);
}

/* A line of the file selector: icon, NAME.EXT, size in the right columns. */
static char *putnum(char *o, unsigned int v)
{
	static const unsigned int p10[4] = {1000, 100, 10, 1};
	int i, started = 0;

	for(i = 0; i < 4; ++i)
	{
		int d = 0;

		while(v >= p10[i])
		{
			v -= p10[i];
			++d;
		}
		if(d || started || i == 3)
		{
			*o++ = '0' + d;
			started = 1;
		}
	}
	return(o);
}

static int format_size(char *o, unsigned int b)
{
	char *s = o;

	if(b >= (1u << 30))
	{
		o = putnum(o, b >> 30);
		*o++ = '.';
		*o++ = '0' + ((((b & 0x3fffffff) >> 20) * 10) >> 10);
		*o++ = 'G';
	}
	else if(b >= (1u << 20))
	{
		unsigned int w = b >> 20;

		o = putnum(o, w);
		if(w < 10)
		{
			*o++ = '.';
			*o++ = '0' + (((b & 0xfffff) * 10) >> 20);
		}
		*o++ = 'M';
	}
	else if(b >= 1024)
	{
		o = putnum(o, b >> 10);
		*o++ = 'K';
	}
	else
	{
		o = putnum(o, b);
		*o++ = 'B';
	}
	*o = 0;
	return((int)(o - s));
}

void fileline(char *dst, DIRENTRY *p, int isdir)
{
	char name[24];
	char size[8];
	const unsigned char *raw = (const unsigned char *)p->Name;
	int n = 0, vis, len, i, sl = 0;

	if(longfilename[0])
	{
		for(i = 0; i < 22 && longfilename[i]; ++i)
			name[i] = (longfilename[i] < ' ' || longfilename[i] > '~') ? '?' : longfilename[i];
		if(i == 22 && longfilename[22])
			name[21] = ICON_ELLIPSIS;
		len = i;
	}
	else
	{
		len = 0;
		for(i = 0; i < 8 && raw[i] != ' '; ++i)
			name[len++] = raw[i];
		if(raw[8] != ' ')
		{
			name[len++] = '.';
			for(i = 8; i < 11 && raw[i] != ' '; ++i)
				name[len++] = raw[i];
		}
	}
	name[len] = 0;

	dst[n++] = isdir ? ICON_FOLDER : ICON_FILE;
	dst[n++] = isdir ? C_LBLUE : C_WHITE;
	strcpy(dst + n, name);
	n += len;
	vis = 1 + len;
	if(!isdir)
	{
		sl = format_size(size, p->FileSize);
		while(vis < 31 - sl)
		{
			dst[n++] = ' ';
			++vis;
		}
		dst[n++] = C_GREY;
		strcpy(dst + n, size);
		n += sl;
	}
	dst[n] = 0;
}

/* The Info page: what the core is and what it has mounted. */
static void inforow(struct menu_entry *m, int i, const char *name, int color, const char *value)
{
	char *d = m[i].label;
	int n = 2, vis;

	d[0] = ' ';
	d[1] = C_GREY;
	strncpy(d + n, name, 8);
	d[n + 8] = 0;
	n += strlen(d + n);
	vis = n - 1;
	while(vis < 11)
	{
		d[n++] = ' ';
		++vis;
	}
	d[n++] = color;
	strncpy(d + n, value, 20);
	d[n + 20] = 0;
	m[i].action = 0;
}

static void inforule(struct menu_entry *m, int i, const char *title)
{
	m[i].label[0] = ICON_RULE;
	strncpy(m[i].label + 1, title, 20);
	m[i].label[21] = 0;
	m[i].action = 0;
}

int info_page(struct menu_entry *m)
{
	int i = 0;
	const char *image;

	inforule(m, i++, "Core");
	inforow(m, i++, "System", C_WHITE, "PCAT-286 AT clone");
	inforow(m, i++, "Board", C_WHITE, "ZXTRES+");
	inforow(m, i++, "Built", C_WHITE, __DATE__);
	inforule(m, i++, "Machine");
	inforow(m, i++, "CPU", C_CYAN, cpu_name());
	inforow(m, i++, "RAM", C_CYAN, ram_name());
	inforow(m, i++, "Monitor", C_CYAN, monitor_models[monitor_index()]);
	inforule(m, i++, "Storage");
	image = imagename('3');
	inforow(m, i++, "Floppy A", image[0] == '(' ? C_GREY : C_GREEN, image);
	image = imagename('4');
	inforow(m, i++, "Floppy B", image[0] == '(' ? C_GREY : C_GREEN, image);
	image = imagename('0');
	inforow(m, i++, "Disk 0", image[0] == '(' ? C_GREY : C_GREEN, image);
	image = imagename('1');
	inforow(m, i++, "Disk 1", image[0] == '(' ? C_GREY : C_GREEN, image);
	inforow(m, i++, "Settings", cfg_state == 2 ? C_GREEN : cfg_state ? C_GREY : C_RED,
		cfg_state == 2 ? "saved on the card" : cfg_state ? "none saved" : "PCAT286.CFG missing");
	return(i);
}
