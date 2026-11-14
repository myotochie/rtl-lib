-- uart_rx: UART receiver. Two-flop synchronizer, counter restarted on the start edge,
-- majority vote of three samples around the middle of each bit, one output register.
-- Behavior is defined in ip/uart/spec/SPEC.md section 5.2. Conventions: docs/CONVENTIONS.md.

library ieee;
use ieee.std_logic_1164.all;
use work.uart_pkg.all;

entity uart_rx is
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
    rxd_i           : in  std_logic;  -- asynchronous to clk_i
    rx_valid_o      : out std_logic;
    rx_ready_i      : in  std_logic;
    rx_data_o       : out std_logic_vector(DATA_BITS - 1 downto 0);
    rx_parity_err_o : out std_logic;
    rx_frame_err_o  : out std_logic;
    rx_overrun_o    : out std_logic
  );
end entity uart_rx;

architecture rtl of uart_rx is
  constant N      : positive := bit_clks(CLK_FREQ_HZ, BAUD);
  constant VOTE_S : positive := vote_offset(N);                     -- vote samples at N/2 -+ VOTE_S
  constant P_LEN  : natural  := parity_len(PARITY);
  constant NB     : positive := 1 + DATA_BITS + P_LEN + STOP_BITS;  -- bits per frame

  -- Phases inside a bit (cnt_q values) where the line is sampled.
  constant PH_A : natural := N / 2 - VOTE_S;
  constant PH_B : natural := N / 2;
  constant PH_C : natural := N / 2 + VOTE_S;  -- decision

  -- The synchronizer resets to 0, so a line that is low when reset is released is not
  -- taken for a start bit (SPEC section 5.4).
  signal sync_q   : std_logic_vector(1 downto 0) := "00";
  signal prev_q   : std_logic := '0';  -- synchronized input one cycle earlier
  attribute ASYNC_REG : string;
  attribute ASYNC_REG of sync_q : signal is "TRUE";

  signal busy_q   : std_logic := '0';
  signal cnt_q    : natural range 0 to N - 1 := 0;
  signal idx_q    : natural range 0 to NB - 1 := 0;  -- 0 = start bit
  signal a_q      : std_logic := '1';
  signal b_q      : std_logic := '1';
  signal shift_q  : std_logic_vector(DATA_BITS - 1 downto 0) := (others => '0');
  signal acc_q    : std_logic := '0';  -- xor of data and parity bits
  signal ferr_q   : std_logic := '0';

  signal out_valid_q  : std_logic := '0';
  signal out_data_q   : std_logic_vector(DATA_BITS - 1 downto 0) := (others => '0');
  signal out_perr_q   : std_logic := '0';
  signal out_ferr_q   : std_logic := '0';
  signal overrun_q    : std_logic := '0';

  signal line_s : std_logic;  -- synchronized input
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

  line_s <= sync_q(1);

  rx_valid_o      <= out_valid_q;
  rx_data_o       <= out_data_q;
  rx_parity_err_o <= out_perr_q;
  rx_frame_err_o  <= out_ferr_q;
  rx_overrun_o    <= overrun_q;

  p_rx : process (clk_i)
    variable v     : std_logic;   -- majority of the three samples
    variable ferr  : std_logic;
    variable perr  : std_logic;
  begin
    if rising_edge(clk_i) then
      if rst_n_i = '0' then
        sync_q      <= "00";
        prev_q      <= '0';
        busy_q      <= '0';
        cnt_q       <= 0;
        idx_q       <= 0;
        a_q         <= '1';
        b_q         <= '1';
        acc_q       <= '0';
        ferr_q      <= '0';
        out_valid_q <= '0';
        overrun_q   <= '0';
      else
        sync_q    <= sync_q(0) & rxd_i;
        prev_q    <= line_s;
        overrun_q <= '0';

        if out_valid_q = '1' and rx_ready_i = '1' then
          out_valid_q <= '0';
        end if;

        if busy_q = '0' then
          -- Idle: a falling edge of the synchronized input starts a frame. The counter
          -- restarts here, so the synchronizer delay cancels out.
          if prev_q = '1' and line_s = '0' then
            busy_q <= '1';
            cnt_q  <= 1;
            idx_q  <= 0;
            acc_q  <= '0';
            ferr_q <= '0';
          end if;
        else
          if cnt_q = PH_A then
            a_q <= line_s;
          end if;
          if cnt_q = PH_B then
            b_q <= line_s;
          end if;

          if cnt_q = PH_C then
            if (a_q and b_q) = '1' or (a_q and line_s) = '1' or (b_q and line_s) = '1' then
              v := '1';
            else
              v := '0';
            end if;

            if idx_q = 0 then
              -- Start bit: a high vote is a false start.
              if v = '1' then
                busy_q <= '0';
              end if;
            elsif idx_q <= DATA_BITS then
              shift_q <= v & shift_q(DATA_BITS - 1 downto 1);
              acc_q   <= acc_q xor v;
            elsif idx_q <= DATA_BITS + P_LEN then
              acc_q   <= acc_q xor v;
            else
              if v = '0' then
                ferr_q <= '1';
              end if;
            end if;

            if idx_q = NB - 1 then
              -- Last stop bit decided: the frame is complete, back to idle at once.
              busy_q <= '0';
              ferr   := ferr_q or not v;
              perr   := '0';
              if PARITY = 1 then
                perr := acc_q;
              elsif PARITY = 2 then
                perr := not acc_q;
              end if;
              if out_valid_q = '0' or rx_ready_i = '1' then
                out_data_q  <= shift_q;
                out_perr_q  <= perr;
                out_ferr_q  <= ferr;
                out_valid_q <= '1';
              else
                overrun_q <= '1';
              end if;
            end if;
          end if;

          if cnt_q = N - 1 then
            cnt_q <= 0;
            if idx_q /= NB - 1 then
              idx_q <= idx_q + 1;
            end if;
          else
            cnt_q <= cnt_q + 1;
          end if;
        end if;
      end if;
    end if;
  end process p_rx;

end architecture rtl;