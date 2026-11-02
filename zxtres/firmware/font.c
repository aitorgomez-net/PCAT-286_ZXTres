/* The character-grid OSD keeps its font in the core (zxtres/rtl/zxtres_osd.sv),
   so the 8x8 pixel font of DeMiSTify/firmware/font.c is not linked.
   font.h still names the menu symbols; the core draws them at the same codes. */
