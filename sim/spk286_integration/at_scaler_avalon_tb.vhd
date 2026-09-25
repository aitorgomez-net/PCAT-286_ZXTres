LIBRARY ieee;
USE ieee.std_logic_1164.ALL;
USE ieee.numeric_std.ALL;
USE std.env.ALL;

-- Production scaler, unrelated clocks, triple buffering and an Avalon slave
-- with bounded backpressure and delayed, ordered burst responses.
ENTITY at_scaler_avalon_tb IS
  GENERIC (PHASE_NS : natural := 0; INTERLACED : boolean := false;
           LOCAL_CONFIG : boolean := false; FILTER_TEST : boolean := false);
END;
ARCHITECTURE test OF at_scaler_avalon_tb IS
  SIGNAL ic,oc,ac,pc : std_logic := '0';
  SIGNAL output_clock_enable : boolean := true;
  SIGNAL filter_clock_enable, poly_clock_enable : boolean := true;
  SIGNAL poly_active, poly_write : std_logic := '0';
  SIGNAL poly_address : unsigned(11 DOWNTO 0) := (OTHERS=>'0');
  SIGNAL poly_data : unsigned(9 DOWNTO 0) := (OTHERS=>'0');
  SIGNAL scaler_mode : unsigned(4 DOWNTO 0);
  SIGNAL reset_na,hs,vs,de,field : std_logic := '0';
  SIGNAL ohs,ovs,ode,ordr : std_logic;
  SIGNAL red,green,blue : unsigned(7 DOWNTO 0);
  SIGNAL hd,vd : natural RANGE 0 TO 4095;
  SIGNAL fb_enable : std_logic := '0';
  SIGNAL config_update : std_logic := '0';
  SIGNAL config_retime : std_logic := '0';
  SIGNAL out_htotal : natural RANGE 0 TO 4095 := 160;
  SIGNAL out_vtotal : natural RANGE 0 TO 4095 := 64;
  SIGNAL out_vdisp : natural RANGE 0 TO 4095 := 48;
  SIGNAL out_vsstart : natural RANGE 0 TO 4095 := 52;
  SIGNAL out_vsend : natural RANGE 0 TO 4095 := 56;
  SIGNAL running : std_logic := '0';
  SIGNAL fb_base : unsigned(31 DOWNTO 0) := x"24000000";
  SIGNAL rd,wr,waitreq,rv : std_logic := '0';
  SIGNAL addr : std_logic_vector(27 DOWNTO 0);
  SIGNAL wd,rdata : std_logic_vector(127 DOWNTO 0) := (OTHERS=>'0');
  SIGNAL bc : std_logic_vector(7 DOWNTO 0);
  SIGNAL be : std_logic_vector(15 DOWNTO 0);
  SIGNAL reads,writes,stalls,good_pixels : natural := 0;
