-- #################################################################################################
-- # << NEORV32 - Serial Peripheral Interface Controller (SPI) >>                                  #
-- # ********************************************************************************************* #
-- # BSD 3-Clause License                                                                          #
-- #                                                                                               #
-- # Copyright (c) 2023, Stephan Nolting. All rights reserved.                                     #
-- #                                                                                               #
-- # Redistribution and use in source and binary forms, with or without modification, are          #
-- # permitted provided that the following conditions are met:                                     #
-- #                                                                                               #
-- # 1. Redistributions of source code must retain the above copyright notice, this list of        #
-- #    conditions and the following disclaimer.                                                   #
-- #                                                                                               #
-- # 2. Redistributions in binary form must reproduce the above copyright notice, this list of     #
-- #    conditions and the following disclaimer in the documentation and/or other materials        #
-- #    provided with the distribution.                                                            #
-- #                                                                                               #
-- # 3. Neither the name of the copyright holder nor the names of its contributors may be used to  #
-- #    endorse or promote products derived from this software without specific prior written      #
-- #    permission.                                                                                #
-- #                                                                                               #
-- # THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND ANY EXPRESS   #
-- # OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF               #
-- # MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE    #
-- # COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,     #
-- # EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE #
-- # GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED    #
-- # AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING     #
-- # NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED  #
-- # OF THE POSSIBILITY OF SUCH DAMAGE.                                                            #
-- # ********************************************************************************************* #
-- # The NEORV32 Processor - https://github.com/stnolting/neorv32              (c) Stephan Nolting #
-- #################################################################################################

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library neorv32;
use neorv32.neorv32_package.all;

entity neorv32_spi is
  generic (
    IO_SPI_FIFO : natural -- SPI RTX fifo depth, has to be a power of two, min 1
  );
  port (
    -- host access --
    clk_i       : in  std_ulogic; -- global clock line
    rstn_i      : in  std_ulogic; -- global reset line, low-active, async
    addr_i      : in  std_ulogic_vector(31 downto 0); -- address
    rden_i      : in  std_ulogic; -- read enable
    wren_i      : in  std_ulogic; -- write enable
    data_i      : in  std_ulogic_vector(31 downto 0); -- data in
    data_o      : out std_ulogic_vector(31 downto 0); -- data out
    ack_o       : out std_ulogic; -- transfer acknowledge
    -- clock generator --
    clkgen_en_o : out std_ulogic; -- enable clock generator
    clkgen_i    : in  std_ulogic_vector(07 downto 0);
    -- com lines --
    spi_clk_o   : out std_ulogic; -- SPI serial clock
    spi_dat_o   : out std_ulogic; -- controller data out, peripheral data in
    spi_dat_i   : in  std_ulogic; -- controller data in, peripheral data out
    spi_csn_o   : out std_ulogic_vector(07 downto 0); -- SPI CS
    -- interrupt --
    irq_o       : out std_ulogic -- transmission done interrupt
  );
end neorv32_spi;

