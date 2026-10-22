-- sync_fifo_tb: self-checking testbench with a reference queue (scoreboard),
-- protocol assertions and coverage counters. Plan: SPEC section 9.
--
-- Prints "TEST PASSED" and exits normally if every check and every coverage
-- item is met. Any failed check stops the simulation with a failure.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;
use std.env.all;
use work.sync_fifo_pkg.all;

entity sync_fifo_tb is
  generic (
    WIDTH     : positive := 8;
    DEPTH     : positive := 16;
    PHASE_LEN : positive := 3000;  -- clock cycles per traffic phase
    SEED      : positive := 1
  );
end entity sync_fifo_tb;

architecture sim of sync_fifo_tb is
  constant ADDR_W : natural := clog2(DEPTH);
  constant PERIOD : time    := 10 ns;

  signal clk      : std_logic := '0';
  signal rst_n    : std_logic := '0';
  signal wr_valid : std_logic := '0';
  signal wr_ready : std_logic;
  signal wr_data  : std_logic_vector(WIDTH - 1 downto 0) := (others => '0');
  signal rd_valid : std_logic;
  signal rd_ready : std_logic := '0';
  signal rd_data  : std_logic_vector(WIDTH - 1 downto 0);
  signal level    : std_logic_vector(ADDR_W downto 0);

  signal w_done    : std_logic := '0';  -- a write transfer happened on the last edge
  signal stim_done : boolean   := false;

  -- Traffic phases: probability that the producer offers a word, and that
  -- the consumer is ready, on each cycle.
  type real_arr is array (natural range <>) of real;
  constant N_PHASES : natural := 8;
  constant P_WR : real_arr(0 to N_PHASES - 1) := (0.9, 0.3, 0.6, 1.0, 1.0, 0.0, 1.0, 0.5);
  constant P_RD : real_arr(0 to N_PHASES - 1) := (0.3, 0.9, 0.6, 1.0, 0.0, 1.0, 1.0, 0.5);
  -- Resets happen after these phases: with a random level (1), with the FIFO
  -- full (4) and with the FIFO drained (6). Pointers differ each time.
  function reset_after(ph : natural) return boolean is
  begin
    return ph = 1 or ph = 4 or ph = 6;
  end function;

  type bool_arr is array (natural range <>) of boolean;
