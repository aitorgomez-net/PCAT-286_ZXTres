LIBRARY ieee;
USE ieee.std_logic_1164.ALL;
USE ieee.numeric_std.ALL;
USE std.env.ALL;
-- Legacy elaboration diagnostic without a memory slave. Functional checks
-- with Avalon responses are in at_scaler_avalon_tb.vhd.
ENTITY at_scaler_cdc_tb IS GENERIC (ENABLE_CDC : boolean := true); END;
ARCHITECTURE test OF at_scaler_cdc_tb IS
  SIGNAL ic,oc,ac,pc : std_logic := '0';
  SIGNAL reset_na,hs,vs,de : std_logic := '0';
  SIGNAL ohs,ovs,ode : std_logic;
  SIGNAL hd,vd : natural RANGE 0 TO 4095;
BEGIN
  ic<=NOT ic AFTER 8.73 ns; oc<=NOT oc AFTER 3.367 ns;
  ac<=NOT ac AFTER 5 ns; pc<=NOT pc AFTER 10 ns;
  PROCESS(ic)
    VARIABLE h : natural := 0;
    VARIABLE v : natural := 0;
  BEGIN
    IF rising_edge(ic) THEN
      IF h=95 THEN h:=0; v:=(v+1) MOD 32; ELSE h:=h+1; END IF;
      hs<='0'; vs<='0'; de<='0';
      IF h>=80 AND h<88 THEN hs<='1'; END IF;
      IF v>=24 AND v<28 THEN vs<='1'; END IF;
      IF h<64 AND v<16 THEN de<='1'; END IF;
    END IF;
  END PROCESS;
  dut: ENTITY work.ascal
    GENERIC MAP(AT_CDC=>ENABLE_CDC, RAMBASE=>x"20000000", IHRES=>128, OHRES=>1024,
      PALETTE=>false,PALETTE2=>false,ADAPTIVE=>false,FRAC=>8,N_DW=>128,N_AW=>28)
    PORT MAP(i_clk=>ic,i_ce=>'1',i_r=>x"44",i_g=>x"55",i_b=>x"66",
      i_hs=>hs,i_vs=>vs,i_de=>de,i_fl=>'0',
      o_clk=>oc,o_ce=>'1',o_r=>OPEN,o_g=>OPEN,o_b=>OPEN,o_hs=>ohs,o_vs=>ovs,
      o_de=>ode,o_vbl=>OPEN,o_brd=>OPEN,o_lltune=>OPEN,
      i_hdmax=>hd,i_vdmax=>vd,mode=>"00000",
      htotal=>160,hsstart=>136,hsend=>144,hdisp=>128,hmin=>16,hmax=>111,
      vtotal=>64,vsstart=>52,vsend=>56,vdisp=>48,vmin=>8,vmax=>39,
      poly_clk=>pc,poly_dw=>(OTHERS=>'0'),poly_a=>(OTHERS=>'0'),poly_wr=>'0',
      avl_clk=>ac,avl_waitrequest=>'0',avl_readdata=>(OTHERS=>'0'),avl_readdatavalid=>'0',
      avl_burstcount=>OPEN,avl_writedata=>OPEN,avl_address=>OPEN,avl_write=>OPEN,avl_read=>OPEN,
      avl_byteenable=>OPEN,reset_na=>reset_na,pal1_dr=>OPEN,pal2_dr=>OPEN);
  PROCESS BEGIN
    WAIT FOR 133 ns; reset_na<='1';
    WAIT FOR 400 us;
    ASSERT hd=64 AND vd=16 REPORT "Scaler input geometry changed" SEVERITY failure;
    REPORT "AT_SCALER_CDC_PASS measured=" & integer'image(hd) & "x" & integer'image(vd);
    stop;
  END PROCESS;
END;
