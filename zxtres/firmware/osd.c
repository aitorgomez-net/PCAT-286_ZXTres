/*
-- OSD drawing code, borrowed from MiST's firmware.
-- Modified for PCAT-286 on the ZXTRES+: rows are sent as character codes for
-- the character-grid OSD in zxtres/rtl/zxtres_osd.sv, not as pixel columns.
-- Replaces DeMiSTify/firmware/osd.c in the build (zxtres/firmware/overrides.mk).
-- Copyright (c) 2005 - 2020 by Dennis van Weeren, Jakub Bednarski,
-- Till Harbaum and others.

-- This program is free software: you can redistribute it and/or modify
-- it under the terms of the GNU General Public License as published by
-- the Free Software Foundation, either version 3 of the License, or
-- (at your option) any later version.

-- This program is distributed in the hope that it will be useful,
-- but WITHOUT ANY WARRANTY; without even the implied warranty
-- of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
-- GNU General Public License for more details.

-- You should have received a copy of the GNU General Public License
-- along with this program.  If not, see <https://www.gnu.org/licenses/>.
*/

#include "osd.h"
#include "spi.h"

void spi_osd_cmd_cont(unsigned char cmd) {
  EnableOsd();
  SPI(cmd);
}

void spi_osd_cmd(unsigned char cmd) {
  spi_osd_cmd_cont(cmd);
  DisableOsd();
}

void spi_osd_cmd8_cont(unsigned char cmd, unsigned char parm) {
  EnableOsd();
  SPI(cmd);
  SPI(parm);
}

void spi_osd_cmd8(unsigned char cmd, unsigned char parm) {
  spi_osd_cmd8_cont(cmd, parm);
  DisableOsd();
}

#define OSD_GRID_COLS (OSDLINELEN/8)

static int osd_col;
static int osd_inv;
static int osd_stipple;
static int osd_writing;
static unsigned char osd_color;
static unsigned char osd_colors[OSD_GRID_COLS];

/* A row is a command, an attribute byte (bit 0 inverse, bit 1 stipple), one
   character code per column and then one colour per column; the core owns the
   font and the palette. Rows 0-15 are the menu, 16 the information line under
   the header and 17 the help line at the foot (commands 0x30 and 0x31).
   A code of 1-8 inside a string selects the colour of what follows (8 is
   white, the colour of a row at its start) and takes no column. */
void OsdWriteStart(int row,int inverse,int stipple)
{
	if(osd_writing)
		OsdWriteEnd();
	EnableOsd();
	SPI(MM1_OSDCMDWRITE|row);
	SPI((inverse ? 1 : 0)|(stipple ? 2 : 0));
	osd_col=0;
	osd_color=0;
	osd_inv=inverse;
	osd_stipple=stipple;
	osd_writing=1;
}

void OsdPutChar(unsigned char c)
{
	if(c>0 && c<9)
	{
		osd_color=c&7;
		return;
	}
	if(osd_col<OSD_GRID_COLS)
	{
		SPI(c ? c : ' ');
		osd_colors[osd_col]=osd_color;
		++osd_col;
	}
}

void OsdPuts(unsigned char *s)
{
	unsigned char c;
	while(c=*s++)
		OsdPutChar(c);
}

void OsdWriteEnd()
{
	int i;
	while(osd_col<OSD_GRID_COLS)
	{
		SPI(' ');
		osd_colors[osd_col]=0;
		++osd_col;
	}
	for(i=0;i<OSD_GRID_COLS;++i)
		SPI(osd_colors[i]);
	DisableOsd();
	osd_writing=0;
}

/* Where the box sits on the picture: 0 centre, 1 top left, 2 top right,
   3 bottom left, 4 bottom right. */
void OsdSetPosition(int pos)
{
	spi_osd_cmd(0x50|(pos&7));
}
