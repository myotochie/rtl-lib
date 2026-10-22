-- sync_fifo_pkg: helper function shared by sync_fifo and its testbench.
-- See ip/sync_fifo/spec/SPEC.md.

library ieee;
use ieee.std_logic_1164.all;

package sync_fifo_pkg is
  -- Smallest N such that 2**N >= n. Used for pointer and level widths.
  function clog2(n : positive) return natural;
end package sync_fifo_pkg;

package body sync_fifo_pkg is
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
end package body sync_fifo_pkg;
