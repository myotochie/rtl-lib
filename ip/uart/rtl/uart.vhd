-- uart: top level, one uart_tx and one uart_rx sharing clock, reset and generics.
-- Behavior is defined in ip/uart/spec/SPEC.md. Conventions: docs/CONVENTIONS.md.

library ieee;
use ieee.std_logic_1164.all;

entity uart is
  generic (
    CLK_FREQ_HZ : positive := 100_000_000;  -- clock frequency, 1 to 500_000_000
    BAUD        : positive := 115_200;      -- bit rate, BIT_CLKS must be 16 to 65535
    DATA_BITS   : positive := 8;            -- 5 to 8
    PARITY      : natural  := 0;            -- 0 none, 1 even, 2 odd
    STOP_BITS   : positive := 1             -- 1 or 2
  );
  port (
    clk_i           : in  std_logic;
    rst_n_i         : in  std_logic;  -- synchronous, active low

    tx_valid_i      : in  std_logic;
    tx_ready_o      : out std_logic;
    tx_data_i       : in  std_logic_vector(DATA_BITS - 1 downto 0);
    txd_o           : out std_logic;

    rxd_i           : in  std_logic;
    rx_valid_o      : out std_logic;
    rx_ready_i      : in  std_logic;
    rx_data_o       : out std_logic_vector(DATA_BITS - 1 downto 0);
    rx_parity_err_o : out std_logic;
    rx_frame_err_o  : out std_logic;
    rx_overrun_o    : out std_logic
  );
end entity uart;

architecture rtl of uart is
begin

  u_tx : entity work.uart_tx
    generic map (CLK_FREQ_HZ => CLK_FREQ_HZ, BAUD => BAUD, DATA_BITS => DATA_BITS,
                 PARITY => PARITY, STOP_BITS => STOP_BITS)
    port map (clk_i => clk_i, rst_n_i => rst_n_i,
              tx_valid_i => tx_valid_i, tx_ready_o => tx_ready_o,
              tx_data_i => tx_data_i, txd_o => txd_o);

  u_rx : entity work.uart_rx
    generic map (CLK_FREQ_HZ => CLK_FREQ_HZ, BAUD => BAUD, DATA_BITS => DATA_BITS,
                 PARITY => PARITY, STOP_BITS => STOP_BITS)
    port map (clk_i => clk_i, rst_n_i => rst_n_i, rxd_i => rxd_i,
              rx_valid_o => rx_valid_o, rx_ready_i => rx_ready_i,
              rx_data_o => rx_data_o, rx_parity_err_o => rx_parity_err_o,
              rx_frame_err_o => rx_frame_err_o, rx_overrun_o => rx_overrun_o);

end architecture rtl;