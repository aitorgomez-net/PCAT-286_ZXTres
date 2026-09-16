LIBRARY ieee;
USE ieee.std_logic_1164.ALL;
USE ieee.numeric_std.ALL;
USE std.env.ALL;

ENTITY at_cdc_vhdl_tb IS END;
ARCHITECTURE test OF at_cdc_vhdl_tb IS
  SIGNAL i_clk,o_clk,clk : std_logic := '0';
  SIGNAL i_run,o_run : boolean := true;
  SIGNAL src_data,dst_data : std_logic_vector(25 DOWNTO 0) := (OTHERS=>'0');
  SIGNAL send,ready,updated : std_logic := '0';
  SIGNAL reset_na,cfg_valid,llena : std_logic := '0';
  SIGNAL lltune : unsigned(15 DOWNTO 0) := (OTHERS=>'0');
  SIGNAL address : unsigned(5 DOWNTO 0) := (OTHERS=>'0');
  SIGNAL wrdata : unsigned(31 DOWNTO 0) := (OTHERS=>'0');
  SIGNAL wr,owr,iwait : std_logic := '0';
  SIGNAL oa : unsigned(5 DOWNTO 0);
  SIGNAL od : unsigned(31 DOWNTO 0);
  SIGNAL accepted,received : natural := 0;
BEGIN
  PROCESS BEGIN WAIT FOR 8.73 ns; IF i_run THEN i_clk<=NOT i_clk; END IF; END PROCESS;
  PROCESS BEGIN WAIT FOR 3.367 ns; IF o_run THEN o_clk<=NOT o_clk; END IF; END PROCESS;
  clk<=NOT clk AFTER 10 ns;
  lltune(6)<=i_clk; lltune(7)<=o_clk; lltune(5)<='1';
  PROCESS(i_clk)
    VARIABLE n : natural := 0;
  BEGIN
    IF rising_edge(i_clk) THEN
      n:=(n+1) MOD 512;
      IF (n MOD 32)<16 THEN lltune(1)<='1'; ELSE lltune(1)<='0'; END IF;
      IF n<256 THEN lltune(0)<='1'; ELSE lltune(0)<='0'; END IF;
    END IF;
  END PROCESS;
  PROCESS(o_clk)
    VARIABLE n : natural := 0;
  BEGIN
    IF rising_edge(o_clk) THEN
      n:=(n+1) MOD 1328;
      IF n<664 THEN lltune(4)<='1'; ELSE lltune(4)<='0'; END IF;
    END IF;
  END PROCESS;
  mailbox: ENTITY work.at_cdc_snapshot_vhd GENERIC MAP(WIDTH=>26)
    PORT MAP(i_clk,send,src_data,ready,o_clk,dst_data,updated);
  pll: ENTITY work.pll_hdmi_adj GENERIC MAP(AT_CDC=>true)
    PORT MAP(cfg_valid=>cfg_valid,llena=>llena,lltune=>lltune,locked=>OPEN,
      i_waitrequest=>iwait,i_write=>wr,i_address=>address,i_writedata=>wrdata,
      o_waitrequest=>'0',o_write=>owr,o_address=>oa,o_writedata=>od,
      clk=>clk,reset_na=>reset_na);
  -- Width/height cross bit boundaries as a single 26-bit geometry tuple.
  PROCESS(i_clk)
    VARIABLE n : natural := 0;
  BEGIN
    IF rising_edge(i_clk) AND send='1' AND ready='1' THEN
      n:=(n+1) MOD 4096;
      accepted<=accepted+1;
      src_data<=std_logic_vector(to_unsigned(n,12)) &
                std_logic_vector(to_unsigned(4095-n,12)) & "10";
    END IF;
  END PROCESS;
  PROCESS
    VARIABLE expected : natural;
  BEGIN
    WAIT UNTIL rising_edge(o_clk); WAIT FOR 1 ps;
    IF updated='1' THEN
      expected:=received MOD 4096;
      IF received=0 THEN
        ASSERT dst_data=(dst_data'RANGE=>'0') REPORT "Initial geometry" SEVERITY failure;
      ELSE
        ASSERT to_integer(unsigned(dst_data(25 DOWNTO 14)))=expected AND
               to_integer(unsigned(dst_data(13 DOWNTO 2)))=4095-expected AND
               dst_data(1 DOWNTO 0)="10" REPORT "Torn VHDL geometry" SEVERITY failure;
      END IF;
      received<=received+1;
    END IF;
  END PROCESS;
  PROCESS BEGIN
    WAIT FOR 51 ns; reset_na<='1'; send<='1';
    WAIT FOR 263 ns; cfg_valid<='1';
    WAIT FOR 20 us; WAIT UNTIL falling_edge(o_clk); o_run<=false;
    WAIT FOR 913 ns; o_run<=true;
    WAIT FOR 10 us; cfg_valid<='0';
    WAIT FOR 367 ns; cfg_valid<='1';
    WAIT FOR 20 us; reset_na<='0';
    WAIT FOR 111 ns; reset_na<='1';
    WAIT FOR 20 us; WAIT UNTIL falling_edge(i_clk); i_run<=false;
    WAIT FOR 723 ns; i_run<=true;
    WAIT FOR 40 us; WAIT UNTIL falling_edge(i_clk); send<='0';
    WAIT FOR 400 ns;
    ASSERT accepted=received AND received>500 REPORT "VHDL snapshot delivery mismatch" SEVERITY failure;
    REPORT "AT_CDC_VHDL_PASS accepted=" & integer'image(accepted);
    stop;
  END PROCESS;
END;
