#!/usr/bin/env python3
"""Stage DeMiSTify sources for the 32-column, 16-row ZXTRES OSD."""
from pathlib import Path
import re
import sys


def replace_once(text, old, new, label):
    count = text.count(old)
    if count != 1:
        raise ValueError(f'{label}: expected one source match, found {count}')
    return text.replace(old, new, 1)


def sub_once(text, pattern, replacement, label):
    result, count = re.subn(pattern, lambda _: replacement, text,
                            count=1, flags=re.MULTILINE | re.DOTALL)
    if count != 1:
        raise ValueError(f'{label}: expected one source match, found {count}')
    return result


def transform(main_path, menu_path, header_path):
    header = header_path.read_text()
    header = sub_once(header, r'#define OSDNLINE\s+8\b',
                      '#define OSDNLINE         16', 'osd.h rows')
    header = sub_once(header, r'#define OSDLINELEN\s+256\b',
                      '#define OSDLINELEN       256', 'osd.h columns')

    menu = menu_path.read_text()
    menu = replace_once(menu, 'menu+7', 'menu+(menurows-1)', 'menu footer row')

    source = main_path.read_text()
    source = replace_once(source, '#define LINELENGTH 32',
                          '#define LINELENGTH (OSDLINELEN/8)', 'menu label width')
    # 32 columns plus the colour codes a label can carry (see overrides.c)
    source = replace_once(source, 'static char romfilenames[7][30];',
                          'static char romfilenames[OSDNLINE-1][40];',
                          'file selector labels')
    source = replace_once(source, 'static char menufiletitle[]="Load *.";',
                          'static char menufiletitle[LINELENGTH+1]="Load *.";',
                          'file title capacity')
    source = replace_once(source, 'menuindex-=6', 'menuindex-=OSDNLINE-2',
                          'main menu page up')
    source = replace_once(source, 'menuindex+=6', 'menuindex+=OSDNLINE-2',
                          'main menu page down')

    # The lines of the file selector: icon, NAME.EXT and the size, made by
    # fileline() in overrides.c.
    source = sub_once(
        source,
        r'if\(longfilename\[0\]\)\s*strncpy\(romfilenames\[j\+\+\]\+2,longfilename,27\);'
        r'\s*else\s*\{\s*romfilenames\[j\]\[13\]=0;'
        r'\s*strncpy\(romfilenames\[j\+\+\]\+2,p->Name,11\);\s*\}',
        'fileline(romfilenames[j++],p,1);',
        'directory filename handling')
    source = sub_once(
        source,
        r'if\(longfilename\[0\]\)\s*strncpy\(romfilenames\[j\+\+\],longfilename,29\);'
        r'\s*else\s*\{\s*romfilenames\[j\]\[11\]=0;'
        r'\s*strncpy\(romfilenames\[j\+\+\],p->Name,11\);\s*\}',
        'fileline(romfilenames[j++],p,0);',
        'file filename handling')

    # The look of the menu (overrides.c) tells the row kinds by their actions.
    source = replace_once(source, 'static void submenu(int row);', 'void submenu(int row);',
                          'submenu prototype')
    source = replace_once(source, 'static void submenu(int row)\n{', 'void submenu(int row)\n{',
                          'submenu definition')
    source = replace_once(source, 'static void fileselector(int row)\n{',
                          'void fileselector(int row)\n{', 'fileselector definition')

    # "L,Title;" is a separator: a rule with a title, not selectable.
    source = sub_once(
        source, r"case 'O':\s*case 'T':",
        "case 'L':\n"
        '\t\t\t\t\t\tc=configstring_next();\n'
        '\t\t\t\t\t\tmenu[line].label[0]=0x88;\n'
        '\t\t\t\t\t\tconfigstring_copytocomma(&menu[line].label[1],LINELENGTH-2,1);\n'
        '\t\t\t\t\t\tmenu[line].action=0;\n'
        '\t\t\t\t\t\tnextline=1;\n'
        '\t\t\t\t\t\tbreak;\n'
        "\t\t\t\t\tcase 'O':\n"
        "\t\t\t\t\tcase 'T':",
        'separator entries')

    menu_entries = 'struct menu_entry menu[]=\n{\n' + ',\n'.join(
        f'\t{{MENU_ACTION(&submenu),romfilenames[{i}],0,0,0}}'
        for i in range(15)) + ',\n'
    menu_entries += '\t{MENU_ACTION(&submenu),0,0,0,0},\n'
    menu_entries += '\t{MENU_ACTION(scrollmenu),0,0,0,0}\n};'
    source = sub_once(source, r'struct menu_entry menu\[\]=\s*\{.*?\n\};',
                      menu_entries, 'menu table (15 rows, footer, handler)')

    count = source.count('menu[7]')
    if count != 5:
        raise ValueError(f'menu footer indexes: expected 5 source matches, found {count}')
    source = source.replace('menu[7]', 'menu[OSDNLINE-1]')
    source = replace_once(source, 'submenu(7)', 'submenu(OSDNLINE-1)',
                          'menu footer navigation')
    source = replace_once(source, '(j<7)', '(j<OSDNLINE-1)',
                          'file selector row count')
    source = replace_once(source, '(line<7)', '(line<OSDNLINE-1)',
                          'supporters row count')
    source = replace_once(source, 'line<7', 'line<OSDNLINE-1',
                          'menu parser row count')
    source = replace_once(source, 'menuindex,7);', 'menuindex,OSDNLINE-1);',
                          'menu parser limit')
    source = replace_once(source, 'supporters[menuindex+6]',
                          'supporters[menuindex+OSDNLINE-2]',
                          'supporter page size')


    # Show the mounted image name after the label of file selector entries.
    # imagename() is provided by the core's overrides.c (a weak default here).
    source = replace_once(
        source,
        'void parseconf(int selpage,struct menu_entry *menu,unsigned int first,unsigned int limit);',
        'void parseconf(int selpage,struct menu_entry *menu,unsigned int first,unsigned int limit);\n'
        '__weak const char *imagename(int unit) { return 0; }\n'
        '#define MENUPAGE_CONFIRM 27\n'
        '#define MENUPAGE_INFO 26\n'
        'int confirm_page(struct menu_entry *m);\n'
        'int info_page(struct menu_entry *m);\n'
        'void fileline(char *dst,DIRENTRY *p,int isdir);',
        'image name hook')

    # Pages of the core's own (overrides.c): "Save settings?" and the like.
    source = sub_once(
        source,
        r'if\(menupage==MENUPAGE_FILE\)\s*\{\s*#ifndef CONFIG_WITHOUT_FILESELECTOR',
        'if(menupage==MENUPAGE_CONFIRM)\n'
        '\t{\n'
        '\t\tline=confirm_page(menu);\n'
        '\t}\n'
        '\telse if(menupage==MENUPAGE_INFO)\n'
        '\t{\n'
        '\t\tline=info_page(menu);\n'
        '\t}\n'
        '\telse if(menupage==MENUPAGE_FILE)\n'
        '\t{\n'
        '#ifndef CONFIG_WITHOUT_FILESELECTOR',
        'confirmation page')
    source = replace_once(
        source, "menu[line].label[low]=' ';",
        '{\n'
        '\t\t\t\t\t\t\t\tconst char *nm=imagename(diskunit);\n'
        '\t\t\t\t\t\t\t\tif(nm)\n'
        '\t\t\t\t\t\t\t\t{\n'
        "\t\t\t\t\t\t\t\t\tmenu[line].label[low++]=' ';\n"
        '\t\t\t\t\t\t\t\t\twhile(*nm && low<(LINELENGTH-3))\n'
        '\t\t\t\t\t\t\t\t\t\tmenu[line].label[low++]=*nm++;\n'
        '\t\t\t\t\t\t\t\t}\n'
        '\t\t\t\t\t\t\t}\n'
        "\t\t\t\t\t\t\tmenu[line].label[low]=' ';",
        'image name in file entries')

    # Keyboard auto-repeat for the cursor keys in the OSD.
    menu = replace_once(
        menu, 'void Menu_Run()\n',
        '/* Cursor key edge, then repeat while the key stays held. */\n'
        '#define KEY_REPEATFIRST 400\n'
        '#define KEY_REPEATRATE 80\n'
        'static int Menu_KeyRepeat(int key,int slot)\n'
        '{\n'
        '\tstatic unsigned int stamp[4];\n'
        '\tint s=TestKey(key);\n'
        '\tif(s&2)\n'
        '\t{\n'
        '\t\tstamp[slot]=GetTimer(KEY_REPEATFIRST);\n'
        '\t\treturn(1);\n'
        '\t}\n'
        '\tif(!(s&1))\n'
        '\t{\n'
        '\t\tstamp[slot]=0;\n'
        '\t\treturn(0);\n'
        '\t}\n'
        '\tif(stamp[slot] && CheckTimer(stamp[slot]))\n'
        '\t{\n'
        '\t\tstamp[slot]=GetTimer(KEY_REPEATRATE);\n'
        '\t\treturn(1);\n'
        '\t}\n'
        '\treturn(0);\n'
        '}\n\n'
        'void Menu_Run()\n',
        'menu key repeat helper')
    # The cursor skips the empty rows: down from the last entry lands on
    # Back, up from Back on the last entry.
    menu = replace_once(
        menu, 'void Menu_Run()\n',
        'static int Menu_NextRow(int row,int dir)\n'
        '{\n'
        '\tint r=row+dir;\n'
        '\twhile(r>=0 && r<menurows-1 && !menu[r].action)\n'
        '\t\tr+=dir;\n'
        '\treturn(r<0 ? row : r);\n'
        '}\n\n'
        'void Menu_Run()\n',
        'menu next row helper')
    menu = replace_once(menu, '--currentrow;', 'currentrow=Menu_NextRow(currentrow,-1);',
                        'menu cursor up')
    menu = replace_once(menu, '++currentrow;', 'currentrow=Menu_NextRow(currentrow,1);',
                        'menu cursor down')
    for slot, name in enumerate(('LEFT', 'RIGHT', 'UP', 'DOWN')):
        menu = replace_once(
            menu, f'TestKey(KEY_OSD_{name}ARROW)&2',
            f'Menu_KeyRepeat(KEY_OSD_{name}ARROW,{slot})',
            f'menu {name.lower()} key repeat')

    # Win+F12 opens and closes the OSD; F12 alone belongs to the core, which
    # pauses on it (zxtres_ps2_key.sv keeps Win+F12 from the core).
    menu = replace_once(
        menu, 'void Menu_Run()\n',
        '/* The menu key, Win+F12: a Windows key down, or pressed since the last\n'
        '   look, makes F12 the menu key; an F12 without one is forgotten. F12\n'
        '   alone closes the menu: the core does not see the keyboard then. */\n'
        'static int Menu_OsdKey()\n'
        '{\n'
        '\tif(((TestKey(KEY_LGUI)|TestKey(KEY_RGUI))&3) || menu_visible)\n'
        '\t\treturn(KEY_OSD);\n'
        '\tTestKey(KEY_OSD);\n'
        '\treturn(0);\n'
        '}\n\n'
        'void Menu_Run()\n',
        'menu key helper')
    menu = replace_once(menu, 'if(Menu_PollInput(KEY_OSD,0,JOY_BUTTON_MENU))',
                        'if(Menu_PollInput(Menu_OsdKey(),0,JOY_BUTTON_MENU))',
                        'menu key Win+F12')

    # ESC backs out of the menu as it does on MiSTer: from a page to the main
    # page (osd_escape() in overrides.c), from the main page it closes the OSD.
    # Presses made while the OSD was hidden belong to the core and are dropped.
    menu = replace_once(menu, '#define KEY_OSD_NUMLOCK KEY_SET1_NUMLOCK\n',
                        '#define KEY_OSD_NUMLOCK KEY_SET1_NUMLOCK\n'
                        '#define KEY_OSD_ESC KEY_SET1_ESC\n', 'menu ESC key (set 1)')
    menu = replace_once(menu, '#define KEY_OSD_NUMLOCK KEY_NUMLOCK\n',
                        '#define KEY_OSD_NUMLOCK KEY_NUMLOCK\n'
                        '#define KEY_OSD_ESC KEY_ESC\n', 'menu ESC key')
    menu = replace_once(menu, 'void Menu_Run()\n',
                        'void osd_escape(void);\n\nvoid Menu_Run()\n', 'menu ESC prototype')
    menu = replace_once(menu, 'TestKey(KEY_OSD_PAGEUP);',
                        'TestKey(KEY_OSD_PAGEUP);\n\t\tTestKey(KEY_OSD_ESC);',
                        'menu ESC swallowed while hidden')
    menu = replace_once(menu, '\tjoy=menu_joymerged;\n',
                        '\tif(TestKey(KEY_OSD_ESC)&2)\n'
                        '\t{\n'
                        '\t\tosd_escape();\n'
                        '\t\treturn;\n'
                        '\t}\n\n'
                        '\tjoy=menu_joymerged;\n', 'menu ESC handler')

    # The look of the rows, the information and help lines, and the left and
    # right keys changing the option under the cursor live in overrides.c.
    menu = replace_once(
        menu, '#define menurows OSD_ROWS\n',
        '#define menurows OSD_ROWS\n\n'
        'int menu_message;       /* set while Menu_Message draws its text on the last row */\n'
        'void Menu_DrawRow(int row,int selected,struct menu_entry *m);\n'
        'void Menu_DrawExtras(int selected,struct menu_entry *m);\n'
        'int Menu_AdjustRow(int row,int dir);\n',
        'menu look hooks')
    menu = replace_once(
        menu,
        '\t\tOsdWriteStart(i,i==currentrow,0);\n'
        "\t\tOsdPutChar(' ');\n"
        '\t\tOsdPuts(m->label);\n'
        '\t\tOsdWriteEnd();\n'
        '\t\tm++;\n'
        '\t}\n',
        '\t\tMenu_DrawRow(i,i==currentrow,m);\n'
        '\t\tm++;\n'
        '\t}\n'
        '\tMenu_DrawExtras(currentrow,menu);\n',
        'menu row drawing')
    menu = replace_once(
        menu, '\t\tm->label=msg;\n\t\tMenu_Set(menu);',
        '\t\tm->label=msg;\n\t\tmenu_message=1;\n\t\tMenu_Set(menu);',
        'menu message start')
    menu = replace_once(menu, '\t\tm->label=tmp;',
                        '\t\tmenu_message=0;\n\t\tm->label=tmp;', 'menu message end')
    menu = replace_once(
        menu, '\tif((act<0) && (m+menurows)->action)\n',
        '\tif((act==ROW_LEFT || act==ROW_RIGHT) && Menu_AdjustRow(currentrow,act==ROW_RIGHT ? 1 : -1))\n'
        '\t{\n'
        '\t\tact=0;\n'
        '\t\tupd=1;\n'
        '\t}\n'
        '\tif((act<0) && (m+menurows)->action)\n',
        'option keys')
    header = replace_once(header, 'void OsdWriteEnd();',
                          'void OsdWriteEnd();\nvoid OsdSetPosition(int pos);',
                          'osd position prototype')

    if 'menu[7]' in source or 'submenu(7)' in source:
        raise ValueError('unexpanded footer references remain')
    if 'menuindex-=6' in source or 'menuindex+=6' in source:
        raise ValueError('unexpanded page size remains')
    if 'line<7' in source or 'j<7' in source or 'menuindex,7)' in source:
        raise ValueError('unexpanded row limit remains')
    if 'longfilename,62' in source or 'longfilename,64' in source:
        raise ValueError('filename width exceeds the 32-column OSD')

    return source, menu, header


def main():
    if len(sys.argv) != 5:
        sys.exit('expand_demistify_osd.py MAIN.C MENU.C OSD.H OUTPUT_DIR')

    main_path, menu_path, header_path, out_dir = map(Path, sys.argv[1:])
    try:
        main, menu, header = transform(main_path, menu_path, header_path)
    except (OSError, ValueError) as exc:
        sys.exit(str(exc))

    # Validate everything in memory before creating or modifying any output.
    out_dir.mkdir(parents=True, exist_ok=True)
    (out_dir / 'main.c').write_text(main)
    (out_dir / 'menu.c').write_text(menu)
    (out_dir / 'osd.h').write_text(header)


if __name__ == '__main__':
    main()
