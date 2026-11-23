-- crc_pkg: constants parsing and the CRC step functions used by crc (SPEC section 5).
-- Conventions: docs/CONVENTIONS.md.

library ieee;
use ieee.std_logic_1164.all;

package crc_pkg is
  -- True if every character of s is a hexadecimal digit (0-9, a-f, A-F) and s is not empty.
  function hex_valid(s : string) return boolean;

  -- True if the value of the hexadecimal string s fits in w bits.
  function hex_fits(s : string; w : positive) return boolean;

  -- Value of the hexadecimal string s, on w bits (the high bits are dropped).
  function hex_to_slv(s : string; w : positive) return std_logic_vector;

  -- Bit-reversed copy of v (same range).
  function reverse(v : std_logic_vector) return std_logic_vector;

  -- One word through the CRC register. crc is the non-reflected register.
  -- refin = false: data(high) is processed first. refin = true: data(0) is processed first.
  function crc_update(crc : std_logic_vector; data : std_logic_vector;
                      poly : std_logic_vector; refin : boolean) return std_logic_vector;

  -- Output value: register, reflected if refout, then xored with xorout.
  function crc_final(crc : std_logic_vector; xorout : std_logic_vector;
                     refout : boolean) return std_logic_vector;
end package crc_pkg;

package body crc_pkg is

  function hex_digit(c : character) return integer is
  begin
    case c is
      when '0' to '9' => return character'pos(c) - character'pos('0');
      when 'a' to 'f' => return character'pos(c) - character'pos('a') + 10;
      when 'A' to 'F' => return character'pos(c) - character'pos('A') + 10;
      when others     => return -1;
    end case;
  end function hex_digit;

  function hex_valid(s : string) return boolean is
  begin
    if s'length = 0 then
      return false;
    end if;
    for i in s'range loop
      if hex_digit(s(i)) < 0 then
        return false;
      end if;
    end loop;
    return true;
  end function hex_valid;

  -- Full value of s on 4 * s'length bits.
  function hex_full(s : string) return std_logic_vector is
    variable r : std_logic_vector(4 * s'length - 1 downto 0);
    variable d : integer;
    variable k : natural := 0;
  begin
    for i in s'reverse_range loop            -- last character is the least significant digit
      d := hex_digit(s(i));
      if d < 0 then
        d := 0;
      end if;
      for b in 0 to 3 loop
        r(4 * k + b) := '1' when ((d / 2 ** b) mod 2) = 1 else '0';
      end loop;
      k := k + 1;
    end loop;
    return r;
  end function hex_full;

  function hex_fits(s : string; w : positive) return boolean is
    constant f : std_logic_vector(4 * s'length - 1 downto 0) := hex_full(s);
  begin
    for i in f'range loop
      if i >= w and f(i) = '1' then
        return false;
      end if;
    end loop;
    return true;
  end function hex_fits;

  function hex_to_slv(s : string; w : positive) return std_logic_vector is
    constant f : std_logic_vector(4 * s'length - 1 downto 0) := hex_full(s);
    variable r : std_logic_vector(w - 1 downto 0) := (others => '0');
  begin
    for i in 0 to w - 1 loop
      if i <= f'high then
        r(i) := f(i);
      end if;
    end loop;
    return r;
  end function hex_to_slv;

  function reverse(v : std_logic_vector) return std_logic_vector is
    variable n : std_logic_vector(v'length - 1 downto 0) := v;
    variable r : std_logic_vector(v'length - 1 downto 0);
  begin
    for i in n'range loop
      r(i) := n(n'high - i);
    end loop;
    return r;
  end function reverse;

  function crc_update(crc : std_logic_vector; data : std_logic_vector;
                      poly : std_logic_vector; refin : boolean) return std_logic_vector is
    variable c  : std_logic_vector(crc'length - 1 downto 0) := crc;
    variable d  : std_logic_vector(data'length - 1 downto 0) := data;
    variable p  : std_logic_vector(crc'length - 1 downto 0) := poly;
    variable fb : std_logic;
    variable b  : std_logic;
  begin
    for i in 0 to d'length - 1 loop
      if refin then
        b := d(i);
      else
        b := d(d'high - i);
      end if;
      fb := c(c'high) xor b;
      c  := c(c'high - 1 downto 0) & '0';
      if fb = '1' then
        c := c xor p;
      end if;
    end loop;
    return c;
  end function crc_update;

  function crc_final(crc : std_logic_vector; xorout : std_logic_vector;
                     refout : boolean) return std_logic_vector is
    variable c : std_logic_vector(crc'length - 1 downto 0) := crc;
    variable x : std_logic_vector(crc'length - 1 downto 0) := xorout;
  begin
    if refout then
      c := reverse(c);
    end if;
    return c xor x;
  end function crc_final;

end package body crc_pkg;