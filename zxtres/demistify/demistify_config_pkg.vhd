-- DeMiSTify configuration for the PCAT-286 ZXTRES+ target.
-- Based on DeMiSTify/templates/demistify_config_pkg.vhd (GPL-3.0).

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

package demistify_config_pkg is
constant demistify_romspace : integer := 14; -- 16 KiB address space for the controller ROM
constant demistify_romsize1 : integer := 13; -- 8 KiB first chunk
constant demistify_romsize2 : integer := 13; -- 8 KiB second chunk

-- Joystick bitmap: directions in bits 3:0, buttons from bit 4 up.
constant demistify_joybits : integer := 8;

constant demistify_button1 : integer := 4;
constant demistify_button2 : integer := 5;
constant demistify_button3 : integer := 6;
constant demistify_button4 : integer := 7;
constant demistify_button5 : integer := 8;
constant demistify_button6 : integer := 9;

constant demistify_serialdebug : std_logic := '0';
end package;
