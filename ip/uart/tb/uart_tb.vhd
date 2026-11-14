-- uart_tb: self-checking testbench for uart (SPEC section 9).
--
-- A: loopback of the top level `uart` (txd_o to rxd_i). A monitor checks the transmitted
--    line cycle by cycle (start at the transfer edge, transitions on multiples of BIT_CLKS,
--    bit values, exact back-to-back timing). A consumer checks every received word.
-- B: a second receiver driven by a line model that can change the bit time and inject
--    faults: baud mismatch, parity error, framing error, break, glitches, false start,
--    overrun, reset in the middle of a frame.
-- Prints TEST PASSED and finishes only if every check passes and every coverage item was hit.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;
use std.env.all;
use work.uart_pkg.all;

entity uart_tb is
  generic (
    CLK_FREQ_HZ : positive := 100_000_000;
    BAUD        : positive := 1_000_000;
    DATA_BITS   : positive := 8;
    PARITY      : natural  := 0;
    STOP_BITS   : positive := 1;
    WORDS       : positive := 40;  -- words in each of the two loopback phases
    SEED        : positive := 1
  );
end entity uart_tb;

architecture sim of uart_tb is
  constant CLK_PER    : time    := 1 sec / CLK_FREQ_HZ;
  constant CLK_PS     : real    := real(CLK_PER / 1 ps);
  constant N          : positive := bit_clks(CLK_FREQ_HZ, BAUD);
  constant VS         : positive := vote_offset(N);
  constant P_LEN      : natural := parity_len(PARITY);
  constant NBITS      : positive := 1 + DATA_BITS + P_LEN + STOP_BITS;
  constant NOM_BIT    : real    := real(N) * CLK_PS;           -- one bit, in ps
  constant FRAME_T    : time    := NBITS * N * CLK_PER;
  constant MAXW       : positive := 2048;

  subtype word_t is std_logic_vector(15 downto 0);
  type word_arr is array (0 to MAXW - 1) of word_t;
  type int_arr  is array (0 to MAXW - 1) of integer;
  type bit_arr  is array (0 to MAXW - 1) of std_logic;

  function pad(x : std_logic_vector) return word_t is
  begin
    return std_logic_vector(resize(unsigned(x), 16));
  end function pad;

  function to_t(x : real) return time is
  begin
    return integer(round(x)) * 1 ps;
  end function to_t;

  function rnd_word(r : real) return word_t is
  begin
    return std_logic_vector(to_unsigned(integer(floor(r * real(2 ** DATA_BITS))), 16));
  end function rnd_word;

  -- Level of bit k of a frame (0 = start). flip inverts the parity bit, stop_lo forces
  -- stop bit number stop_lo (1 or 2) low.
  function bit_level(k : natural; d : word_t; flip : boolean; stop_lo : natural) return std_logic is
    variable p : std_logic;
  begin
    if k = 0 then
      return '0';
    elsif k <= DATA_BITS then
      return d(k - 1);
    elsif k <= DATA_BITS + P_LEN then
      p := parity_bit(d(DATA_BITS - 1 downto 0), PARITY);
      if flip then
        p := not p;
      end if;
      return p;
    else
      if stop_lo = k - (DATA_BITS + P_LEN) then
        return '0';
      end if;
      return '1';
    end if;
  end function bit_level;

  type frm_t is record
    data    : word_t;
    bit_ps  : real;      -- bit time, ps
    flip    : boolean;   -- invert the parity bit
    stop_lo : natural;   -- 0 none, else this stop bit is sent low
    gl_at   : real;      -- glitch start in ps after the start edge, negative for none
    gl_w    : real;      -- glitch width in ps
    gap     : real;      -- idle (high) time after the frame, ps
    narrow  : boolean;   -- each bit is valid only in the middle 40 percent, inverted elsewhere
  end record frm_t;

  function nominal(d : word_t) return frm_t is
  begin
    return (data => d, bit_ps => NOM_BIT, flip => false, stop_lo => 0,
            gl_at => -1.0, gl_w => 0.0, gap => 0.0, narrow => false);
  end function nominal;

  -- Drives one frame on the line. Optional glitch inverts the line for gl_w ps.
  procedure send_frame(signal ln : out std_logic; fr : frm_t) is
    type rarr is array (0 to 3 * NBITS + 4) of real;
    variable ts   : rarr;
    variable cnt  : natural := 0;
    variable tmp  : real;
    variable t_prev, t_now, k : integer;
    variable lvl  : std_logic;
    variable frac : real;
  begin
    for i in 0 to NBITS loop
      ts(cnt) := real(i) * fr.bit_ps;
      cnt := cnt + 1;
    end loop;
    if fr.narrow then
      for i in 1 to NBITS - 2 loop
        ts(cnt) := (real(i) + 0.3) * fr.bit_ps;
        ts(cnt + 1) := (real(i) + 0.7) * fr.bit_ps;
        cnt := cnt + 2;
      end loop;
    end if;
    if fr.gl_at >= 0.0 then
      ts(cnt) := fr.gl_at;
      cnt := cnt + 1;
      ts(cnt) := fr.gl_at + fr.gl_w;
      cnt := cnt + 1;
    end if;
    for i in 0 to cnt - 2 loop            -- sort the event times
      for j in 0 to cnt - 2 - i loop
        if ts(j) > ts(j + 1) then
          tmp := ts(j); ts(j) := ts(j + 1); ts(j + 1) := tmp;
        end if;
      end loop;
    end loop;
    t_prev := 0;
    for i in 0 to cnt - 1 loop
      t_now := integer(round(ts(i)));
      if t_now > t_prev then
        wait for (t_now - t_prev) * 1 ps;
        t_prev := t_now;
      end if;
      k := integer(floor(ts(i) / fr.bit_ps + 1.0e-9));
      if k >= NBITS then
        lvl := '1';
      else
        lvl := bit_level(k, fr.data, fr.flip, fr.stop_lo);
      end if;
      if fr.narrow and k >= 1 and k <= NBITS - 2 then
        frac := ts(i) / fr.bit_ps - real(k);
        if frac < 0.3 - 1.0e-6 or frac >= 0.7 - 1.0e-6 then
          lvl := not lvl;
        end if;
      end if;
      if fr.gl_at >= 0.0 and ts(i) >= fr.gl_at - 1.0e-6 and ts(i) < fr.gl_at + fr.gl_w - 1.0e-6 then
        lvl := not lvl;
      end if;
      ln <= lvl;
    end loop;
    if fr.gap > 0.0 then
      wait for to_t(fr.gap);
    end if;
  end procedure send_frame;

  signal clk     : std_logic := '0';
  signal rst_n   : std_logic := '0';
  signal rst2_n  : std_logic := '0';
  signal cyc     : natural := 0;

  -- A: loopback
  signal a_tx_valid, a_tx_ready, a_txd : std_logic := '0';
  signal a_tx_data  : std_logic_vector(DATA_BITS - 1 downto 0) := (others => '0');
  signal a_rx_valid, a_rx_ready, a_perr, a_ferr, a_ovr : std_logic;
  signal a_rx_data  : std_logic_vector(DATA_BITS - 1 downto 0);
  signal lp_mode    : natural := 0;        -- 0 full rate, 1 random gaps, 3 idle time before each word
  signal cons_mode  : natural := 0;        -- 0 always ready, 1 random
  signal lp_target  : natural := 0;
  signal sent_s     : natural := 0;
  signal lp_rx_n    : natural := 0;
  signal tx_log     : word_arr := (others => (others => '0'));
  signal tx_xfer    : int_arr  := (others => 0);
  signal tx_off     : int_arr  := (others => 0);

  -- B: receiver under fault injection
  signal line2      : std_logic := '1';
  signal b_valid, b_perr, b_ferr, b_ovr : std_logic;
  signal b_ready    : std_logic;
  signal b_mode     : natural := 0;        -- 0 always ready, 1 never ready
  signal b_data     : std_logic_vector(DATA_BITS - 1 downto 0);
  signal b_cnt      : natural := 0;
  signal b_ovr_cnt  : natural := 0;
  signal b_dat      : word_arr := (others => (others => '0'));
  signal b_pe       : bit_arr  := (others => '0');
  signal b_fe       : bit_arr  := (others => '0');

  signal tx_frames  : natural := 0;        -- frames seen on txd_o by the monitor
  signal tx_gap0    : natural := 0;        -- frames that followed the previous one with no gap
  signal tx_gapn    : natural := 0;        -- frames that followed after an idle time
