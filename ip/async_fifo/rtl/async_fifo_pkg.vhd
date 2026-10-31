-- async_fifo_pkg: helper functions shared by async_fifo and its testbench.
-- See ip/async_fifo/spec/SPEC.md.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

package async_fifo_pkg is
  -- Smallest N such that 2**N >= n. Used for pointer and level widths.
  function clog2(n : positive) return natural;
  -- Binary to Gray code. Two consecutive binary values give Gray codes that differ by one bit.
  function bin_to_gray(b : unsigned) return std_logic_vector;
  -- Gray code to binary.
  function gray_to_bin(g : std_logic_vector) return unsigned;
end package async_fifo_pkg;

package body async_fifo_pkg is
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

  function bin_to_gray(b : unsigned) return std_logic_vector is
  begin
    return std_logic_vector(b xor shift_right(b, 1));
  end function bin_to_gray;

  function gray_to_bin(g : std_logic_vector) return unsigned is
    variable b : unsigned(g'length - 1 downto 0);
    variable gv : std_logic_vector(g'length - 1 downto 0) := g;
  begin
    b(b'high) := gv(gv'high);
    for i in gv'high - 1 downto 0 loop
      b(i) := b(i + 1) xor gv(i);
    end loop;
    return b;
  end function gray_to_bin;
end package body async_fifo_pkg;