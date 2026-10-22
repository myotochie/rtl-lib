-- sync_fifo: single-clock FIFO, first-word fall-through, valid/ready on both sides.
-- Behavior is defined in ip/sync_fifo/spec/SPEC.md. Conventions: docs/CONVENTIONS.md.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.sync_fifo_pkg.all;

entity sync_fifo is
  generic (
    WIDTH : positive := 8;   -- data width in bits, 1 to 1024
    DEPTH : positive := 16   -- number of words, power of two, 2 to 4096
  );
  port (
    clk_i      : in  std_logic;
    rst_n_i    : in  std_logic;  -- synchronous, active low

    wr_valid_i : in  std_logic;
    wr_ready_o : out std_logic;
    wr_data_i  : in  std_logic_vector(WIDTH - 1 downto 0);

    rd_valid_o : out std_logic;
    rd_ready_i : in  std_logic;
    rd_data_o  : out std_logic_vector(WIDTH - 1 downto 0);

    level_o    : out std_logic_vector(clog2(DEPTH) downto 0)
  );
end entity sync_fifo;

architecture rtl of sync_fifo is
  constant ADDR_W : natural := clog2(DEPTH);

  type mem_t is array (0 to DEPTH - 1) of std_logic_vector(WIDTH - 1 downto 0);

  -- Initial values are for simulation cleanliness. They are not a reset:
  -- the storage array is not reset at run time (SPEC section 5).
  signal mem      : mem_t := (others => (others => '0'));
  signal wr_ptr_q : unsigned(ADDR_W downto 0) := (others => '0');
  signal rd_ptr_q : unsigned(ADDR_W downto 0) := (others => '0');

  signal full  : std_logic;
  signal empty : std_logic;
begin

  -- Parameter legality (SPEC section 2, CONVENTIONS section 6).
  assert WIDTH <= 1024
    report "sync_fifo: WIDTH must be 1 to 1024"
    severity failure;
  assert DEPTH >= 2 and DEPTH <= 4096 and 2 ** ADDR_W = DEPTH
    report "sync_fifo: DEPTH must be a power of two from 2 to 4096"
    severity failure;

  -- Pointers have one extra most significant bit (SPEC section 5).
  empty <= '1' when wr_ptr_q = rd_ptr_q else '0';
  full  <= '1' when wr_ptr_q(ADDR_W - 1 downto 0) = rd_ptr_q(ADDR_W - 1 downto 0)
                    and wr_ptr_q(ADDR_W) /= rd_ptr_q(ADDR_W)
           else '0';

  wr_ready_o <= not full;
  rd_valid_o <= not empty;
  rd_data_o  <= mem(to_integer(rd_ptr_q(ADDR_W - 1 downto 0)));
  level_o    <= std_logic_vector(wr_ptr_q - rd_ptr_q);

  process (clk_i)
  begin
    if rising_edge(clk_i) then
      if rst_n_i = '0' then
        wr_ptr_q <= (others => '0');
        rd_ptr_q <= (others => '0');
      else
        if wr_valid_i = '1' and full = '0' then
          mem(to_integer(wr_ptr_q(ADDR_W - 1 downto 0))) <= wr_data_i;
          wr_ptr_q <= wr_ptr_q + 1;
        end if;
        if rd_ready_i = '1' and empty = '0' then
          rd_ptr_q <= rd_ptr_q + 1;
        end if;
      end if;
    end if;
  end process;

end architecture rtl;
