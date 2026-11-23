-- crc_tb: self-checking testbench for crc (SPEC section 9).
--
-- Two references, written differently from the RTL:
--   * a per-cycle monitor with its own register model (reset, clear, start, valid priorities)
--     compares crc_o after every clock edge, including idle cycles with junk inputs;
--   * at the end of each message crc_o is compared with a polynomial long division of the
--     whole message (a different algorithm from the shift register).
-- When CHECK is given and DATA_WIDTH divides 72, the message "123456789" is sent and
-- crc_o must equal the catalogue check value.
-- Prints TEST PASSED and finishes only if every check passes and every coverage item was hit.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;
use std.env.all;
use work.crc_pkg.all;

entity crc_tb is
  generic (
    CRC_WIDTH  : integer := 32;
    DATA_WIDTH : integer := 8;
    POLY       : string  := "04C11DB7";
    INIT       : string  := "FFFFFFFF";
    XOROUT     : string  := "FFFFFFFF";
    REFIN      : boolean := true;
    REFOUT     : boolean := true;
    CHECK      : string  := "CBF43926";  -- catalogue check value of "123456789", "" to skip
    MESSAGES   : positive := 60;         -- random messages, at least 10
    SEED       : positive := 1
  );
end entity crc_tb;

architecture sim of crc_tb is
  constant W      : integer := CRC_WIDTH;
  constant DW     : integer := DATA_WIDTH;
  constant CLK_PER : time := 10 ns;
  constant MAXW   : positive := 72;   -- words of the longest message (check message, DW = 1)
  constant RANDW  : positive := 16;   -- words of the longest random message

  constant POLY_V   : std_logic_vector(W - 1 downto 0) := hex_to_slv(POLY, W);
  constant INIT_V   : std_logic_vector(W - 1 downto 0) := hex_to_slv(INIT, W);
  constant XOROUT_V : std_logic_vector(W - 1 downto 0) := hex_to_slv(XOROUT, W);

  subtype word_t is std_logic_vector(DW - 1 downto 0);
  type word_arr is array (0 to MAXW - 1) of word_t;

  signal clk     : std_logic := '0';
  signal rst_n   : std_logic := '0';
  signal clear   : std_logic := '0';
  signal valid   : std_logic := '0';
  signal start   : std_logic := '0';
  signal data    : word_t := (others => '0');
  signal crc     : std_logic_vector(W - 1 downto 0);
  signal done    : boolean := false;

  -- Reference 1: long division of the whole message.
  function ref_div(words : word_arr; n : natural) return std_logic_vector is
    variable bits : std_logic_vector(0 to MAXW * DW + W - 1) := (others => '0');
    variable full : std_logic_vector(W downto 0) := '1' & POLY_V;
    variable len  : natural := n * DW;
    variable k    : natural := 0;
    variable rem_v : std_logic_vector(W - 1 downto 0);
  begin
    for i in 0 to n - 1 loop
      for j in 0 to DW - 1 loop
        if REFIN then
          bits(k) := words(i)(j);
        else
          bits(k) := words(i)(DW - 1 - j);
        end if;
        k := k + 1;
      end loop;
    end loop;
    for i in 0 to W - 1 loop                    -- INIT xored into the first W bits
      bits(i) := bits(i) xor INIT_V(W - 1 - i);
    end loop;
    for i in 0 to len - 1 loop
      if bits(i) = '1' then
        for j in 0 to W loop
          bits(i + j) := bits(i + j) xor full(W - j);
        end loop;
      end if;
    end loop;
    for i in 0 to W - 1 loop
      rem_v(W - 1 - i) := bits(len + i);
    end loop;
    if REFOUT then                              -- reflected: LSB of the remainder is bits(len)
      for i in 0 to W - 1 loop
        rem_v(i) := bits(len + i);
      end loop;
    end if;
    return rem_v xor XOROUT_V;
  end function ref_div;

  -- Reference 2: register model, one bit at a time, written on unsigned.
  function tb_step(st : unsigned; word : word_t) return unsigned is
    variable s   : unsigned(W - 1 downto 0) := st;
    variable top : std_logic;
    variable b   : std_logic;
  begin
    for k in 0 to DW - 1 loop
      if REFIN then
        b := word(k);
      else
        b := word(DW - 1 - k);
      end if;
      top := s(W - 1);
      s := shift_left(s, 1);
      if (top xor b) = '1' then
        s := s xor unsigned(POLY_V);
      end if;
    end loop;
    return s;
  end function tb_step;

  function tb_out(st : unsigned) return std_logic_vector is
    variable r : std_logic_vector(W - 1 downto 0) := std_logic_vector(st);
    variable o : std_logic_vector(W - 1 downto 0);
  begin
    if REFOUT then
      for i in 0 to W - 1 loop
        o(i) := r(W - 1 - i);
      end loop;
    else
      o := r;
    end if;
    return o xor XOROUT_V;
  end function tb_out;