architecture neorv32_spi_rtl of neorv32_spi is

  -- IO space: module base address --
  constant hi_abb_c : natural := index_size_f(io_size_c)-1; -- high address boundary bit
  constant lo_abb_c : natural := index_size_f(spi_size_c); -- low address boundary bit

  -- control register --
  constant ctrl_en_c           : natural :=  0; -- r/w: spi enable
  constant ctrl_cpha_c         : natural :=  1; -- r/w: spi clock phase
  constant ctrl_cpol_c         : natural :=  2; -- r/w: spi clock polarity
  constant ctrl_cs_sel0_c      : natural :=  3; -- r/w: spi CS select bit 0
  constant ctrl_cs_sel1_c      : natural :=  4; -- r/w: spi CS select bit 1
  constant ctrl_cs_sel2_c      : natural :=  5; -- r/w: spi CS select bit 2
  constant ctrl_cs_en_c        : natural :=  6; -- r/w: enable selected cs line (set bit -> clear line)
  constant ctrl_prsc0_c        : natural :=  7; -- r/w: spi prescaler select bit 0
  constant ctrl_prsc1_c        : natural :=  8; -- r/w: spi prescaler select bit 1
  constant ctrl_prsc2_c        : natural :=  9; -- r/w: spi prescaler select bit 2
  constant ctrl_cdiv0_c        : natural := 10; -- r/w: clock divider bit 0
  constant ctrl_cdiv1_c        : natural := 11; -- r/w: clock divider bit 1
  constant ctrl_cdiv2_c        : natural := 12; -- r/w: clock divider bit 2
  constant ctrl_cdiv3_c        : natural := 13; -- r/w: clock divider bit 3
  --
  constant ctrl_rx_avail_c     : natural := 16; -- r/-: rx fifo data available (fifo not empty)
  constant ctrl_tx_empty_c     : natural := 17; -- r/-: tx fifo empty
  constant ctrl_tx_nhalf_c     : natural := 18; -- r/-: tx fifo not at least half full
  constant ctrl_tx_full_c      : natural := 19; -- r/-: tx fifo full
  constant ctrl_irq_rx_avail_c : natural := 20; -- r/w: fire irq if rx fifo data available (fifo not empty)
  constant ctrl_irq_tx_empty_c : natural := 21; -- r/w: fire irq if tx fifo empty
  constant ctrl_irq_tx_nhalf_c : natural := 22; -- r/w: fire irq if tx fifo not at least half full
  constant ctrl_fifo_size0_c   : natural := 23; -- r/-: log2(fifo size), bit 0 (lsb)
  constant ctrl_fifo_size1_c   : natural := 24; -- r/-: log2(fifo size), bit 1
  constant ctrl_fifo_size2_c   : natural := 25; -- r/-: log2(fifo size), bit 2
  constant ctrl_fifo_size3_c   : natural := 26; -- r/-: log2(fifo size), bit 3 (msb)
  --
  constant ctrl_busy_c         : natural := 31; -- r/-: spi phy busy or tx fifo not empty yet

  -- access control --
  signal acc_en  : std_ulogic; -- module access enable
  signal addr    : std_ulogic_vector(31 downto 0); -- access address
  signal wren    : std_ulogic; -- word write enable
  signal rden    : std_ulogic; -- read enable
  signal rden_ff : std_ulogic;

  -- control register --
  type ctrl_t is record
    enable       : std_ulogic;
    cpha         : std_ulogic;
    cpol         : std_ulogic;
    cs_sel       : std_ulogic_vector(2 downto 0);
    cs_en        : std_ulogic;
    prsc         : std_ulogic_vector(2 downto 0);
    cdiv         : std_ulogic_vector(3 downto 0);
    irq_rx_avail : std_ulogic;
    irq_tx_empty : std_ulogic;
    irq_tx_nhalf : std_ulogic;
  end record;
  signal ctrl : ctrl_t;

  -- clock generator --
  signal cdiv_cnt   : std_ulogic_vector(3 downto 0);
  signal spi_clk_en : std_ulogic;

  -- spi transceiver --
  type rtx_engine_t is record
    state    : std_ulogic_vector(2 downto 0);
    busy     : std_ulogic;
    start    : std_ulogic;
    sreg     : std_ulogic_vector(7 downto 0);
    bitcnt   : std_ulogic_vector(3 downto 0);
    sdi_sync : std_ulogic;
    done     : std_ulogic;
  end record;
  signal rtx_engine : rtx_engine_t;

  -- FIFO interface --
  type fifo_t is record
    we    : std_ulogic; -- write enable
    re    : std_ulogic; -- read enable
    clear : std_ulogic; -- sync reset, high-active
    wdata : std_ulogic_vector(7 downto 0); -- write data
    rdata : std_ulogic_vector(7 downto 0); -- read data
    avail : std_ulogic; -- data available?
    free  : std_ulogic; -- free entry available?
    half  : std_ulogic; -- half full
  end record;
  signal tx_fifo, rx_fifo : fifo_t;

