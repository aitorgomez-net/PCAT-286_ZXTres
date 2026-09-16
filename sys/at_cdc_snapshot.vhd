-- VHDL counterpart of at_cdc_snapshot.sv (same protocol and SDC names).
-- Latest-value metadata only. Configuration initializes both endpoints;
-- runtime reset must NOT reset just one side of this toggle handshake.
LIBRARY ieee;
USE ieee.std_logic_1164.ALL;

ENTITY at_cdc_snapshot_vhd IS
  GENERIC (WIDTH : positive := 1);
  PORT (
    src_clk, src_send : IN std_logic;
    src_data : IN std_logic_vector(WIDTH-1 DOWNTO 0);
    src_ready : OUT std_logic;
    dst_clk : IN std_logic;
    dst_data : OUT std_logic_vector(WIDTH-1 DOWNTO 0) := (OTHERS => '0');
    dst_update : OUT std_logic := '0'
  );
END ENTITY;

ARCHITECTURE rtl OF at_cdc_snapshot_vhd IS
  SIGNAL payload_q : std_logic_vector(WIDTH-1 DOWNTO 0) := (OTHERS => '0');
  SIGNAL req_q, ack_q, ack_meta, ack_sync, req_meta, req_sync : std_logic := '0';
  ATTRIBUTE preserve : boolean;
  ATTRIBUTE preserve OF payload_q, req_q, ack_q, ack_meta, ack_sync, req_meta, req_sync : SIGNAL IS true;
  ATTRIBUTE altera_attribute : string;
  ATTRIBUTE altera_attribute OF ack_meta, ack_sync, req_meta, req_sync : SIGNAL IS
    "-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS; -name DONT_MERGE_REGISTER ON";
BEGIN
  src_ready <= '1' WHEN req_q = ack_sync ELSE '0';
  PROCESS(src_clk) BEGIN
    IF rising_edge(src_clk) THEN
      ack_meta <= ack_q;
      ack_sync <= ack_meta;
      IF src_send = '1' AND req_q = ack_sync THEN
        payload_q <= src_data;
        req_q <= NOT req_q;
      END IF;
    END IF;
  END PROCESS;
  PROCESS(dst_clk) BEGIN
    IF rising_edge(dst_clk) THEN
      req_meta <= req_q;
      req_sync <= req_meta;
      dst_update <= '0';
      IF req_sync /= ack_q THEN
        dst_data <= payload_q;
        dst_update <= '1';
        ack_q <= req_sync;
      END IF;
    END IF;
  END PROCESS;
END ARCHITECTURE;
