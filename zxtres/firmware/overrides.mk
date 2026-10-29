# Extra rules for DeMiSTify/firmware/Makefile (make -f Makefile -f overrides.mk):
# Build the OSD and menu sources from this staging directory.
osd.o : osd.c config.h $(CC)
	@echo "Compiling osd.c (PCAT-286)"
	@$(CC) $(COPT) $(CFLAGS) -I$(INCDIR) -I$(DEMISTIFYPATH)/firmware -o=osd.asm osd.c $(CDEFS)
	@$(AS) >/dev/null $(ASFLAGS) -o osd.o osd.asm

font.o : font.c config.h $(CC)
	@echo "Compiling font.c (empty)"
	@$(CC) $(COPT) $(CFLAGS) -I$(INCDIR) -I$(DEMISTIFYPATH)/firmware -o=font.asm font.c $(CDEFS)
	@$(AS) >/dev/null $(ASFLAGS) -o font.o font.asm

main.o : main.c config.h $(CC)
	@echo "Compiling main.c (ZXTRES OSD)"
	@$(CC) $(COPT) $(CFLAGS) -I$(INCDIR) -I$(DEMISTIFYPATH)/firmware -o=main.asm main.c
	@$(AS) >/dev/null $(ASFLAGS) -o main.o main.asm

menu.o : menu.c config.h $(CC)
	@echo "Compiling menu.c (ZXTRES OSD)"
	@$(CC) $(COPT) $(CFLAGS) -I$(INCDIR) -I$(DEMISTIFYPATH)/firmware -o=menu.asm menu.c
	@$(AS) >/dev/null $(ASFLAGS) -o menu.o menu.asm

diskimg.o : diskimg.c config.h $(CC)
	@echo "Compiling diskimg.c (five block devices)"
	@$(CC) $(COPT) $(CFLAGS) -I$(INCDIR) -I$(DEMISTIFYPATH)/firmware -o=diskimg.asm diskimg.c $(CDEFS)
	@$(AS) >/dev/null $(ASFLAGS) -o diskimg.o diskimg.asm