begin

  clk <= not clk after CLK_PER / 2 when not done else clk;

  dut : entity work.crc
    generic map (CRC_WIDTH => CRC_WIDTH, DATA_WIDTH => DATA_WIDTH, POLY => POLY, INIT => INIT,
                 XOROUT => XOROUT, REFIN => REFIN, REFOUT => REFOUT)
    port map (clk_i => clk, rst_n_i => rst_n, clear_i => clear, valid_i => valid,
              start_i => start, data_i => data, crc_o => crc);

  ------------------------------------------------------------------ per-cycle monitor
  monitor : process
    variable ex   : unsigned(W - 1 downto 0) := unsigned(INIT_V);
    variable base : unsigned(W - 1 downto 0);
  begin
    wait for 1 ns;
    loop
      wait until rising_edge(clk);
      if rst_n = '0' or clear = '1' then
        ex := unsigned(INIT_V);
      elsif valid = '1' then
        if start = '1' then
          base := unsigned(INIT_V);
        else
          base := ex;
        end if;
        ex := tb_step(base, data);
      end if;
      wait for 1 ns;
      assert crc = tb_out(ex)
        report "crc: crc_o differs from the cycle model" severity failure;
    end loop;
  end process monitor;

  ------------------------------------------------------------------ stimulus
  stim : process
    variable s1 : positive := SEED;
    variable s2 : positive := SEED + 7;
    variable r  : real;
    variable msg : word_arr;
    variable n   : natural;
    variable mode : natural;
    variable exp_v : std_logic_vector(W - 1 downto 0);
    -- coverage
    type cov_arr is array (0 to 4) of natural;
    variable cov_mode   : cov_arr := (others => 0);
    variable cov_junk   : natural := 0;   -- idle cycles with start_i = 1
    variable cov_coll   : natural := 0;   -- clear_i together with valid_i
    variable cov_gap    : natural := 0;   -- gaps inside a message
    variable cov_rstmid : natural := 0;   -- reset while valid_i = 1
    variable cov_len1   : natural := 0;
    variable cov_check  : natural := 0;

    impure function rnd return real is
      variable x : real;
    begin
      uniform(s1, s2, x);
      return x;
    end function rnd;

    impure function rnd_int(hi : natural) return natural is   -- 0 to hi
    begin
      return natural(floor(rnd * real(hi + 1))) mod (hi + 1);
    end function rnd_int;

    impure function rnd_word return word_t is
      variable wd : word_t;
      variable k : natural := rnd_int(9);
    begin
      for i in wd'range loop
        if rnd < 0.5 then wd(i) := '1'; else wd(i) := '0'; end if;
      end loop;
      if k = 0 then
        wd := (others => '0');
      elsif k = 1 then
        wd := (others => '1');
      elsif k = 2 then
        wd := (others => '0');
        wd(rnd_int(DW - 1)) := '1';
      end if;
      return wd;
    end function rnd_word;

    function sel(c : boolean) return std_logic is
    begin
      if c then return '1'; else return '0'; end if;
    end function sel;

    procedure drive(v, s, c : std_logic; d : word_t) is
    begin
      wait until rising_edge(clk);
      valid <= v;
      start <= s;
      clear <= c;
      data  <= d;
    end procedure drive;

    -- idle cycle: valid_i low, junk on start_i and data_i
    procedure idle(cycles : natural) is
      variable s : std_logic;
    begin
      for i in 1 to cycles loop
        if rnd < 0.5 then s := '1'; cov_junk := cov_junk + 1; else s := '0'; end if;
        drive('0', s, '0', rnd_word);
      end loop;
    end procedure idle;

    procedure check_now(expected : std_logic_vector; what : string) is
    begin
      wait for 2 ns;
      assert crc = expected report "crc: " & what & " differs from the reference" severity failure;
    end procedure check_now;

    procedure do_reset(cycles : positive) is
    begin
      for i in 1 to cycles loop
        wait until rising_edge(clk);
        rst_n <= '0';
        valid <= '1';              -- junk on the inputs during reset
        start <= '1';
        data  <= rnd_word;
        clear <= '0';
      end loop;
      cov_rstmid := cov_rstmid + 1;
      wait until rising_edge(clk);
      rst_n <= '1';
      valid <= '0';
      start <= '0';
    end procedure do_reset;

    -- send msg(0 to n-1); first_start: start_i on the first word
    procedure send(n_words : positive; first_start : boolean; gaps : boolean) is
    begin
      for i in 0 to n_words - 1 loop
        if gaps and rnd < 0.3 then
          idle(1 + rnd_int(2));
          cov_gap := cov_gap + 1;
        end if;
        drive('1', sel(i = 0 and first_start), '0', msg(i));
      end loop;
    end procedure send;

    constant MSG_TXT : string(1 to 9) := "123456789";
    variable bitstream : std_logic_vector(0 to 71);
    variable ch : natural;
  begin
    wait for 1 ns;
    do_reset(2);

    ------------------------------------------------ reset value: CRC of the empty message
    idle(1);
    check_now(ref_div(msg, 0), "value after reset");

    ------------------------------------------------ check value of "123456789"
    if CHECK'length > 0 and (72 mod DW) = 0 then
      for i in 0 to 8 loop
        ch := character'pos(MSG_TXT(i + 1));
        for b in 0 to 7 loop
          if REFIN then
            bitstream(8 * i + b) := '1' when ((ch / 2 ** b) mod 2) = 1 else '0';
          else
            bitstream(8 * i + b) := '1' when ((ch / 2 ** (7 - b)) mod 2) = 1 else '0';
          end if;
        end loop;
      end loop;
      for i in 0 to 72 / DW - 1 loop
        for j in 0 to DW - 1 loop
          if REFIN then
            msg(i)(j) := bitstream(i * DW + j);
          else
            msg(i)(DW - 1 - j) := bitstream(i * DW + j);
          end if;
        end loop;
      end loop;
      send(72 / DW, true, false);
      drive('0', '0', '0', rnd_word);
      check_now(hex_to_slv(CHECK, W), "check value of 123456789");
      assert crc = ref_div(msg, 72 / DW)
        report "crc: long division differs from the check value" severity failure;
      cov_check := 1;
    else
      cov_check := 1;
    end if;

    ------------------------------------------------ random messages
    for m in 0 to MESSAGES - 1 loop
      mode := m mod 5;
      case m mod 3 is
        when 0      => n := 1;
        when 1      => n := 1 + rnd_int(RANDW - 1);
        when others => n := RANDW;
      end case;
      if n = 1 then cov_len1 := cov_len1 + 1; end if;
      for i in 0 to n - 1 loop
        msg(i) := rnd_word;
      end loop;
      cov_mode(mode) := cov_mode(mode) + 1;

      case mode is
        when 0 =>                                  -- start_i on the first word, dirty state
          send(n, true, true);
        when 1 =>                                  -- clear_i pulse, idle, then the message
          drive('0', '0', '1', rnd_word);
          idle(1);
          check_now(ref_div(msg, 0), "value after clear");
          send(n, false, true);
        when 2 =>                                  -- clear_i together with valid_i and start_i
          drive('1', '1', '1', rnd_word);
          cov_coll := cov_coll + 1;
          idle(1);
          check_now(ref_div(msg, 0), "value after clear with valid");
          send(n, false, true);
        when 3 =>                                  -- reset in the middle of junk traffic
          drive('1', '0', '0', rnd_word);
          do_reset(1 + rnd_int(2));
          idle(1);
          check_now(ref_div(msg, 0), "value after reset");
          send(n, false, true);
        when others =>                             -- two messages back to back, no gap
          send(n, true, false);
          idle(1);
          check_now(ref_div(msg, n), "message value");
          send(n, true, true);                     -- a new message right after, no gap
      end case;

      drive('0', '0', '0', rnd_word);
      check_now(ref_div(msg, n), "message value");
      idle(rnd_int(3));                            -- the value must be held while idle
      wait for 2 ns;
      assert crc = ref_div(msg, n) report "crc: value not held while idle" severity failure;
    end loop;

    ------------------------------------------------ end
    assert cov_mode(0) > 0 and cov_mode(1) > 0 and cov_mode(2) > 0 and cov_mode(3) > 0
           and cov_mode(4) > 0 and cov_junk > 0 and cov_coll > 0 and cov_gap > 0
           and cov_rstmid > 0 and cov_len1 > 0 and cov_check > 0
      report "coverage: an item was never hit" severity failure;
    report "coverage: messages=" & integer'image(MESSAGES)
         & " start_first=" & integer'image(cov_mode(0))
         & " clear=" & integer'image(cov_mode(1))
         & " clear_with_valid=" & integer'image(cov_coll)
         & " reset=" & integer'image(cov_rstmid)
         & " junk_start_idle=" & integer'image(cov_junk)
         & " gaps=" & integer'image(cov_gap) severity note;
    report "TEST PASSED" severity note;
    done <= true;
    finish;
  end process stim;

end architecture sim;