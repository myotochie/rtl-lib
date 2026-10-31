-- async_fifo_tb: self-checking testbench for async_fifo (SPEC section 9).
--
-- Two free-running clocks with any period ratio and phase. Random traffic on both sides,
-- scoreboard by sequence number, true occupancy computed from the two transfer counters,
-- assertions, coverage items that fail the test when not reached.
-- Prints "TEST PASSED" only if every check passed.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;
use std.env.all;
use work.async_fifo_pkg.all;

entity async_fifo_tb is
  generic (
    WIDTH       : positive := 8;
    DEPTH       : positive := 16;
    SYNC_STAGES : positive := 2;
    WR_PS       : positive := 10000;  -- write clock period in ps
    RD_PS       : positive := 10000;  -- read clock period in ps
    RD_PHASE_PS : natural  := 3000;   -- delay of the read clock relative to the write clock
    PHASE_LEN   : positive := 3000;   -- length of a traffic phase, in edges of the slower clock
    SEED        : positive := 1
  );
end entity async_fifo_tb;

architecture sim of async_fifo_tb is
  constant ADDR_W  : natural  := clog2(DEPTH);
  constant SLOW_PS : positive := maximum(WR_PS, RD_PS);

  -- Full rate is only promised for equal clocks and a deep enough FIFO (SPEC section 8).
  constant FULL_RATE_CHECK : boolean :=
    WR_PS = RD_PS and ((SYNC_STAGES = 2 and DEPTH >= 8) or (SYNC_STAGES > 2 and DEPTH >= 16));

  signal wr_clk, rd_clk     : std_logic := '0';
  signal wr_rst_n, rd_rst_n : std_logic := '0';

  signal wr_valid : std_logic := '0';
  signal wr_ready : std_logic;
  signal wr_data  : std_logic_vector(WIDTH - 1 downto 0);
  signal wr_level : std_logic_vector(ADDR_W downto 0);
  signal rd_valid : std_logic;
  signal rd_ready : std_logic := '0';
  signal rd_data  : std_logic_vector(WIDTH - 1 downto 0);
  signal rd_level : std_logic_vector(ADDR_W downto 0);

  -- Transfers since the last reset, one counter per domain.
  signal wr_count : natural := 0;
  signal rd_count : natural := 0;
  signal wr_limit : natural := natural'high;  -- the producer offers no word beyond this count

  -- Control
  signal chk_en : boolean := false;
  signal p_wr   : integer := 0;  -- probability (percent) that the producer offers a word
  signal p_rd   : integer := 0;  -- probability (percent) that the consumer is ready

  -- Latency measurement
  signal lat_armed : boolean := false;
  signal lat_t0    : time := 0 ps;
  signal lat_t0_set : boolean := false;
  signal lat_done  : boolean := false;
  signal lat_value : natural := 0;

  -- Coverage flags, each driven by one process
  signal cov_full_refused : boolean := false;
  signal cov_empty_ready  : boolean := false;
  signal cov_wl_loose     : boolean := false;
  signal cov_rl_loose     : boolean := false;
  signal cov_stall        : boolean := false;
  signal cov_reset_words  : boolean := false;
  signal cov_order0       : boolean := false;
  signal cov_order1       : boolean := false;
  signal cov_order2       : boolean := false;
  signal cov_levels       : boolean := false;
  signal cov_wrap         : boolean := false;

  -- Expected data for the word with this sequence number.
  function word(n : natural) return std_logic_vector is
    constant K1 : unsigned(31 downto 0) := x"9E3779B1";
    constant K2 : unsigned(31 downto 0) := x"85EBCA6B";
    variable h : unsigned(31 downto 0);
    variable r : std_logic_vector(WIDTH - 1 downto 0);
  begin
    h := resize(to_unsigned(n + 1, 32) * K1, 32);
    h := h xor shift_right(h, 15);
    h := resize(h * K2, 32);
    h := h xor shift_right(h, 13);
    for i in 0 to WIDTH - 1 loop
      r(i) := h(i mod 32) xor h((i / 32 + 7) mod 32);
    end loop;
    return r;
  end function word;

  function ones(v : std_logic_vector) return natural is
    variable c : natural := 0;
  begin
    for i in v'range loop
      if v(i) = '1' then
        c := c + 1;
      end if;
    end loop;
    return c;
  end function ones;