BEGIN
  ic<=NOT ic AFTER 8.73 ns;
  PROCESS BEGIN
    WAIT FOR PHASE_NS * 1 ns;
    LOOP
      WAIT FOR 3.367 ns;
      IF output_clock_enable AND filter_clock_enable THEN oc<=NOT oc; END IF;
    END LOOP;
  END PROCESS;
  ac<=NOT ac AFTER 5 ns;
  PROCESS BEGIN WAIT FOR 10 ns; IF poly_clock_enable THEN pc<=NOT pc; END IF; END PROCESS;
  scaler_mode <= "01100" WHEN FILTER_TEST ELSE "01000";
  PROCESS
    PROCEDURE table_write(bank : natural) IS
    BEGIN
      FOR word IN 0 TO 1023 LOOP
        WAIT UNTIL falling_edge(pc);
        poly_write<='1'; poly_address<=to_unsigned(bank*1024+word,12);
        -- Both base and adaptive tables are normalized identity filters.
        IF word MOD 4=1 THEN poly_data<=to_unsigned(256,10);
        ELSE poly_data<=(OTHERS=>'0'); END IF;
      END LOOP;
      WAIT UNTIL falling_edge(pc); poly_write<='0';
    END;
  BEGIN
    IF FILTER_TEST THEN
      WAIT FOR 1 us; poly_active<='1';
      table_write(0); table_write(1); table_write(2);
      -- A long pause inside UIO is not a completed coefficient transaction.
      poly_clock_enable<=false; WAIT FOR 100 us; poly_clock_enable<=true;
      WAIT UNTIL falling_edge(pc); poly_active<='0';
      WAIT FOR 90 us;
      -- Replace H adaptive by V adaptive while the receiver clock is stopped.
      filter_clock_enable<=false; poly_active<='1';
      table_write(0); table_write(1); table_write(3);
      WAIT UNTIL falling_edge(pc); poly_active<='0';
      WAIT FOR 10 us; filter_clock_enable<=true;
      WAIT FOR 90 us;
      -- A horizontal-only update must preserve the vertical adaptive flag.
      poly_active<='1'; table_write(0);
      WAIT UNTIL falling_edge(pc); poly_active<='0';
      WAIT FOR 90 us;
      poly_active<='1'; table_write(1);
      WAIT UNTIL falling_edge(pc); poly_active<='0';
    END IF;
    WAIT;
  END PROCESS;
  PROCESS(ic)
    VARIABLE h,v : natural := 0;
  BEGIN
    IF rising_edge(ic) THEN
      IF h=95 THEN
        h:=0; v:=(v+1) MOD 32;
        IF v=0 AND INTERLACED THEN field<=NOT field; END IF;
      ELSE h:=h+1; END IF;
      hs<='0'; vs<='0'; de<='0';
      IF h>=80 AND h<88 THEN hs<='1'; END IF;
      IF v>=24 AND v<28 THEN vs<='1'; END IF;
      IF h<64 AND v<16 THEN de<='1'; END IF;
    END IF;
  END PROCESS;
  dut: ENTITY work.ascal
    GENERIC MAP(AT_CDC=>true, AT_LOCAL_CONFIG=>LOCAL_CONFIG, RAMBASE=>x"20000000", IHRES=>128, OHRES=>2304,
      PALETTE=>false,PALETTE2=>false,ADAPTIVE=>FILTER_TEST,FRAC=>8,N_DW=>128,N_AW=>28)
    PORT MAP(i_clk=>ic,i_ce=>'1',i_r=>x"55",i_g=>x"55",i_b=>x"55",
      i_hs=>hs,i_vs=>vs,i_de=>de,i_fl=>field,
      o_clk=>oc,o_ce=>'1',o_r=>red,o_g=>green,o_b=>blue,o_hs=>ohs,o_vs=>ovs,
      o_de=>ode,o_vbl=>OPEN,o_brd=>ordr,o_lltune=>OPEN,
      i_hdmax=>hd,i_vdmax=>vd,mode=>scaler_mode,run=>running,
      at_input_mode=>scaler_mode,at_config_update=>config_update,at_config_retime=>config_retime,
      o_fb_ena=>fb_enable,o_fb_hsize=>64,o_fb_vsize=>16,
      o_fb_format=>"000101",o_fb_base=>fb_base,
      htotal=>out_htotal,hsstart=>136,hsend=>144,hdisp=>128,hmin=>16,hmax=>111,
      vtotal=>out_vtotal,vsstart=>out_vsstart,vsend=>out_vsend,vdisp=>out_vdisp,vmin=>8,vmax=>39,
      poly_clk=>pc,poly_dw=>poly_data,poly_a=>poly_address,poly_wr=>poly_write,at_poly_active=>poly_active,
      avl_clk=>ac,avl_waitrequest=>waitreq,avl_readdata=>rdata,avl_readdatavalid=>rv,
      avl_burstcount=>bc,avl_writedata=>wd,avl_address=>addr,avl_write=>wr,avl_read=>rd,
      avl_byteenable=>be,reset_na=>reset_na,pal1_dr=>OPEN,pal2_dr=>OPEN);

  PROCESS(ac)
    TYPE memory_t IS ARRAY(0 TO 6143) OF std_logic_vector(127 DOWNTO 0);
    VARIABLE mem : memory_t := (OTHERS=>(OTHERS=>'0'));
    TYPE queue_t IS ARRAY(0 TO 3) OF natural;
    VARIABLE queue : queue_t;
    VARIABLE head,tail,queued,beat,delay,cycle,wbeat,wa,a,idx : natural := 0;
    VARIABLE held : boolean := false;
    VARIABLE held_addr : std_logic_vector(27 DOWNTO 0);
    VARIABLE held_data : std_logic_vector(127 DOWNTO 0);
    VARIABLE held_rd,held_wr : std_logic;
    FUNCTION capture_index(a : natural) RETURN natural IS
      VARIABLE delta,bank,offset : natural;
    BEGIN
      ASSERT a>=16#2000000# AND a<16#2180000# REPORT "Capture address out of range" SEVERITY failure;
      delta:=a-16#2000000#; bank:=delta/16#80000#; offset:=delta MOD 16#80000#;
      ASSERT offset<2048 REPORT "Unexpected capture frame offset" SEVERITY failure;
      RETURN bank*2048+offset;
    END;
  BEGIN
    IF rising_edge(ac) THEN
      cycle:=cycle+1;
      -- Two blocked cycles every 13, plus bounded 110 ns pauses.
      IF cycle MOD 13<2 OR cycle MOD 997<11 THEN waitreq<='1';
      ELSE waitreq<='0'; END IF;
      rv<='0';
      IF reset_na='1' THEN
        ASSERT NOT(rd='1' AND wr='1') REPORT "Simultaneous Avalon read/write" SEVERITY failure;
        IF held THEN
          ASSERT addr=held_addr AND rd=held_rd AND wr=held_wr
            REPORT "Avalon command changed under waitrequest" SEVERITY failure;
          IF held_wr='1' THEN
            ASSERT wd=held_data REPORT "Avalon data changed under waitrequest" SEVERITY failure;
          END IF;
        END IF;
        held:=(rd='1' OR wr='1') AND waitreq='1';
        held_addr:=addr; held_data:=wd; held_rd:=rd; held_wr:=wr;
        IF held THEN stalls<=stalls+1; END IF;
        IF wr='1' AND waitreq='0' THEN
          ASSERT bc=x"10" AND be=x"FFFF" REPORT "Write burst shape changed" SEVERITY failure;
          a:=to_integer(unsigned(addr));
          IF wbeat=0 THEN wa:=a;
          ELSE ASSERT a=wa REPORT "Write address changed within burst" SEVERITY failure; END IF;
          IF a>=16#2000000# THEN
            idx:=capture_index(a+wbeat); mem(idx):=wd;
          ELSE ASSERT now<100 us REPORT "Invalid write after startup" SEVERITY failure; END IF;
          wbeat:=(wbeat+1) MOD 16; writes<=writes+1;
        END IF;
        IF rd='1' AND waitreq='0' THEN
          ASSERT bc=x"10" AND queued<4 REPORT "Read queue/burst overflow" SEVERITY failure;
          queue(tail):=to_integer(unsigned(addr)); tail:=(tail+1) MOD 4;
          queued:=queued+1; reads<=reads+1;
        END IF;
        IF queued>0 THEN
          IF delay>0 THEN delay:=delay-1;
          ELSIF cycle MOD 7/=0 THEN
            a:=queue(head)+beat;
            IF a<16#2000000# THEN
              ASSERT now<100 us REPORT "Invalid read after startup" SEVERITY failure;
              rdata<=(OTHERS=>'0');
            ELSIF a>=16#2400000# AND a<16#2480800# THEN
              rdata<=x"55555555555555555555555555555555";
            ELSE idx:=capture_index(a); rdata<=mem(idx); END IF;
            rv<='1'; beat:=beat+1;
            IF beat=16 THEN
              beat:=0; queued:=queued-1; head:=(head+1) MOD 4; delay:=3;
            END IF;
          END IF;
        ELSE delay:=3; END IF;
      END IF;
    END IF;
  END PROCESS;
  PROCESS(oc) BEGIN
    IF rising_edge(oc) AND now>200 us AND ode='1' AND ordr='0' THEN
      IF red=x"55" AND green=x"55" AND blue=x"55" THEN good_pixels<=good_pixels+1; END IF;
    END IF;
  END PROCESS;
  PROCESS BEGIN
    WAIT FOR 133 ns; reset_na<='1';
    -- Like HPS startup, enable output only after input geometry is known.
    WAIT FOR 120 us; running<='1';
    WAIT FOR 210 us;
    IF LOCAL_CONFIG THEN WAIT UNTIL falling_edge(ovs); WAIT UNTIL rising_edge(oc); END IF;
    fb_enable<='1'; config_update<='1';
    WAIT UNTIL rising_edge(oc); config_update<='0';
    WAIT FOR 170 us;
    IF LOCAL_CONFIG THEN WAIT UNTIL falling_edge(ovs); WAIT UNTIL rising_edge(oc); END IF;
    fb_base<=x"24800000"; config_update<='1';
    WAIT UNTIL rising_edge(oc); config_update<='0';
    WAIT FOR 30 us;
    IF LOCAL_CONFIG THEN
      -- Taller raster: old VS lies inside the new active height. The wrapper
      -- supplies the complete local packet, then pulses retime one cycle later.
      WAIT UNTIL falling_edge(ovs); WAIT UNTIL rising_edge(oc);
      out_htotal<=176; out_vtotal<=80; out_vdisp<=64; out_vsstart<=68; out_vsend<=72;
      config_update<='1';
      WAIT UNTIL rising_edge(oc); config_update<='0'; config_retime<='1';
      WAIT UNTIL rising_edge(oc); config_retime<='0';
      WAIT FOR 1 us;
      ASSERT ode='0' REPORT "Taller raster exposed a partial active frame" SEVERITY failure;
    END IF;
    WAIT FOR 85 us; running<='0';
    WAIT FOR 10 us; running<='1';
    WAIT FOR 60 us; output_clock_enable<=false;
    WAIT FOR 3 us; output_clock_enable<=true;
    WAIT FOR 112 us;
    -- These diagnostic ports report the last coordinate, not the pixel count.
    ASSERT hd=63 AND vd=15 REPORT "Scaler input geometry changed" SEVERITY failure;
    ASSERT reads>100 AND writes>100 AND stalls>100 AND good_pixels>1000
      REPORT "Missing framebuffer/Avalon/video activity" SEVERITY failure;
    REPORT "AT_SCALER_AVALON_PASS reads=" & integer'image(reads) &
      " write_beats=" & integer'image(writes) & " stalls=" & integer'image(stalls) &
      " pixels=" & integer'image(good_pixels);
    stop;
  END PROCESS;
END;