begin

  -- Sanity Checks --------------------------------------------------------------------------
  -- -------------------------------------------------------------------------------------------
  assert not ((is_power_of_two_f(IO_SPI_FIFO) = false))
    report "NEORV32 PROCESSOR CONFIG ERROR: SPI FIFO size has to be a power of two." severity error;
  assert not (IO_SPI_FIFO > 2**15)
    report "NEORV32 PROCESSOR CONFIG ERROR: SPI FIFO size has to be in range 1..32768." severity error;


  -- Host Access ----------------------------------------------------------------------------
  -- -------------------------------------------------------------------------------------------

  -- access control --
  acc_en <= '1' when (addr_i(hi_abb_c downto lo_abb_c) = spi_base_c(hi_abb_c downto lo_abb_c)) else '0';
  addr   <= spi_base_c(31 downto lo_abb_c) & addr_i(lo_abb_c-1 downto 2) & "00"; -- word aligned
  wren   <= acc_en and wren_i;
  rden   <= acc_en and rden_i;

  -- write access --
  process(rstn_i, clk_i)
  begin
    if (rstn_i = '0') then
      ctrl.enable       <= '0';
      ctrl.cpha         <= '0';
      ctrl.cpol         <= '0';
      ctrl.cs_sel       <= (others => '0');
      ctrl.cs_en        <= '0';
      ctrl.prsc         <= (others => '0');
      ctrl.cdiv         <= (others => '0');
      ctrl.irq_rx_avail <= '0';
      ctrl.irq_tx_empty <= '0';
      ctrl.irq_tx_nhalf <= '0';
    elsif rising_edge(clk_i) then
      if (wren = '1') then
        if (addr = spi_ctrl_addr_c) then -- control register
          ctrl.enable       <= data_i(ctrl_en_c);
          ctrl.cpha         <= data_i(ctrl_cpha_c);
          ctrl.cpol         <= data_i(ctrl_cpol_c);
          ctrl.cs_sel       <= data_i(ctrl_cs_sel2_c downto ctrl_cs_sel0_c);
          ctrl.cs_en        <= data_i(ctrl_cs_en_c);
          ctrl.prsc         <= data_i(ctrl_prsc2_c downto ctrl_prsc0_c);
          ctrl.cdiv         <= data_i(ctrl_cdiv3_c downto ctrl_cdiv0_c);
          ctrl.irq_rx_avail <= data_i(ctrl_irq_rx_avail_c);
          ctrl.irq_tx_empty <= data_i(ctrl_irq_tx_empty_c);
          ctrl.irq_tx_nhalf <= data_i(ctrl_irq_tx_nhalf_c);
        end if;
      end if;
    end if;
  end process;

  -- read access --
  process(clk_i)
  begin
    if rising_edge(clk_i) then
      rden_ff <= rden; -- delay read access by one cycle due to sync FIFO read access (FIXME?)
      ack_o   <= rden_ff or wren; -- bus access acknowledge
      data_o  <= (others => '0');
      if (rden_ff = '1') then
        if (addr = spi_ctrl_addr_c) then -- control register
          data_o(ctrl_en_c)                            <= ctrl.enable;
          data_o(ctrl_cpha_c)                          <= ctrl.cpha;
          data_o(ctrl_cpol_c)                          <= ctrl.cpol;
          data_o(ctrl_cs_sel2_c downto ctrl_cs_sel0_c) <= ctrl.cs_sel;
          data_o(ctrl_cs_en_c)                         <= ctrl.cs_en;
          data_o(ctrl_prsc2_c downto ctrl_prsc0_c)     <= ctrl.prsc;
          data_o(ctrl_cdiv3_c downto ctrl_cdiv0_c)     <= ctrl.cdiv;
          --
          data_o(ctrl_rx_avail_c)     <= rx_fifo.avail;
          data_o(ctrl_tx_empty_c)     <= not tx_fifo.avail;
          data_o(ctrl_tx_nhalf_c)     <= not tx_fifo.half;
          data_o(ctrl_tx_full_c)      <= not tx_fifo.free;
          data_o(ctrl_irq_rx_avail_c) <= ctrl.irq_rx_avail;
          data_o(ctrl_irq_tx_empty_c) <= ctrl.irq_tx_empty;
          data_o(ctrl_irq_tx_nhalf_c) <= ctrl.irq_tx_nhalf;
          --
          data_o(ctrl_fifo_size3_c downto ctrl_fifo_size0_c) <= std_ulogic_vector(to_unsigned(index_size_f(IO_SPI_FIFO), 4));
          --
          data_o(ctrl_busy_c) <= rtx_engine.busy or tx_fifo.avail;
        else -- data register (spi_rtx_addr_c)
          data_o(7 downto 0) <= rx_fifo.rdata;
        end if;
      end if;
    end if;
  end process;


  -- direct chip-select (low-active) --
  process(ctrl)
  begin
    spi_csn_o <= (others => '1'); -- default: all disabled
    if (ctrl.cs_en = '1') and (ctrl.enable = '1') then
      spi_csn_o(to_integer(unsigned(ctrl.cs_sel))) <= '0';
    end if;
  end process;


  -- Data FIFO ("Ring Buffer") --------------------------------------------------------------
  -- -------------------------------------------------------------------------------------------

  -- TX FIFO --
  tx_fifo_inst: neorv32_fifo
  generic map (
    FIFO_DEPTH => IO_SPI_FIFO, -- number of fifo entries; has to be a power of two; min 1
    FIFO_WIDTH => 8,           -- size of data elements in fifo
    FIFO_RSYNC => true,        -- sync read
    FIFO_SAFE  => true,        -- safe access
    FIFO_GATE  => false        -- no output gate required
  )
  port map (
    -- control --
    clk_i   => clk_i,         -- clock, rising edge
    rstn_i  => rstn_i,        -- async reset, low-active
    clear_i => tx_fifo.clear, -- sync reset, high-active
    half_o  => tx_fifo.half,  -- FIFO at least half-full
    -- write port --
    wdata_i => tx_fifo.wdata, -- write data
    we_i    => tx_fifo.we,    -- write enable
    free_o  => tx_fifo.free,  -- at least one entry is free when set
    -- read port --
    re_i    => tx_fifo.re,    -- read enable
    rdata_o => tx_fifo.rdata, -- read data
    avail_o => tx_fifo.avail  -- data available when set
  );

  tx_fifo.clear <= not ctrl.enable;
  tx_fifo.we    <= '1' when (wren = '1') and (addr = spi_rtx_addr_c) else '0';
  tx_fifo.wdata <= data_i(7 downto 0);
  tx_fifo.re    <= '1' when (rtx_engine.state = "100") and (tx_fifo.avail = '1') and (rtx_engine.start = '0') else '0';


  -- RX FIFO --
  rx_fifo_inst: neorv32_fifo
  generic map (
    FIFO_DEPTH => IO_SPI_FIFO, -- number of fifo entries; has to be a power of two; min 1
    FIFO_WIDTH => 8,           -- size of data elements in fifo
    FIFO_RSYNC => true,        -- sync read
    FIFO_SAFE  => true,        -- safe access
    FIFO_GATE  => false        -- no output gate required
  )
  port map (
    -- control --
    clk_i   => clk_i,         -- clock, rising edge
    rstn_i  => rstn_i,        -- async reset, low-active
    clear_i => rx_fifo.clear, -- sync reset, high-active
    half_o  => rx_fifo.half,  -- FIFO at least half-full
    -- write port --
    wdata_i => rx_fifo.wdata, -- write data
    we_i    => rx_fifo.we,    -- write enable
    free_o  => rx_fifo.free,  -- at least one entry is free when set
    -- read port --
    re_i    => rx_fifo.re,    -- read enable
    rdata_o => rx_fifo.rdata, -- read data
    avail_o => rx_fifo.avail  -- data available when set
  );

  rx_fifo.clear <= not ctrl.enable;
  rx_fifo.wdata <= rtx_engine.sreg;
  rx_fifo.we    <= rtx_engine.done;
  rx_fifo.re    <= '1' when (rden = '1') and (addr = spi_rtx_addr_c) else '0';


  -- IRQ generator --
  process(clk_i)
  begin
    if rising_edge(clk_i) then
      irq_o <= ctrl.enable and (
               (ctrl.irq_rx_avail and      rx_fifo.avail)  or -- IRQ if RX FIFO is not empty
               (ctrl.irq_tx_empty and (not tx_fifo.avail)) or -- IRQ if TX FIFO is empty
               (ctrl.irq_tx_nhalf and (not tx_fifo.half)));   -- IRQ if TX buffer is not half full
    end if;
  end process;


  -- SPI Transceiver ------------------------------------------------------------------------
  -- -------------------------------------------------------------------------------------------
  process(clk_i)
  begin
    if rising_edge(clk_i) then
      -- defaults --
      rtx_engine.done  <= '0';
      rtx_engine.start <= tx_fifo.re; -- delay start trigger by one cycle due to sync FIFO read access

      -- serial engine --
      rtx_engine.state(2) <= ctrl.enable;
      case rtx_engine.state is

        when "100" => -- enabled but idle, waiting for new transmission trigger
        -- ------------------------------------------------------------
          spi_clk_o         <= ctrl.cpol;
          rtx_engine.bitcnt <= (others => '0');
          rtx_engine.sreg   <= tx_fifo.rdata;
          if (rtx_engine.start = '1') then -- trigger new transmission
            rtx_engine.state(1 downto 0) <= "01";
          end if;

        when "101" => -- start with next new clock pulse
        -- ------------------------------------------------------------
          if (spi_clk_en = '1') then
            if (ctrl.cpha = '1') then -- clock phase shift
              spi_clk_o <= not ctrl.cpol;
            end if;
            rtx_engine.state(1 downto 0) <= "10";
          end if;

        when "110" => -- first phase of bit transmission
        -- ------------------------------------------------------------
          if (spi_clk_en = '1') then
            spi_clk_o                    <= not (ctrl.cpha xor ctrl.cpol);
            rtx_engine.sdi_sync          <= spi_dat_i; -- sample data input
            rtx_engine.bitcnt            <= std_ulogic_vector(unsigned(rtx_engine.bitcnt) + 1);
            rtx_engine.state(1 downto 0) <= "11";
          end if;

        when "111" => -- second phase of bit transmission
        -- ------------------------------------------------------------
          if (spi_clk_en = '1') then
            rtx_engine.sreg <= rtx_engine.sreg(6 downto 0) & rtx_engine.sdi_sync; -- shift and set output
            if (rtx_engine.bitcnt(3) = '1') then -- all bits transferred?
              spi_clk_o                    <= ctrl.cpol;
              rtx_engine.done              <= '1'; -- done!
              rtx_engine.state(1 downto 0) <= "00"; -- transmission done
            else
              spi_clk_o                    <= ctrl.cpha xor ctrl.cpol;
              rtx_engine.state(1 downto 0) <= "10";
            end if;
          end if;

        when others => -- "0--": SPI deactivated
        -- ------------------------------------------------------------
          spi_clk_o                    <= ctrl.cpol;
          rtx_engine.sreg              <= (others => '0');
          rtx_engine.state(1 downto 0) <= "00";

      end case;
    end if;
  end process;

  -- PHY busy flag --
  rtx_engine.busy <= '0' when (rtx_engine.state(1 downto 0) = "00") else '1';

  -- data output --
  spi_dat_o <= rtx_engine.sreg(7); -- MSB first


  -- clock generator --
  process(clk_i)
  begin
    if rising_edge(clk_i) then
      if (ctrl.enable = '0') then -- reset/disabled
        spi_clk_en <= '0';
        cdiv_cnt   <= (others => '0');
      else
        spi_clk_en <= '0'; -- default
        if (clkgen_i(to_integer(unsigned(ctrl.prsc))) = '1') then -- pre-scaled clock
          if (cdiv_cnt = ctrl.cdiv) then -- clock divider for fine-tuning
            spi_clk_en <= '1';
            cdiv_cnt   <= (others => '0');
          else
            cdiv_cnt <= std_ulogic_vector(unsigned(cdiv_cnt) + 1);
          end if;
        end if;
      end if;
    end if;
  end process;

  -- clock generator enable --
  clkgen_en_o <= ctrl.enable;


end neorv32_spi_rtl;