begin

  dut : entity work.async_fifo
    generic map (WIDTH => WIDTH, DEPTH => DEPTH, SYNC_STAGES => SYNC_STAGES)
    port map (
      wr_clk_i   => wr_clk,
      wr_rst_n_i => wr_rst_n,
      wr_valid_i => wr_valid,
      wr_ready_o => wr_ready,
      wr_data_i  => wr_data,
      wr_level_o => wr_level,
      rd_clk_i   => rd_clk,
      rd_rst_n_i => rd_rst_n,
      rd_valid_o => rd_valid,
      rd_ready_i => rd_ready,
      rd_data_o  => rd_data,
      rd_level_o => rd_level
    );

  -- Clocks. Both run forever; the simulation ends with finish.
  p_wr_clk : process
  begin
    wr_clk <= '0';
    wait for (WR_PS - WR_PS / 2) * 1 ps;
    loop
      wr_clk <= '1';
      wait for (WR_PS / 2) * 1 ps;
      wr_clk <= '0';
      wait for (WR_PS - WR_PS / 2) * 1 ps;
    end loop;
  end process p_wr_clk;

  p_rd_clk : process
  begin
    rd_clk <= '0';
    wait for (RD_PHASE_PS + RD_PS - RD_PS / 2) * 1 ps;
    loop
      rd_clk <= '1';
      wait for (RD_PS / 2) * 1 ps;
      rd_clk <= '0';
      wait for (RD_PS - RD_PS / 2) * 1 ps;
    end loop;
  end process p_rd_clk;

  -- Producer: random offers, a word is held until accepted. Data depends on the sequence number.
  wr_data <= word(wr_count);

  p_prod : process (wr_clk)
    variable s1 : positive := SEED;
    variable s2 : positive := 7 * SEED + 1;
    variable r  : real;
    variable sent : natural;
  begin
    if rising_edge(wr_clk) then
      if wr_rst_n = '0' then
        wr_valid <= '0';
      elsif wr_valid = '1' and wr_ready = '0' then
        null;  -- hold the offer until it is accepted
      else
        sent := wr_count;
        if wr_valid = '1' then
          sent := sent + 1;  -- the word offered now is accepted on this edge
        end if;
        uniform(s1, s2, r);
        if r * 100.0 < real(p_wr) and sent < wr_limit then
          wr_valid <= '1';
        else
          wr_valid <= '0';
        end if;
      end if;
    end if;
  end process p_prod;

  -- Consumer: random ready.
  p_cons : process (rd_clk)
    variable s1 : positive := 3 * SEED + 5;
    variable s2 : positive := 11 * SEED + 2;
    variable r  : real;
  begin
    if rising_edge(rd_clk) then
      uniform(s1, s2, r);
      if r * 100.0 < real(p_rd) then
        rd_ready <= '1';
      else
        rd_ready <= '0';
      end if;
    end if;
  end process p_cons;

  -- Write-side monitor: counts transfers, checks wr_level_o against the true occupancy.
  p_wr_mon : process (wr_clk)
    variable occ : integer;
  begin
    if rising_edge(wr_clk) then
      if wr_rst_n = '0' then
        wr_count <= 0;
      else
        if wr_valid = '1' and wr_ready = '1' then
          wr_count <= wr_count + 1;
          if lat_armed and wr_count = 0 and not lat_t0_set then
            lat_t0     <= now;
            lat_t0_set <= true;
          end if;
        end if;
      end if;
      if chk_en then
        occ := wr_count - rd_count;
        assert to_integer(unsigned(wr_level)) >= occ
          report "wr_level_o below the true occupancy: level=" & integer'image(to_integer(unsigned(wr_level)))
                 & " true=" & integer'image(occ)
          severity failure;
        if to_integer(unsigned(wr_level)) > occ then
          cov_wl_loose <= true;
        end if;
        if wr_valid = '1' and wr_ready = '0' and occ = DEPTH then
          cov_full_refused <= true;
        end if;
      end if;
    end if;
  end process p_wr_mon;

  -- Read-side monitor: scoreboard, rd_valid_o and rd_level_o against the true occupancy,
  -- output stability, latency measurement.
  p_rd_mon : process (rd_clk)
    variable occ        : integer;
    variable stalled    : boolean := false;
    variable stall_len  : natural := 0;
    variable prev_data  : std_logic_vector(WIDTH - 1 downto 0);
    variable lat_cnt    : natural := 0;
  begin
    if rising_edge(rd_clk) then
      if rd_rst_n = '0' then
        rd_count <= 0;
        stalled  := false;
        stall_len := 0;
      else
        -- output stability: a stalled word stays valid and unchanged
        if stalled then
          assert rd_valid = '1' and rd_data = prev_data
            report "rd_valid_o or rd_data_o changed while the word was not read"
            severity failure;
        end if;
        stalled := rd_valid = '1' and rd_ready = '0';
        prev_data := rd_data;
        if stalled then
          stall_len := stall_len + 1;
          if stall_len >= 4 then
            cov_stall <= true;
          end if;
        else
          stall_len := 0;
        end if;

        if rd_valid = '1' and rd_ready = '1' then
          assert rd_data = word(rd_count)
            report "data mismatch on word " & integer'image(rd_count)
            severity failure;
          rd_count <= rd_count + 1;
        end if;

        -- latency of one word crossing an empty FIFO: read edges after the write edge,
        -- up to and including the first edge where rd_valid_o is seen high
        if lat_armed and lat_t0_set and now > lat_t0 and not lat_done then
          lat_cnt := lat_cnt + 1;
          if rd_valid = '1' then
            lat_done  <= true;
            lat_value <= lat_cnt;
          end if;
        end if;
      end if;
      if chk_en then
        occ := wr_count - rd_count;
        if rd_valid = '1' then
          assert occ >= 1
            report "rd_valid_o high but the FIFO is empty (underflow)"
            severity failure;
        end if;
        assert to_integer(unsigned(rd_level)) <= occ
          report "rd_level_o above the true occupancy: level=" & integer'image(to_integer(unsigned(rd_level)))
                 & " true=" & integer'image(occ)
          severity failure;
        if to_integer(unsigned(rd_level)) < occ then
          cov_rl_loose <= true;
        end if;
        if rd_ready = '1' and rd_valid = '0' and occ = 0 then
          cov_empty_ready <= true;
        end if;
      end if;
    end if;
  end process p_rd_mon;

  -- True occupancy: never below 0, never above DEPTH. Level and wrap coverage.
  p_occ_mon : process (wr_count, rd_count)
    variable occ     : integer;
    variable seen    : std_logic_vector(0 to DEPTH) := (others => '0');
    variable max_wr  : natural := 0;
    variable max_rd  : natural := 0;
  begin
    if chk_en then
      occ := wr_count - rd_count;
      assert occ >= 0
        report "underflow: more words read than written"
        severity failure;
      assert occ <= DEPTH
        report "overflow: occupancy " & integer'image(occ) & " above DEPTH"
        severity failure;
      seen(occ) := '1';
      if ones(seen) = DEPTH + 1 then
        cov_levels <= true;
      end if;
    end if;
    max_wr := maximum(max_wr, wr_count);
    max_rd := maximum(max_rd, rd_count);
    if max_wr >= 2 * DEPTH and max_rd >= 2 * DEPTH then
      cov_wrap <= true;
    end if;
  end process p_occ_mon;

  -- Gray property: each crossing bus changes by one bit at most per source edge.
  -- Sampled on its own source clock, so two consecutive samples are one source edge apart.
  p_gray_wr : process (wr_clk)
    alias wr_gray_x is <<signal .async_fifo_tb.dut.wr_gray_q : std_logic_vector>>;
    variable prev : std_logic_vector(ADDR_W downto 0) := (others => '0');
  begin
    if rising_edge(wr_clk) then
      if chk_en then
        assert ones(wr_gray_x xor prev) <= 1
          report "wr_gray crossing bus changed by more than one bit"
          severity failure;
      end if;
      prev := wr_gray_x;
    end if;
  end process p_gray_wr;

  p_gray_rd : process (rd_clk)
    alias rd_gray_x is <<signal .async_fifo_tb.dut.rd_gray_q : std_logic_vector>>;
    variable prev : std_logic_vector(ADDR_W downto 0) := (others => '0');
  begin
    if rising_edge(rd_clk) then
      if chk_en then
        assert ones(rd_gray_x xor prev) <= 1
          report "rd_gray crossing bus changed by more than one bit"
          severity failure;
      end if;
      prev := rd_gray_x;
    end if;
  end process p_gray_rd;

  -- Test sequence.
  p_ctrl : process
    variable tx0, tx1 : natural;
    variable rate     : real;

    procedure wait_slow(n : natural) is
    begin
      wait for (n * SLOW_PS) * 1 ps;
    end procedure;

    procedure phase(w, r : integer; n : natural) is
    begin
      p_wr <= w;
      p_rd <= r;
      wait_slow(n);
    end procedure;

    -- Both resets are asserted together for at least one edge of each clock (SPEC section 4).
    -- order 0: released together, 1: write domain first, 2: read domain first.
    procedure do_reset(order : integer) is
    begin
      chk_en <= false;
      if wr_count - rd_count > 0 then
        cov_reset_words <= true;
      end if;
      wr_rst_n <= '0';
      rd_rst_n <= '0';
      wait_slow(3);
      case order is
        when 0 =>
          wr_rst_n <= '1';
          rd_rst_n <= '1';
          cov_order0 <= true;
        when 1 =>
          wr_rst_n <= '1';
          wait_slow(3);
          rd_rst_n <= '1';
          cov_order1 <= true;
        when others =>
          rd_rst_n <= '1';
          wait_slow(3);
          wr_rst_n <= '1';
          cov_order2 <= true;
      end case;
      wait_slow(SYNC_STAGES + 4);  -- flush the synchronizers
      chk_en <= true;
    end procedure;
  begin
    do_reset(0);

    -- 1. One word through an empty FIFO: latency.
    p_wr <= 100;
    p_rd <= 100;
    wr_limit <= 1;
    lat_armed <= true;
    wait until lat_done for 1000 * SLOW_PS * 1 ps;
    assert lat_done report "latency: the word never became readable" severity failure;
    assert lat_value >= SYNC_STAGES + 1 and lat_value <= SYNC_STAGES + 2
      report "latency out of range: " & integer'image(lat_value) & " read edges"
      severity failure;
    wait_slow(4);
    wr_limit <= natural'high;

    -- 2. Streaming at full rate (measured only when the spec promises it).
    phase(100, 100, 100);
    tx0 := wr_count;
    phase(100, 100, PHASE_LEN - 100);
    tx1 := wr_count;
    rate := real(tx1 - tx0) / real(PHASE_LEN - 100);
    report "transfers: full-rate phase " & integer'image(tx1 - tx0) & " words in "
           & integer'image(PHASE_LEN - 100) & " slow-clock cycles";
    if FULL_RATE_CHECK then
      assert rate >= 0.98
        report "full rate not reached: " & real'image(rate) & " words per cycle"
        severity failure;
    end if;

    -- 3. Reader stopped: the FIFO fills up and refuses writes. Reset with words stored.
    phase(100, 0, PHASE_LEN);
    do_reset(1);

    -- 4. Writer stopped: the FIFO drains and reads are offered while empty.
    phase(100, 100, PHASE_LEN / 4);
    phase(0, 100, PHASE_LEN);

    -- 5. Mixed traffic, then a reset with the read domain released first.
    phase(50, 50, PHASE_LEN);
    phase(100, 10, PHASE_LEN);
    do_reset(2);
    phase(10, 100, PHASE_LEN);
    phase(100, 100, PHASE_LEN);

    -- 6. Final drain, then the end-of-test checks.
    phase(0, 100, PHASE_LEN);
    assert wr_count = rd_count
      report "words left in the FIFO after the final drain"
      severity failure;

    assert cov_full_refused report "coverage: no write offered while full" severity failure;
    assert cov_empty_ready  report "coverage: no read offered while empty" severity failure;
    assert cov_wl_loose     report "coverage: wr_level_o never above the true occupancy" severity failure;
    assert cov_rl_loose     report "coverage: rd_level_o never below the true occupancy" severity failure;
    assert cov_stall        report "coverage: no stall of 4 cycles or more" severity failure;
    assert cov_reset_words  report "coverage: no reset with words stored" severity failure;
    assert cov_order0 and cov_order1 and cov_order2
      report "coverage: not every reset release order was run" severity failure;
    assert cov_levels       report "coverage: not every occupancy level reached" severity failure;
    assert cov_wrap         report "coverage: pointers did not wrap twice" severity failure;

    report "coverage: latency=" & integer'image(lat_value)
           & " read edges, all items reached";
    report "TEST PASSED";
    finish;
  end process p_ctrl;

end architecture sim;