begin

  clk <= not clk after PERIOD / 2;

  dut : entity work.sync_fifo
    generic map (WIDTH => WIDTH, DEPTH => DEPTH)
    port map (
      clk_i      => clk,
      rst_n_i    => rst_n,
      wr_valid_i => wr_valid,
      wr_ready_o => wr_ready,
      wr_data_i  => wr_data,
      rd_valid_o => rd_valid,
      rd_ready_i => rd_ready,
      rd_data_o  => rd_data,
      level_o    => level
    );

  -- Stimulus: drives on falling edges. The producer follows the valid/ready
  -- rule: once valid is high, valid and data are held until accepted.
  stim : process
    variable s1 : positive := SEED;
    variable s2 : positive := SEED + 7;
    variable r  : real;
    variable v  : std_logic_vector(WIDTH - 1 downto 0);
  begin
    rst_n <= '0';
    for i in 1 to 3 loop
      wait until falling_edge(clk);
    end loop;
    rst_n <= '1';

    for ph in 0 to N_PHASES - 1 loop
      for cyc in 1 to PHASE_LEN loop
        wait until falling_edge(clk);

        if wr_valid = '1' and w_done = '0' then
          null;  -- not accepted yet: hold valid and data
        else
          uniform(s1, s2, r);
          if r < P_WR(ph) then
            for b in 0 to WIDTH - 1 loop
              uniform(s1, s2, r);
              if r > 0.5 then
                v(b) := '1';
              else
                v(b) := '0';
              end if;
            end loop;
            wr_valid <= '1';
            wr_data  <= v;
          else
            wr_valid <= '0';
          end if;
        end if;

        uniform(s1, s2, r);
        if r < P_RD(ph) then
          rd_ready <= '1';
        else
          rd_ready <= '0';
        end if;
      end loop;

      if reset_after(ph) then
        wait until falling_edge(clk);
        wr_valid <= '0';
        rd_ready <= '0';
        rst_n    <= '0';
        wait until falling_edge(clk);
        wait until falling_edge(clk);
        rst_n <= '1';
      end if;
    end loop;

    wait until falling_edge(clk);
    wr_valid  <= '0';
    rd_ready  <= '0';
    stim_done <= true;
    wait;
  end process stim;

  -- Monitor and scoreboard: samples on rising edges, so it sees the values
  -- the DUT sees at that edge (before the edge's updates).
  mon : process (clk)
    type ref_t is array (0 to DEPTH) of std_logic_vector(WIDTH - 1 downto 0);
    variable q     : ref_t;
    variable head  : natural := 0;
    variable count : natural := 0;
    variable do_w, do_r : boolean;

    variable prev_stall : boolean := false;
    variable prev_data  : std_logic_vector(WIDTH - 1 downto 0) := (others => '0');

    variable seen : bool_arr(0 to DEPTH) := (others => false);

    -- coverage counters (SPEC section 9)
    variable cov_w_while_full   : natural := 0;
    variable cov_r_while_empty  : natural := 0;
    variable cov_rw_mid         : natural := 0;
    variable cov_r_with_w_full  : natural := 0;
    variable cov_stall_3        : natural := 0;
    variable cov_reset_w_data   : natural := 0;
    variable stall_len          : natural := 0;
    variable writes_since_reset : natural := 0;
    variable wrapped            : boolean := false;
    variable total_w, total_r   : natural := 0;

    function yn(b : boolean) return string is
    begin
      if b then return "yes"; else return "NO"; end if;
    end function;
  begin
    if rising_edge(clk) then
      if rst_n = '0' then
        if count > 0 then
          cov_reset_w_data := cov_reset_w_data + 1;
        end if;
        count := 0;
        head  := 0;
        prev_stall := false;
        stall_len  := 0;
        writes_since_reset := 0;
        seen(0) := true;
        w_done <= '0';
      else
        -- Output checks against the reference queue (SPEC sections 4, 5, 9)
        assert (wr_ready = '1') = (count < DEPTH)
          report "wr_ready wrong: ready=" & std_logic'image(wr_ready)
                 & " ref level=" & integer'image(count)
          severity failure;
        assert (rd_valid = '1') = (count > 0)
          report "rd_valid wrong: valid=" & std_logic'image(rd_valid)
                 & " ref level=" & integer'image(count)
          severity failure;
        assert to_integer(unsigned(level)) = count
          report "level_o wrong: dut=" & integer'image(to_integer(unsigned(level)))
                 & " ref=" & integer'image(count)
          severity failure;
        if count > 0 then
          assert rd_data = q(head)
            report "data mismatch at read side (lost, duplicated or reordered word)"
            severity failure;
        end if;

        -- Output stability: a stalled word must stay valid and unchanged
        if prev_stall then
          assert rd_valid = '1' and rd_data = prev_data
            report "rd_valid or rd_data changed during a stall"
            severity failure;
        end if;

        do_w := wr_valid = '1' and wr_ready = '1';
        do_r := rd_valid = '1' and rd_ready = '1';

        -- Coverage
        if wr_valid = '1' and count = DEPTH then
          cov_w_while_full := cov_w_while_full + 1;
          if rd_ready = '1' then
            cov_r_with_w_full := cov_r_with_w_full + 1;
          end if;
        end if;
        if rd_ready = '1' and count = 0 then
          cov_r_while_empty := cov_r_while_empty + 1;
        end if;
        if do_w and do_r and count > 0 and count < DEPTH then
          cov_rw_mid := cov_rw_mid + 1;
        end if;
        if rd_valid = '1' and rd_ready = '0' then
          stall_len := stall_len + 1;
          if stall_len = 3 then
            cov_stall_3 := cov_stall_3 + 1;
          end if;
        else
          stall_len := 0;
        end if;

        -- Reference queue update: read first, then write
        if do_r then
          head  := (head + 1) mod (DEPTH + 1);
          count := count - 1;
          total_r := total_r + 1;
        end if;
        if do_w then
          assert count < DEPTH
            report "reference queue overflow: DUT accepted a write while full"
            severity failure;
          q((head + count) mod (DEPTH + 1)) := wr_data;
          count := count + 1;
          total_w := total_w + 1;
          writes_since_reset := writes_since_reset + 1;
          if writes_since_reset >= 2 * DEPTH then
            wrapped := true;
          end if;
        end if;

        seen(count) := true;
        if do_w then w_done <= '1'; else w_done <= '0'; end if;
        prev_stall := rd_valid = '1' and rd_ready = '0';
        prev_data  := rd_data;
      end if;

      -- End of test: coverage must be complete
      if stim_done then
        report "coverage: all levels 0 to " & integer'image(DEPTH) & " reached: "
               & yn(seen = bool_arr'(0 to DEPTH => true));
        report "coverage: write offered while full:        " & integer'image(cov_w_while_full);
        report "coverage: rd_ready high while empty:       " & integer'image(cov_r_while_empty);
        report "coverage: read and write on same edge:     " & integer'image(cov_rw_mid);
        report "coverage: read while write refused (full): " & integer'image(cov_r_with_w_full);
        report "coverage: stall of 3 or more cycles:       " & integer'image(cov_stall_3);
        report "coverage: reset with words stored:         " & integer'image(cov_reset_w_data);
        report "coverage: pointer wrap-around:             " & yn(wrapped);
        report "transfers: written=" & integer'image(total_w)
               & " read=" & integer'image(total_r);

        assert seen = bool_arr'(0 to DEPTH => true)
          report "coverage hole: not every level was reached" severity failure;
        assert cov_w_while_full > 0
          report "coverage hole: write while full" severity failure;
        assert cov_r_while_empty > 0
          report "coverage hole: rd_ready while empty" severity failure;
        assert cov_rw_mid > 0
          report "coverage hole: same-edge read and write" severity failure;
        assert cov_r_with_w_full > 0
          report "coverage hole: read while write refused" severity failure;
        assert cov_stall_3 > 0
          report "coverage hole: stall of 3 cycles" severity failure;
        assert cov_reset_w_data > 0
          report "coverage hole: reset with words stored" severity failure;
        assert wrapped
          report "coverage hole: pointer wrap-around" severity failure;

        report "TEST PASSED: WIDTH=" & integer'image(WIDTH)
               & " DEPTH=" & integer'image(DEPTH);
        finish;
      end if;
    end if;
  end process mon;

end architecture sim;
