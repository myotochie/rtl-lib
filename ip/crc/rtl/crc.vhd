-- crc: parameterizable CRC engine, Rocksoft model, DATA_WIDTH bits per clock cycle.
-- Behavior is defined in ip/crc/spec/SPEC.md. Conventions: docs/CONVENTIONS.md.

library ieee;
use ieee.std_logic_1164.all;
use work.crc_pkg.all;

entity crc is
  generic (
    CRC_WIDTH  : integer := 32;            -- 3 to 64
    DATA_WIDTH : integer := 8;             -- 1 to 64
    POLY       : string  := "04C11DB7";    -- hex, without the x^CRC_WIDTH term, must be odd
    INIT       : string  := "FFFFFFFF";    -- hex, initial register value
    XOROUT     : string  := "FFFFFFFF";    -- hex, xored with the output
    REFIN      : boolean := true;          -- false: data_i(high) first, true: data_i(0) first
    REFOUT     : boolean := true           -- reflect the register before XOROUT
  );
  port (
    clk_i   : in  std_logic;
    rst_n_i : in  std_logic;  -- synchronous, active low

    clear_i : in  std_logic;  -- restart: the CRC becomes the one of the empty message
    valid_i : in  std_logic;  -- data_i is a word of the message
    start_i : in  std_logic;  -- with valid_i: this word is the first of a message
    data_i  : in  std_logic_vector(DATA_WIDTH - 1 downto 0);

    crc_o   : out std_logic_vector(CRC_WIDTH - 1 downto 0)
  );
end entity crc;

architecture rtl of crc is
begin

  assert CRC_WIDTH >= 3 and CRC_WIDTH <= 64
    report "crc: CRC_WIDTH must be 3 to 64" severity failure;
  assert DATA_WIDTH >= 1 and DATA_WIDTH <= 64
    report "crc: DATA_WIDTH must be 1 to 64" severity failure;
  assert hex_valid(POLY) and hex_valid(INIT) and hex_valid(XOROUT)
    report "crc: POLY, INIT and XOROUT must be non-empty hexadecimal strings" severity failure;

  gen_ok : if CRC_WIDTH >= 3 and CRC_WIDTH <= 64 and DATA_WIDTH >= 1 and DATA_WIDTH <= 64
             and hex_valid(POLY) and hex_valid(INIT) and hex_valid(XOROUT) generate

    constant POLY_V   : std_logic_vector(CRC_WIDTH - 1 downto 0) := hex_to_slv(POLY, CRC_WIDTH);
    constant INIT_V   : std_logic_vector(CRC_WIDTH - 1 downto 0) := hex_to_slv(INIT, CRC_WIDTH);
    constant XOROUT_V : std_logic_vector(CRC_WIDTH - 1 downto 0) := hex_to_slv(XOROUT, CRC_WIDTH);

    signal state : std_logic_vector(CRC_WIDTH - 1 downto 0) := INIT_V;
  begin

    assert hex_fits(POLY, CRC_WIDTH)
      report "crc: POLY does not fit in CRC_WIDTH bits" severity failure;
    assert hex_fits(INIT, CRC_WIDTH)
      report "crc: INIT does not fit in CRC_WIDTH bits" severity failure;
    assert hex_fits(XOROUT, CRC_WIDTH)
      report "crc: XOROUT does not fit in CRC_WIDTH bits" severity failure;
    assert POLY_V(0) = '1'
      report "crc: POLY must be odd (the x^0 term must be present)" severity failure;

    process (clk_i)
      variable base : std_logic_vector(CRC_WIDTH - 1 downto 0);
    begin
      if rising_edge(clk_i) then
        if rst_n_i = '0' or clear_i = '1' then
          state <= INIT_V;
        elsif valid_i = '1' then
          if start_i = '1' then
            base := INIT_V;
          else
            base := state;
          end if;
          state <= crc_update(base, data_i, POLY_V, REFIN);
        end if;
      end if;
    end process;

    crc_o <= crc_final(state, XOROUT_V, REFOUT);

  end generate gen_ok;

end architecture rtl;