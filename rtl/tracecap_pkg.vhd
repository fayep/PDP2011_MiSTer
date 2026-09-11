-- Shared types/constants for the generic event-trace capture facility
-- (tracecap.vhd + tracecap_dbg.sv). Every event producer (disk-transfer
-- completion, MMU PAR write, or anything added later) packages its own
-- specifics into this ONE generic shape before handing it to the shared
-- capture bus -- tracecap.vhd itself has zero knowledge of what RL11,
-- RH11, or the MMU actually are, so adding a new source later is "write
-- a small adapter emitting this shape," never "touch the capture engine".
--
-- Faye: "I kinda want to make the same class of artifact from the FPGA
-- now" -- this mirrors pdp11dis/diskmem.py's Provenance idea (kind +
-- a small number of fields, not a bespoke record per source), just
-- captured directly in hardware instead of parsed from a SIMH log.

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;

package tracecap_pkg is

   constant TRACE_NUM_SOURCES : integer := 4;  -- e.g. 0=RL0 disk, 1=RH0 disk,
                                                -- 2=MMU kernel PAR write,
                                                -- 3=reserved. Unused indices'
                                                -- src_valid tied to '0'.

   constant TRACE_A_WIDTH    : integer := 22;  -- disk sector number / physical addr
   constant TRACE_B_WIDTH    : integer := 22;  -- destination physical addr / PAR value
   constant TRACE_C_WIDTH    : integer := 16;  -- word count / misc
   constant TRACE_D_WIDTH    : integer := 64;  -- disk events only:
                                                -- {KDPAR5,KDPAR6,KIPAR5,KIPAR6}, sampled by
                                                -- rl11.vhd/rh11.vhd from mmu.vhd's live copies of
                                                -- those four registers, at the SAME READ+GO trigger
                                                -- moment as a/b/c -- held stable for the whole
                                                -- transaction, same CDC-safety property a/b/c
                                                -- already have. NOT a standalone PAR-write event:
                                                -- PAR5/6 change far too often (confirmed on real
                                                -- hardware: 16222 of 16384 ring entries were
                                                -- PAR-write events, zero disk events survived) to
                                                -- log as their own events, even scoped to just
                                                -- these registers with real value-change dedup.
                                                -- KIPAR5/6 (kernel I-space) are the pair RSTS's
                                                -- real overlay-mapping mechanism actually uses
                                                -- (notes/rsts-init-disasm.md's MAPCOPY_PARAM);
                                                -- KDPAR5/6 (kernel D-space) were this session's
                                                -- original wrong guess, kept anyway per the
                                                -- eventual goal of tracing all MMU registers.
   constant TRACE_KIND_WIDTH : integer := 4;
   constant TRACE_SRC_WIDTH  : integer := 4;

   subtype trace_a_t    is std_logic_vector(TRACE_A_WIDTH-1 downto 0);
   subtype trace_b_t    is std_logic_vector(TRACE_B_WIDTH-1 downto 0);
   subtype trace_c_t    is std_logic_vector(TRACE_C_WIDTH-1 downto 0);
   subtype trace_d_t    is std_logic_vector(TRACE_D_WIDTH-1 downto 0);
   subtype trace_kind_t is std_logic_vector(TRACE_KIND_WIDTH-1 downto 0);
   subtype trace_src_t  is std_logic_vector(TRACE_SRC_WIDTH-1 downto 0);

   type trace_a_array    is array (0 to TRACE_NUM_SOURCES-1) of trace_a_t;
   type trace_b_array    is array (0 to TRACE_NUM_SOURCES-1) of trace_b_t;
   type trace_c_array    is array (0 to TRACE_NUM_SOURCES-1) of trace_c_t;
   type trace_d_array    is array (0 to TRACE_NUM_SOURCES-1) of trace_d_t;
   type trace_kind_array is array (0 to TRACE_NUM_SOURCES-1) of trace_kind_t;
   type trace_src_array  is array (0 to TRACE_NUM_SOURCES-1) of trace_src_t;

   -- kind values -- keep in sync with tracecap_dbg.sv's header comment
   constant TRACE_KIND_DISK : trace_kind_t := "0001";  -- a=LBN, b=dest phys addr, c=word count,
                                                        -- d={KDPAR5,KDPAR6,KIPAR5,KIPAR6}
   constant TRACE_KIND_PARW : trace_kind_t := "0010";  -- retired: no producer emits this kind any more

end package tracecap_pkg;
