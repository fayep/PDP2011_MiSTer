-- mmu_trace_watch.vhd -- live shadow copies of KERNEL D-space and
-- I-space PAR5/PAR6, for tracecap.vhd, built ENTIRELY by watching the
-- CPU bus from outside mmu.vhd -- not a port/signal added to mmu.vhd
-- itself.
--
-- Architecture, per the user's own repeated instruction this session
-- (paraphrased: "the event carries state over the clock boundary, the
-- registers should only ever exist in the trace module" -- asked for
-- many times before this was actually built this way): tracing must be
-- fully isolated from the devices it observes. This module watches
-- cpu_addr/cpu_dataout/cpu_wr/cpu_dw8 -- signals unibus.vhd ALREADY
-- has and ALREADY feeds to mmu0 -- and reconstructs the same write
-- events mmu.vhd's own write-decode sees, entirely independently.
-- mmu.vhd, rl11.vhd, and rh11.vhd need zero new ports for this: a build
-- without tracing simply doesn't instantiate this module, and every
-- device file is byte-for-byte its original, already-timing-proven
-- self. This directly replaces the EARLIER (wrong) approach of adding
-- trace_kdpar5/6 (and later trace_kipar5/6) ports straight onto
-- mmu.vhd's own entity and write-decode process.
--
-- Correctness note: PAR5/PAR6 (kernel D-space AND I-space) live in the
-- top 8K I/O page (virtual addresses with top 3 bits "111"), which is
-- ALWAYS identity-mapped on a real PDP-11 regardless of MMU enable
-- state or translation mode -- this is architectural, not an
-- approximation. So the raw, untranslated cpu_addr (what the CPU
-- itself issues) already equals the literal register address for these
-- four registers specifically, with no need to replicate mmu.vhd's
-- general virtual-to-physical translation logic here.
--
-- Register identity (see notes/rsts-init-disasm.md, confirmed via real
-- SIMH-breakpoint disassembly of RSTS's actual overlay-mapping
-- routine, MAPCOPY_PARAM at 025006/025120/025204):
--   KIPAR5 = 172352 (virtual) -- the pair RSTS's real overlay mechanism
--   KIPAR6 = 172354 (virtual)    actually uses (mov r0,@#172352 / mov r1,@#172354)
--   KDPAR5 = 172372 (virtual) -- this session's original WRONG guess at
--   KDPAR6 = 172374 (virtual)    which pair mattered; kept anyway, since
--                                something else in RSTS does write real
--                                values there too, and the user wants
--                                eventual coverage of all MMU registers.
--
-- Byte-write handling duplicates mmu.vhd's own mmu_dato half-select
-- logic (cpu_dw8 + cpu_addr(0) pick which byte of cpu_dataout lands
-- where) -- a small, stable piece of PDP-11 bus convention, not the
-- actual PAR-array/translation logic this module is deliberately kept
-- independent of.

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;

entity mmu_trace_watch is
   port(
      clk   : in std_logic;  -- nclk -- SAME domain mmu.vhd itself uses
                              -- (mmu0: clk => nclk in unibus.vhd), and
                              -- the same domain cpu_addr/cpu_dataout/
                              -- cpu_wr/cpu_dw8 are already safely
                              -- consumed in (mmu.vhd samples the exact
                              -- same signals, same way, today).
      reset : in std_logic;

      cpu_addr    : in std_logic_vector(15 downto 0);
      cpu_dataout : in std_logic_vector(15 downto 0);
      cpu_wr      : in std_logic;
      cpu_dw8     : in std_logic;

      trace_kdpar5 : out std_logic_vector(15 downto 0);
      trace_kdpar6 : out std_logic_vector(15 downto 0);
      trace_kipar5 : out std_logic_vector(15 downto 0);
      trace_kipar6 : out std_logic_vector(15 downto 0)
   );
end entity mmu_trace_watch;

architecture rtl of mmu_trace_watch is
   -- Register (word) address, with the byte-select bit masked off --
   -- a byte write to the ODD address of a register (e.g. 172353, the
   -- high byte of KIPAR5 at 172352) must still match that register;
   -- cpu_addr(0) is checked separately below, purely for byte-half
   -- selection, same split mmu.vhd's own decode uses (addr_p24z5 vs
   -- addr_p(4 downto 1) vs cpu_addr_v(0)).
   signal word_addr : std_logic_vector(15 downto 0);
begin
   word_addr <= cpu_addr(15 downto 1) & '0';

   process(clk)
   begin
      if rising_edge(clk) then
         if reset = '1' then
            trace_kdpar5 <= (others => '0');
            trace_kdpar6 <= (others => '0');
            trace_kipar5 <= (others => '0');
            trace_kipar6 <= (others => '0');
         elsif cpu_wr = '1' then
            -- VHDL o"..." literals produce a bit length that's a
            -- multiple of 3 (6 octal digits = 18 bits), which doesn't
            -- fit a 16-bit target -- hex literals instead, octal noted
            -- in each comment for cross-reference against
            -- notes/rsts-init-disasm.md and mmu.vhd's own addressing.
            case word_addr is
               when x"F4EA" =>  -- 172352 octal = KIPAR5
                  if cpu_dw8 = '0' then
                     trace_kipar5 <= cpu_dataout;
                  elsif cpu_addr(0) = '0' then
                     trace_kipar5(7 downto 0) <= cpu_dataout(7 downto 0);
                  else
                     -- odd-address byte write: the CPU ALWAYS presents
                     -- the byte in cpu_dataout(7:0), never (15:8), for
                     -- either half -- mmu.vhd's own mmu_dato mux shifts
                     -- it up before use; this replicates that shift.
                     trace_kipar5(15 downto 8) <= cpu_dataout(7 downto 0);
                  end if;
               when x"F4EC" =>  -- 172354 octal = KIPAR6
                  if cpu_dw8 = '0' then
                     trace_kipar6 <= cpu_dataout;
                  elsif cpu_addr(0) = '0' then
                     trace_kipar6(7 downto 0) <= cpu_dataout(7 downto 0);
                  else
                     trace_kipar6(15 downto 8) <= cpu_dataout(7 downto 0);
                  end if;
               when x"F4FA" =>  -- 172372 octal = KDPAR5
                  if cpu_dw8 = '0' then
                     trace_kdpar5 <= cpu_dataout;
                  elsif cpu_addr(0) = '0' then
                     trace_kdpar5(7 downto 0) <= cpu_dataout(7 downto 0);
                  else
                     trace_kdpar5(15 downto 8) <= cpu_dataout(7 downto 0);
                  end if;
               when x"F4FC" =>  -- 172374 octal = KDPAR6
                  if cpu_dw8 = '0' then
                     trace_kdpar6 <= cpu_dataout;
                  elsif cpu_addr(0) = '0' then
                     trace_kdpar6(7 downto 0) <= cpu_dataout(7 downto 0);
                  else
                     trace_kdpar6(15 downto 8) <= cpu_dataout(7 downto 0);
                  end if;
               when others =>
                  null;
            end case;
         end if;
      end if;
   end process;
end architecture rtl;