begin

  clk <= not clk after CLK_PER / 2;

  p_cyc : process (clk)
  begin
    if rising_edge(clk) then
      cyc <= cyc + 1;
    end if;
  end process p_cyc;

  dut_a : entity work.uart
    generic map (CLK_FREQ_HZ => CLK_FREQ_HZ, BAUD => BAUD, DATA_BITS => DATA_BITS,
                 PARITY => PARITY, STOP_BITS => STOP_BITS)
    port map (clk_i => clk, rst_n_i => rst_n,
              tx_valid_i => a_tx_valid, tx_ready_o => a_tx_ready, tx_data_i => a_tx_data,
              txd_o => a_txd, rxd_i => a_txd,
              rx_valid_o => a_rx_valid, rx_ready_i => a_rx_ready, rx_data_o => a_rx_data,
              rx_parity_err_o => a_perr, rx_frame_err_o => a_ferr, rx_overrun_o => a_ovr);

  dut_b : entity work.uart_rx
    generic map (CLK_FREQ_HZ => CLK_FREQ_HZ, BAUD => BAUD, DATA_BITS => DATA_BITS,
                 PARITY => PARITY, STOP_BITS => STOP_BITS)
    port map (clk_i => clk, rst_n_i => rst2_n, rxd_i => line2,
              rx_valid_o => b_valid, rx_ready_i => b_ready, rx_data_o => b_data,
              rx_parity_err_o => b_perr, rx_frame_err_o => b_ferr, rx_overrun_o => b_ovr);

  b_ready <= '1' when b_mode = 0 else '0';

  ---------------------------------------------------------------------------
  -- A: producer of the loopback
  ---------------------------------------------------------------------------
  p_prod : process (clk)
    variable s1, s2 : positive := SEED + 11;
    variable s3     : positive := SEED + 23;
    variable r      : real;
    variable n_sent : natural := 0;
    variable xfer   : boolean;
    variable want   : boolean;
    variable delay  : integer := 0;
  begin
    if rising_edge(clk) then
      if rst_n = '0' then
        a_tx_valid <= '0';
      else
        xfer := (a_tx_valid = '1' and a_tx_ready = '1');
        if xfer then
          tx_log(n_sent)  <= pad(a_tx_data);
          tx_xfer(n_sent) <= cyc;
          n_sent := n_sent + 1;
          sent_s <= n_sent;
          delay  := (NBITS + 3) * N;   -- used by lp_mode 3 only
        end if;
        if delay > 0 then
          delay := delay - 1;
        end if;
        if a_tx_valid = '0' or xfer then
          uniform(s1, s3, r);
          want := n_sent < lp_target and (lp_mode = 0 or (lp_mode = 1 and r < 2.0 / real(NBITS * N))
                                          or (lp_mode = 3 and delay = 0));
          if want then
            uniform(s1, s3, r);
            a_tx_data  <= rnd_word(r)(DATA_BITS - 1 downto 0);
            a_tx_valid <= '1';
            tx_off(n_sent) <= cyc;
          else
            a_tx_valid <= '0';
          end if;
        end if;
      end if;
    end if;
  end process p_prod;

  ---------------------------------------------------------------------------
  -- A: consumer of the loopback
  ---------------------------------------------------------------------------
  p_cons : process (clk)
    variable s1 : positive := SEED + 31;
    variable s2 : positive := SEED + 37;
    variable r  : real;
    variable nrx  : natural := 0;
  begin
    if rising_edge(clk) then
      if rst_n = '1' then
        assert a_ovr = '0'
          report "loopback: overrun" severity failure;
        if a_rx_valid = '1' and a_rx_ready = '1' then
          assert nrx < sent_s
            report "loopback: received a word that was never sent" severity failure;
          assert a_rx_data = tx_log(nrx)(DATA_BITS - 1 downto 0)
            report "loopback: received word differs from the sent word, index " & integer'image(nrx)
            severity failure;
          assert a_perr = '0' and a_ferr = '0'
            report "loopback: error flag set on a good word" severity failure;
          nrx := nrx + 1;
          lp_rx_n <= nrx;
        end if;
      end if;
      uniform(s1, s2, r);
      if cons_mode = 0 or r < 0.5 then
        a_rx_ready <= '1';
      else
        a_rx_ready <= '0';
      end if;
    end if;
  end process p_cons;

  ---------------------------------------------------------------------------
  -- A: monitor of the transmitted line (SPEC 5.1)
  ---------------------------------------------------------------------------
  p_txmon : process (clk)
    variable prev      : std_logic := '1';
    variable cur       : std_logic;
    variable start     : integer := 0;
    variable frames    : natural := 0;
    variable rel       : integer;
    variable expect_x  : integer;
    variable g0, gn    : natural := 0;
  begin
    if rising_edge(clk) then
      if rst_n = '1' then
        cur := a_txd;
        if cur /= prev then
          if cur = '0' and (frames = 0 or cyc - start >= NBITS * N) then
            assert frames < sent_s
              report "tx: line went low with no word transferred" severity failure;
            if frames = 0 then
              expect_x := tx_off(0) + 1;
            else
              expect_x := tx_off(frames) + 1;
              if start + NBITS * N - 1 > expect_x then
                expect_x := start + NBITS * N - 1;
              end if;
            end if;
            assert tx_xfer(frames) = expect_x
              report "tx: transfer at cycle " & integer'image(tx_xfer(frames)) & ", expected "
                     & integer'image(expect_x) & " (ready timing)" severity failure;
            assert cyc = tx_xfer(frames) + 1
              report "tx: start bit not at the transfer edge" severity failure;
            if frames > 0 then
              assert cyc - start >= NBITS * N
                report "tx: frame shorter than the nominal length" severity failure;
              if cyc - start = NBITS * N then
                g0 := g0 + 1;
              else
                gn := gn + 1;
              end if;
            end if;
            start  := cyc;
            frames := frames + 1;
            tx_frames <= frames;
            tx_gap0   <= g0;
            tx_gapn   <= gn;
          else
            assert (cyc - start) mod N = 0
              report "tx: line transition not on a multiple of BIT_CLKS" severity failure;
          end if;
        end if;
        prev := cur;
        if frames > 0 then
          rel := cyc - start;
          if rel >= 0 and rel < NBITS * N and rel mod N = N / 2 then
            assert cur = bit_level(rel / N, tx_log(frames - 1), false, 0)
              report "tx: wrong level for bit " & integer'image(rel / N) & " of frame "
                     & integer'image(frames - 1) severity failure;
          end if;
        end if;
      end if;
    end if;
  end process p_txmon;

  ---------------------------------------------------------------------------
  -- B: logger of the received words and stability checks of both outputs
  ---------------------------------------------------------------------------
  p_bmon : process (clk)
    variable nrx   : natural := 0;
    variable ovr : natural := 0;
    variable pa_v, pb_v : std_logic := '0';
    variable pa_r, pb_r : std_logic := '0';
    variable pa_d, pb_d : std_logic_vector(DATA_BITS - 1 downto 0) := (others => '0');
    variable pa_f, pb_f : std_logic_vector(1 downto 0) := "00";
  begin
    if rising_edge(clk) then
      if b_valid = '1' and b_ready = '1' then
        b_dat(nrx) <= pad(b_data);
        b_pe(nrx)  <= b_perr;
        b_fe(nrx)  <= b_ferr;
        nrx := nrx + 1;
        b_cnt <= nrx;
      end if;
      if b_ovr = '1' then
        ovr := ovr + 1;
        b_ovr_cnt <= ovr;
      end if;
      -- once valid is high, data and flags hold until the transfer (SPEC 4)
      if pb_v = '1' and pb_r = '0' and rst2_n = '1' then
        assert b_valid = '1' and b_data = pb_d and (b_perr & b_ferr) = pb_f
          report "rx(B): valid or data changed before the transfer" severity failure;
      end if;
      pb_v := b_valid; pb_r := b_ready; pb_d := b_data; pb_f := b_perr & b_ferr;
      if pa_v = '1' and pa_r = '0' and rst_n = '1' then
        assert a_rx_valid = '1' and a_rx_data = pa_d and (a_perr & a_ferr) = pa_f
          report "rx(A): valid or data changed before the transfer" severity failure;
      end if;
      pa_v := a_rx_valid; pa_r := a_rx_ready; pa_d := a_rx_data; pa_f := a_perr & a_ferr;
    end if;
  end process p_bmon;

  ---------------------------------------------------------------------------
  -- Control
  ---------------------------------------------------------------------------
  p_ctrl : process
    variable s1 : positive := SEED + 101;
    variable s2 : positive := SEED + 211;
    variable r  : real;
    variable fr : frm_t;
    variable d  : word_t;
    variable n0 : natural;
    variable eps : real;
    variable w  : natural;
    variable exp_d : word_arr;
    variable cov_loop, cov_mis, cov_par, cov_frm, cov_brk, cov_gl, cov_fs, cov_ovr, cov_rst : natural := 0;
    variable cov_g0, cov_gn : natural := 0;
    variable cov_pos : natural := 0;
    variable kk, o : integer;

    procedure rnd(variable x : out real) is
    begin
      uniform(s1, s2, x);
    end procedure rnd;

    procedure expect_rx(idx : natural; dd : word_t; pe, fe : std_logic; chk_pe : boolean; msg : string) is
    begin
      assert b_dat(idx)(DATA_BITS - 1 downto 0) = dd(DATA_BITS - 1 downto 0)
        report msg & ": wrong data" severity failure;
      assert b_fe(idx) = fe
        report msg & ": wrong frame error flag" severity failure;
      if chk_pe then
        assert b_pe(idx) = pe
          report msg & ": wrong parity error flag" severity failure;
      end if;
    end procedure expect_rx;

    procedure good_frame(msg : string) is
      variable dd : word_t;
      variable x  : real;
      variable m0 : natural;
    begin
      rnd(x);
      dd := rnd_word(x);
      m0 := b_cnt;
      fr := nominal(dd);
      fr.gap := 3.0 * NOM_BIT;
      send_frame(line2, fr);
      assert b_cnt = m0 + 1
        report msg & ": good frame not received (count " & integer'image(b_cnt - m0) & ")"
        severity failure;
      expect_rx(m0, dd, '0', '0', true, msg);
    end procedure good_frame;
  begin
    line2 <= '1';
    ---------------------------------------------------------------- reset
    rst_n  <= '0';
    rst2_n <= '0';
    wait for 5 * CLK_PER;
    assert a_tx_ready = '0' and a_txd = '1' and a_rx_valid = '0'
      report "reset: outputs not idle during reset" severity failure;
    wait until falling_edge(clk);
    rst_n  <= '1';
    rst2_n <= '1';
    wait for 4 * CLK_PER;
    assert a_tx_ready = '1'
      report "reset: tx_ready not high after reset" severity failure;
    rnd(r);
    wait for to_t(r * CLK_PS);

    ---------------------------------------------------------------- A: loopback
    cons_mode <= 0;
    lp_mode   <= 0;
    lp_target <= WORDS;
    wait until lp_rx_n = WORDS for (WORDS + 4) * 2 * FRAME_T;
    assert lp_rx_n = WORDS
      report "loopback phase 1: " & integer'image(lp_rx_n) & " of " & integer'image(WORDS)
             & " words received" severity failure;
    cons_mode <= 1;
    lp_mode   <= 1;
    lp_target <= 2 * WORDS;
    wait until lp_rx_n = 2 * WORDS for (WORDS + 4) * 4 * FRAME_T;
    assert lp_rx_n = 2 * WORDS
      report "loopback phase 2: " & integer'image(lp_rx_n) & " of " & integer'image(2 * WORDS)
             & " words received" severity failure;
    -- three words each sent a few bit times after the previous frame: idle time on the line
    lp_mode   <= 3;
    lp_target <= 2 * WORDS + 3;
    wait until lp_rx_n = 2 * WORDS + 3 for 4 * (NBITS + 6) * N * CLK_PER + 3 * FRAME_T;
    assert lp_rx_n = 2 * WORDS + 3
      report "loopback phase 3: words missing" severity failure;
    wait for 2 * FRAME_T;
    assert sent_s = 2 * WORDS + 3 and tx_frames = 2 * WORDS + 3
      report "tx: frames on the line " & integer'image(tx_frames) & ", words sent "
             & integer'image(sent_s) severity failure;
    assert tx_gap0 > 0 and tx_gapn > 0
      report "coverage: no back-to-back frame or no frame after an idle time" severity failure;
    cov_loop := lp_rx_n;
    cov_g0 := tx_gap0;
    cov_gn := tx_gapn;

    ---------------------------------------------------------------- B: baud mismatch
    for sgn in 0 to 2 loop
      if sgn = 0 then
        eps := 0.02;
      elsif sgn = 1 then
        eps := -0.02;
      else
        eps := 0.0;
      end if;
      rnd(r);
      wait for to_t(r * CLK_PS);
      n0 := b_cnt;
      for i in 0 to 11 loop
        rnd(r);
        d := rnd_word(r);
        exp_d(i) := d;
        fr := nominal(d);
        fr.bit_ps := NOM_BIT * (1.0 + eps);
        if sgn = 2 then            -- 0 percent: random gaps instead of back to back
          rnd(r);
          fr.gap := r * 3.0 * NOM_BIT;
        end if;
        if i = 11 then
          fr.gap := 4.0 * NOM_BIT;
        end if;
        send_frame(line2, fr);
      end loop;
      assert b_cnt = n0 + 12
        report "mismatch: " & integer'image(b_cnt - n0) & " of 12 words received" severity failure;
      for i in 0 to 11 loop
        expect_rx(n0 + i, exp_d(i), '0', '0', true, "mismatch");
      end loop;
      cov_mis := cov_mis + 12;
    end loop;

    ---------------------------------------------------------------- B: parity error
    if PARITY /= 0 then
      for i in 0 to 3 loop
        rnd(r);
        d := rnd_word(r);
        n0 := b_cnt;
        fr := nominal(d);
        fr.flip := true;
        fr.gap  := 3.0 * NOM_BIT;
        send_frame(line2, fr);
        assert b_cnt = n0 + 1
          report "parity error: word not delivered" severity failure;
        expect_rx(n0, d, '1', '0', true, "parity error");
        cov_par := cov_par + 1;
        good_frame("after parity error");
      end loop;
    end if;

    ---------------------------------------------------------------- B: framing error
    for sl in 1 to STOP_BITS loop
      for i in 0 to 2 loop
        rnd(r);
        d := rnd_word(r);
        n0 := b_cnt;
        fr := nominal(d);
        fr.stop_lo := sl;
        fr.gap := 3.0 * NOM_BIT;
        send_frame(line2, fr);
        assert b_cnt = n0 + 1
          report "framing error: word not delivered" severity failure;
        expect_rx(n0, d, '0', '1', PARITY /= 0, "framing error");
        cov_frm := cov_frm + 1;
        good_frame("after framing error");
      end loop;
    end loop;

    ---------------------------------------------------------------- B: break
    for i in 0 to 1 loop
      n0 := b_cnt;
      line2 <= '0';
      wait for to_t(real(NBITS + 3) * NOM_BIT);
      assert b_cnt = n0 + 1
        report "break: expected exactly one word, got " & integer'image(b_cnt - n0) severity failure;
      assert b_fe(n0) = '1' and b_dat(n0)(DATA_BITS - 1 downto 0) = (DATA_BITS - 1 downto 0 => '0')
        report "break: expected data 0 with framing error" severity failure;
      line2 <= '1';
      wait for to_t(3.0 * NOM_BIT);
      assert b_cnt = n0 + 1
        report "break: extra word when the line came back" severity failure;
      cov_brk := cov_brk + 1;
      good_frame("after break");
    end loop;

    ---------------------------------------------------------------- B: glitches inside frames
    -- Directed: glitches of 1 and VS cycles placed on and around the three vote samples of
    -- the start bit, the first data bit and the last stop bit. The vote must remove them.
    for kb in 0 to 2 loop
      if kb = 0 then
        kk := 0;
      elsif kb = 1 then
        kk := 1;
      else
        kk := NBITS - 1;
      end if;
      for wi in 0 to 1 loop
        for oi in 0 to 8 loop
          if wi = 0 then
            w := 1;
            case oi is
              when 0 => o := -VS - 1;
              when 1 => o := -VS;
              when 2 => o := -VS + 1;
              when 3 => o := -1;
              when 4 => o := 0;
              when 5 => o := 1;
              when 6 => o := VS - 1;
              when 7 => o := VS;
              when others => o := VS + 1;
            end case;
          else
            w := VS;
            o := -VS - 1 + oi * ((2 * VS + 2) / 8);
          end if;
          rnd(r);
          d := rnd_word(r);
          n0 := b_cnt;
          fr := nominal(d);
          rnd(r);
          fr.gl_at := (real(kk * N + N / 2 + o) + r) * CLK_PS;
          fr.gl_w  := real(w) * CLK_PS;
          fr.gap   := 3.0 * NOM_BIT;
          send_frame(line2, fr);
          assert b_cnt = n0 + 1
            report "glitch: " & integer'image(b_cnt - n0) & " words instead of 1 (bit "
                   & integer'image(kk) & ", width " & integer'image(w) & ", offset "
                   & integer'image(o) & ")" severity failure;
          expect_rx(n0, d, '0', '0', true, "glitch of " & integer'image(w) & " cycles");
          cov_gl := cov_gl + 1;
        end loop;
      end loop;
    end loop;

    ---------------------------------------------------------------- B: sample position
    -- Each bit is valid only in the middle 40 percent: the three samples must all fall there.
    for i in 0 to 7 loop
      rnd(r);
      d := rnd_word(r);
      n0 := b_cnt;
      fr := nominal(d);
      fr.narrow := true;
      fr.gap := 3.0 * NOM_BIT;
      rnd(r);
      wait for to_t(r * CLK_PS);
      send_frame(line2, fr);
      assert b_cnt = n0 + 1
        report "sample position: word not received" severity failure;
      expect_rx(n0, d, '0', '0', true, "sample position");
      cov_pos := cov_pos + 1;
    end loop;

    ---------------------------------------------------------------- B: false start
    for i in 0 to 3 loop
      if i mod 2 = 0 then
        w := N / 4;
      else
        w := N / 2 - 1;
      end if;
      n0 := b_cnt;
      rnd(r);
      wait for to_t(r * CLK_PS);
      line2 <= '0';
      wait for to_t(real(w) * CLK_PS);
      line2 <= '1';
      wait for to_t(real(NBITS + 3) * NOM_BIT);
      assert b_cnt = n0
        report "false start: a glitch of " & integer'image(w) & " cycles gave a word" severity failure;
      cov_fs := cov_fs + 1;
      good_frame("after false start");
    end loop;

    ---------------------------------------------------------------- B: overrun
    b_mode <= 1;
    n0 := b_cnt;
    rnd(r);
    d := rnd_word(r);
    exp_d(0) := d;
    fr := nominal(d);
    send_frame(line2, fr);
    for i in 1 to 2 loop
      rnd(r);
      fr := nominal(rnd_word(r));
      if i = 2 then
        fr.gap := 3.0 * NOM_BIT;
      end if;
      send_frame(line2, fr);
    end loop;
    assert b_valid = '1' and b_data = d(DATA_BITS - 1 downto 0)
      report "overrun: the first word was not kept" severity failure;
    assert b_ovr_cnt = 2
      report "overrun: " & integer'image(b_ovr_cnt) & " pulses instead of 2" severity failure;
    assert b_cnt = n0
      report "overrun: word transferred while not ready" severity failure;
    b_mode <= 0;
    wait for 4 * CLK_PER;
    assert b_cnt = n0 + 1
      report "overrun: kept word not delivered" severity failure;
    expect_rx(n0, exp_d(0), '0', '0', true, "overrun");
    wait for to_t(2.0 * NOM_BIT);
    assert b_cnt = n0 + 1
      report "overrun: a dropped word came out" severity failure;
    cov_ovr := cov_ovr + 1;
    good_frame("after overrun");

    ---------------------------------------------------------------- B: reset
    -- frame cut by a reset, line stays high afterwards: no word
    n0 := b_cnt;
    line2 <= '0';
    wait for to_t(NOM_BIT);
    line2 <= '1';
    wait for to_t(0.5 * NOM_BIT);
    wait until falling_edge(clk);
    rst2_n <= '0';
    wait for 3 * CLK_PER;
    rst2_n <= '1';
    wait for to_t(real(NBITS + 3) * NOM_BIT);
    assert b_cnt = n0
      report "reset: the frame in progress was not abandoned" severity failure;
    good_frame("after reset in a frame");
    -- pending word dropped by reset
    b_mode <= 1;
    n0 := b_cnt;
    fr := nominal(rnd_word(0.37));
    fr.gap := 3.0 * NOM_BIT;
    send_frame(line2, fr);
    assert b_valid = '1' report "reset: no pending word to drop" severity failure;
    wait until falling_edge(clk);
    rst2_n <= '0';
    wait for 3 * CLK_PER;
    assert b_valid = '0' report "reset: valid still high in reset" severity failure;
    rst2_n <= '1';
    wait for 4 * CLK_PER;
    assert b_valid = '0' report "reset: pending word came back" severity failure;
    b_mode <= 0;
    -- line low when the reset is released: no start bit
    line2 <= '0';
    wait for to_t(2.0 * NOM_BIT);
    wait until falling_edge(clk);
    rst2_n <= '0';
    wait for 3 * CLK_PER;
    rst2_n <= '1';
    wait for to_t(real(NBITS + 3) * NOM_BIT);
    assert b_cnt = n0
      report "reset: low line at reset release taken for a start bit" severity failure;
    line2 <= '1';
    wait for to_t(2.0 * NOM_BIT);
    good_frame("after reset with low line");
    cov_rst := 3;

    ---------------------------------------------------------------- coverage and end
    assert cov_loop > 0 and cov_mis > 0 and cov_brk > 0 and cov_gl > 0 and cov_fs > 0
           and cov_ovr > 0 and cov_rst > 0 and cov_pos > 0 and cov_frm > 0 and (PARITY = 0 or cov_par > 0)
      report "coverage: an item was never hit" severity failure;
    report "coverage: loopback_words=" & integer'image(cov_loop)
           & " back_to_back=" & integer'image(cov_g0) & " after_idle=" & integer'image(cov_gn)
           & " mismatch_words=" & integer'image(cov_mis) & " parity_err=" & integer'image(cov_par)
           & " framing_err=" & integer'image(cov_frm) & " break=" & integer'image(cov_brk)
           & " glitch=" & integer'image(cov_gl) & " false_start=" & integer'image(cov_fs)
           & " sample_pos=" & integer'image(cov_pos) & " overrun=" & integer'image(cov_ovr)
           & " reset=" & integer'image(cov_rst)
           severity note;
    report "transfers: BIT_CLKS=" & integer'image(N) & " tx_frames=" & integer'image(tx_frames)
           & " rx_words_B=" & integer'image(b_cnt) severity note;
    report "TEST PASSED" severity note;
    finish;
  end process p_ctrl;

end architecture sim;