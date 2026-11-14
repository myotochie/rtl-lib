-- uart_tx: UART transmitter, valid/ready input, registered serial output.
-- Behavior is defined in ip/uart/spec/SPEC.md section 5.1. Conventions: docs/CONVENTIONS.md.

library ieee;
use ieee.std_logic_1164.all;
use work.uart_pkg.all;

entity uart_tx is
  generic (
    CLK_FREQ_HZ : positive := 100_000_000;  -- clock frequency, 1 to 500_000_000
    BAUD        : positive := 115_200;      -- bit rate, BIT_CLKS must be 16 to 65535
    DATA_BITS   : positive := 8;            -- 5 to 8
    PARITY      : natural  := 0;            -- 0 none, 1 even, 2 odd
    STOP_BITS   : positive := 1             -- 1 or 2
  );
  port (
    clk_i      : in  std_logic;
    rst_n_i    : in  std_logic;  -- synchronous, active low
    tx_valid_i : in  std_logic;
    tx_ready_o : out std_logic;
    tx_data_i  : in  std_logic_vector(DATA_BITS - 1 downto 0);
    txd_o      : out std_logic
  );
end entity uart_tx;

architecture rtl of uart_tx is
  constant N     : positive := bit_clks(CLK_FREQ_HZ, BAUD);
  constant P_LEN : natural  := parity_len(PARITY);
  constant REST  : positive := DATA_BITS + P_LEN + STOP_BITS;  -- bits after the start bit
  constant NB    : positive := 1 + REST;                       -- bits per frame

  signal run_q    : std_logic := '0';                          -- low during and right after reset
  signal busy_q   : std_logic := '0';
  signal txd_q    : std_logic := '1';
  signal cnt_q    : natural range 0 to N - 1 := 0;             -- clock cycles inside the bit
  signal idx_q    : natural range 0 to NB - 1 := 0;            -- 0 = start bit
  signal shift_q  : std_logic_vector(REST - 1 downto 0) := (others => '1');  -- next bit in (0)
  signal ready    : std_logic;
  signal last_clk : std_logic;                                 -- last cycle of the last stop bit
begin

  assert CLK_FREQ_HZ <= 500_000_000
    report "uart: CLK_FREQ_HZ must be 1 to 500000000"
    severity failure;
  assert bit_clks_raw(CLK_FREQ_HZ, BAUD) >= 16 and bit_clks_raw(CLK_FREQ_HZ, BAUD) <= 65535
    report "uart: BIT_CLKS (CLK_FREQ_HZ / BAUD) must be 16 to 65535"
    severity failure;
  assert baud_error_ok(CLK_FREQ_HZ, BAUD)
    report "uart: rounding error of BIT_CLKS exceeds 2 percent"
    severity failure;
  assert DATA_BITS >= 5 and DATA_BITS <= 8
    report "uart: DATA_BITS must be 5 to 8"
    severity failure;
  assert PARITY <= 2
    report "uart: PARITY must be 0, 1 or 2"
    severity failure;
  assert STOP_BITS <= 2
    report "uart: STOP_BITS must be 1 or 2"
    severity failure;

  -- Ready when idle, and in the last cycle of the last stop bit so that the next frame
  -- starts at the very next edge with no gap. Not a function of tx_valid_i.
  last_clk   <= '1' when (idx_q = NB - 1 and cnt_q = N - 1) else '0';
  ready      <= run_q and (not busy_q or last_clk);
  tx_ready_o <= ready;
  txd_o      <= txd_q;

  p_tx : process (clk_i)
    variable word : std_logic_vector(REST - 1 downto 0);
  begin
    if rising_edge(clk_i) then
      if rst_n_i = '0' then
        run_q   <= '0';
        busy_q  <= '0';
        txd_q   <= '1';
        cnt_q   <= 0;
        idx_q   <= 0;
        shift_q <= (others => '1');
      else
        run_q <= '1';
        if tx_valid_i = '1' and ready = '1' then
          -- Transfer: the start bit begins at this edge.
          word := (others => '1');
          word(DATA_BITS - 1 downto 0) := tx_data_i;
          if PARITY /= 0 then
            word(DATA_BITS) := parity_bit(tx_data_i, PARITY);
          end if;
          shift_q <= word;
          txd_q   <= '0';
          busy_q  <= '1';
          cnt_q   <= 0;
          idx_q   <= 0;
        elsif busy_q = '1' then
          if cnt_q = N - 1 then
            cnt_q <= 0;
            if idx_q = NB - 1 then
              busy_q <= '0';
              txd_q  <= '1';
            else
              idx_q   <= idx_q + 1;
              txd_q   <= shift_q(0);
              shift_q <= '1' & shift_q(REST - 1 downto 1);
            end if;
          else
            cnt_q <= cnt_q + 1;
          end if;
        end if;
      end if;
    end if;
  end process p_tx;

end architecture rtl;