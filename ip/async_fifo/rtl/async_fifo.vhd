-- async_fifo: dual-clock FIFO, Gray-coded pointers, first-word fall-through,
-- valid/ready on both sides.
-- Behavior is defined in ip/async_fifo/spec/SPEC.md. Conventions: docs/CONVENTIONS.md.
-- Integration rules (ASYNC_REG, set_max_delay on the Gray buses): SPEC section 10.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.async_fifo_pkg.all;

entity async_fifo is
  generic (
    WIDTH       : positive := 8;   -- data width in bits, 1 to 1024
    DEPTH       : positive := 16;  -- number of words, power of two, 4 to 1024
    SYNC_STAGES : positive := 2    -- flip-flops per pointer synchronizer, 2 to 4
  );
  port (
    -- write domain
    wr_clk_i   : in  std_logic;
    wr_rst_n_i : in  std_logic;  -- synchronous, active low
    wr_valid_i : in  std_logic;
    wr_ready_o : out std_logic;
    wr_data_i  : in  std_logic_vector(WIDTH - 1 downto 0);
    wr_level_o : out std_logic_vector(clog2(DEPTH) downto 0);

    -- read domain
    rd_clk_i   : in  std_logic;
    rd_rst_n_i : in  std_logic;  -- synchronous, active low
    rd_valid_o : out std_logic;
    rd_ready_i : in  std_logic;
    rd_data_o  : out std_logic_vector(WIDTH - 1 downto 0);
    rd_level_o : out std_logic_vector(clog2(DEPTH) downto 0)
  );
end entity async_fifo;

architecture rtl of async_fifo is
  constant ADDR_W : natural := clog2(DEPTH);

  type mem_t is array (0 to DEPTH - 1) of std_logic_vector(WIDTH - 1 downto 0);
  type sync_t is array (0 to SYNC_STAGES - 1) of std_logic_vector(ADDR_W downto 0);

  -- Initial values are for simulation cleanliness. They are not a reset.
  signal mem : mem_t := (others => (others => '0'));

  -- write domain
  signal wr_bin_q       : unsigned(ADDR_W downto 0) := (others => '0');
  signal wr_gray_q      : std_logic_vector(ADDR_W downto 0) := (others => '0');  -- crosses to read domain
  signal rd_gray_sync_q : sync_t := (others => (others => '0'));
  signal wr_level       : unsigned(ADDR_W downto 0) := (others => '0');
  signal full           : std_logic := '0';

  -- read domain
  signal rd_bin_q       : unsigned(ADDR_W downto 0) := (others => '0');
  signal rd_gray_q      : std_logic_vector(ADDR_W downto 0) := (others => '0');  -- crosses to write domain
  signal wr_gray_sync_q : sync_t := (others => (others => '0'));
  signal rd_level       : unsigned(ADDR_W downto 0) := (others => '0');
  signal empty          : std_logic := '1';

  -- SPEC section 10: keep each synchronizer chain together, do not optimize it away.
  attribute ASYNC_REG : string;
  attribute ASYNC_REG of rd_gray_sync_q : signal is "TRUE";
  attribute ASYNC_REG of wr_gray_sync_q : signal is "TRUE";
begin

  -- Parameter legality (SPEC section 2, CONVENTIONS section 6).
  assert WIDTH <= 1024
    report "async_fifo: WIDTH must be 1 to 1024"
    severity failure;
  assert DEPTH >= 4 and DEPTH <= 1024 and 2 ** ADDR_W = DEPTH
    report "async_fifo: DEPTH must be a power of two from 4 to 1024"
    severity failure;
  assert SYNC_STAGES >= 2 and SYNC_STAGES <= 4
    report "async_fifo: SYNC_STAGES must be 2 to 4"
    severity failure;

  -- Levels and flags come from the local pointer and the synchronized remote pointer.
  -- The synchronized pointer is an old value, so wr_level >= true occupancy and
  -- rd_level <= true occupancy (SPEC section 5).
  wr_level <= wr_bin_q - gray_to_bin(rd_gray_sync_q(SYNC_STAGES - 1));
  rd_level <= gray_to_bin(wr_gray_sync_q(SYNC_STAGES - 1)) - rd_bin_q;

  -- Level is at most DEPTH, so its most significant bit is set only when it equals DEPTH.
  full  <= wr_level(ADDR_W);
  empty <= '1' when rd_level = 0 else '0';

  wr_ready_o <= not full;
  rd_valid_o <= not empty;
  rd_data_o  <= mem(to_integer(rd_bin_q(ADDR_W - 1 downto 0)));
  wr_level_o <= std_logic_vector(wr_level);
  rd_level_o <= std_logic_vector(rd_level);

  -- Write domain. The Gray pointer is registered here and goes to the other domain
  -- with no logic after the register.
  p_wr : process (wr_clk_i)
    variable wr_next : unsigned(ADDR_W downto 0);
  begin
    if rising_edge(wr_clk_i) then
      if wr_rst_n_i = '0' then
        wr_bin_q       <= (others => '0');
        wr_gray_q      <= (others => '0');
        rd_gray_sync_q <= (others => (others => '0'));
      else
        rd_gray_sync_q <= rd_gray_q & rd_gray_sync_q(0 to SYNC_STAGES - 2);
        if wr_valid_i = '1' and full = '0' then
          mem(to_integer(wr_bin_q(ADDR_W - 1 downto 0))) <= wr_data_i;
          wr_next   := wr_bin_q + 1;
          wr_bin_q  <= wr_next;
          wr_gray_q <= bin_to_gray(wr_next);
        end if;
      end if;
    end if;
  end process p_wr;

  -- Read domain, same structure.
  p_rd : process (rd_clk_i)
    variable rd_next : unsigned(ADDR_W downto 0);
  begin
    if rising_edge(rd_clk_i) then
      if rd_rst_n_i = '0' then
        rd_bin_q       <= (others => '0');
        rd_gray_q      <= (others => '0');
        wr_gray_sync_q <= (others => (others => '0'));
      else
        wr_gray_sync_q <= wr_gray_q & wr_gray_sync_q(0 to SYNC_STAGES - 2);
        if rd_ready_i = '1' and empty = '0' then
          rd_next   := rd_bin_q + 1;
          rd_bin_q  <= rd_next;
          rd_gray_q <= bin_to_gray(rd_next);
        end if;
      end if;
    end if;
  end process p_rd;

end architecture rtl;