-- uart_pkg: constants and helper functions shared by uart_tx, uart_rx, uart and the testbench.
-- See ip/uart/spec/SPEC.md.

library ieee;
use ieee.std_logic_1164.all;
use ieee.math_real.all;

package uart_pkg is
  -- Smallest N such that 2**N >= n.
  function clog2(n : positive) return natural;
  -- Clock cycles per bit, CLK_FREQ_HZ / BAUD rounded to nearest, before any legality check.
  function bit_clks_raw(clk_hz : positive; baud : positive) return natural;
  -- Same value forced into 16 to 65535, so that declarations stay valid when a generic is
  -- illegal. The elaboration assertions then report the real problem.
  function bit_clks(clk_hz : positive; baud : positive) return positive;
  -- True if the rounding error of BIT_CLKS is at most 2 percent.
  function baud_error_ok(clk_hz : positive; baud : positive) return boolean;
  -- Offset S of the first and third vote samples around the middle of the bit.
  function vote_offset(n : positive) return positive;
  -- Parity bit to append to data. mode 1 = even, 2 = odd.
  function parity_bit(data : std_logic_vector; mode : natural) return std_logic;
  -- 1 if the frame has a parity bit, else 0.
  function parity_len(mode : natural) return natural;
end package uart_pkg;

package body uart_pkg is
  function clog2(n : positive) return natural is
    variable r : natural := 0;
    variable v : positive := 1;
  begin
    while v < n loop
      v := v * 2;
      r := r + 1;
    end loop;
    return r;
  end function clog2;

  function bit_clks_raw(clk_hz : positive; baud : positive) return natural is
    variable q : real := real(clk_hz) / real(baud);
  begin
    if q > 1.0e9 then
      return 1000000000;
    end if;
    return natural(round(q));
  end function bit_clks_raw;

  function bit_clks(clk_hz : positive; baud : positive) return positive is
    variable n : natural := bit_clks_raw(clk_hz, baud);
  begin
    if n < 16 then
      return 16;
    elsif n > 65535 then
      return 65535;
    end if;
    return n;
  end function bit_clks;

  function baud_error_ok(clk_hz : positive; baud : positive) return boolean is
    variable n : natural := bit_clks_raw(clk_hz, baud);
    variable err : real;
  begin
    if n = 0 then
      return false;
    end if;
    err := abs(real(n) * real(baud) / real(clk_hz) - 1.0);
    return err <= 0.02;
  end function baud_error_ok;

  function vote_offset(n : positive) return positive is
  begin
    if n / 16 < 1 then
      return 1;
    end if;
    return n / 16;
  end function vote_offset;

  function parity_bit(data : std_logic_vector; mode : natural) return std_logic is
    variable p : std_logic := '0';
  begin
    for i in data'range loop
      p := p xor data(i);
    end loop;
    if mode = 2 then
      p := not p;
    end if;
    return p;
  end function parity_bit;

  function parity_len(mode : natural) return natural is
  begin
    if mode = 0 then
      return 0;
    end if;
    return 1;
  end function parity_len;
end package body uart_pkg;