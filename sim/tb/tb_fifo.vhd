--------------------------------------------------------------------------------
-- tb_fifo
--   Self-checking unit testbench for entity work.fifo.
--
--   A behavioural reference model (a plain queue) runs in lock-step with the
--   DUT. Every clock cycle all outputs are compared with the model:
--     empty, full, threshold_act, push_err, pop_err, byte_out_pl
--
--   Phases: reset -> directed corner cases -> constrained-random traffic with
--   fill-heavy / drain-heavy / balanced bias -> reset during traffic.
--   Functional coverage bins are counted and every reachable bin must be hit.
--------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;
use std.textio.all;

use work.tb_util_pkg.all;

entity tb_fifo is
    generic(
        g_byte_size  : positive := 8;
        g_fifo_size  : positive := 16;
        g_threshold  : natural  := 1;
        g_force_wrap : natural  := 0;      -- 0 = reject when full, 1 = overwrite oldest
        g_seed       : positive := 1;
        g_num_cycles : positive := 20_000; -- random cycles per bias phase
        g_max_errors : natural  := 20
    );
end entity tb_fifo;

architecture sim of tb_fifo is

    constant C_CLK_PERIOD : time    := 10 ns;
    constant C_MAX_DATA   : natural := 2 ** minimum(g_byte_size, 30) - 1;
    constant C_WRAP       : boolean := g_force_wrap /= 0;

    signal clk           : std_logic := '0';
    signal rst           : std_logic := '1';
    signal push          : std_logic := '0';
    signal pop           : std_logic := '0';
    signal byte_pl       : std_logic_vector(g_byte_size - 1 downto 0) := (others => '0');
    signal byte_out_pl   : std_logic_vector(g_byte_size - 1 downto 0);
    signal threshold_act : std_logic;
    signal empty         : std_logic;
    signal full          : std_logic;
    signal push_err      : std_logic;
    signal pop_err       : std_logic;
    signal sim_done      : boolean := false;

    function sl(b : boolean) return std_logic is
    begin
        if b then return '1'; end if;
        return '0';
    end function;

begin

    clk <= not clk after C_CLK_PERIOD / 2 when not sim_done;

    dut : entity work.fifo
        generic map(
            byte_size  => g_byte_size,
            fifo_size  => g_fifo_size,
            threshold  => g_threshold,
            force_wrap => sl(C_WRAP))
        port map(
            push          => push,
            byte_pl       => byte_pl,
            rst           => rst,
            clk           => clk,
            threshold_act => threshold_act,
            empty         => empty,
            full          => full,
            push_err      => push_err,
            pop_err       => pop_err,
            pop           => pop,
            byte_out_pl   => byte_out_pl);

    main : process
        -- reference model ---------------------------------------------------
        type q_t is array (0 to g_fifo_size - 1) of natural;
        variable q        : q_t;
        variable q_head   : natural := 0;
        variable q_size   : natural := 0;
        variable m_out    : natural := 0;
        variable m_push_e : std_logic := '0';
        variable m_pop_e  : std_logic := '0';

        -- coverage bins -----------------------------------------------------
        variable cv_full        : natural := 0;  -- reached full
        variable cv_push_reject : natural := 0;  -- push into full, rejected
        variable cv_wrap        : natural := 0;  -- push into full, oldest overwritten
        variable cv_pop_empty   : natural := 0;  -- pop from empty -> error
        variable cv_bypass      : natural := 0;  -- push+pop on empty
        variable cv_pp_full     : natural := 0;  -- push+pop on full
        variable cv_pp_mid      : natural := 0;  -- push+pop, partially filled
        variable cv_thr_rise    : natural := 0;  -- threshold_act 0 -> 1
        variable cv_thr_fall    : natural := 0;  -- threshold_act 1 -> 0
        variable prev_thr       : boolean := false;

        variable seed1, seed2 : positive;
        variable cycles       : natural := 0;
        variable err0         : natural;
        variable summary      : line;

        impure function rnd(lo, hi : integer) return integer is
            variable r : real;
        begin
            uniform(seed1, seed2, r);
            return lo + integer(floor(r * real(hi - lo + 1)));
        end function;

        procedure model_reset is
        begin
            q_head   := 0;
            q_size   := 0;
            m_out    := 0;
            m_push_e := '0';
            m_pop_e  := '0';
        end procedure;

        -- update the model with the inputs the DUT has just sampled
        procedure model_step(p, o : boolean; d : natural) is
            variable was_size : natural := q_size;
        begin
            -- coverage of the input situation
            if p and o and was_size = 0 then cv_bypass := cv_bypass + 1; end if;
            if p and o and was_size = g_fifo_size then cv_pp_full := cv_pp_full + 1; end if;
            if p and o and was_size > 0 and was_size < g_fifo_size then cv_pp_mid := cv_pp_mid + 1; end if;

            -- pop: served from the queue, or bypassed from the input when empty
            if o then
                if was_size > 0 then
                    m_out   := q(q_head);
                    q_head  := (q_head + 1) mod g_fifo_size;
                    q_size  := q_size - 1;
                    m_pop_e := '0';
                elsif p then
                    m_out   := d;
                    m_pop_e := '0';
                else
                    m_pop_e := '1';
                    cv_pop_empty := cv_pop_empty + 1;
                end if;
            end if;

            -- push
            if p and not (o and was_size = 0) then
                if was_size < g_fifo_size or o then
                    q((q_head + q_size) mod g_fifo_size) := d;
                    q_size   := q_size + 1;
                    m_push_e := '0';
                elsif C_WRAP then
                    -- full and no pop: overwrite the oldest entry
                    q(q_head) := d;
                    q_head    := (q_head + 1) mod g_fifo_size;
                    m_push_e  := '0';
                    cv_wrap   := cv_wrap + 1;
                else
                    m_push_e := '1';
                    cv_push_reject := cv_push_reject + 1;
                end if;
            elsif p then
                m_push_e := '0';               -- bypass counts as accepted push
            end if;
        end procedure;

        procedure compare(ctx : string) is
            variable thr : boolean := q_size > g_threshold;
        begin
            check_sl(empty,         sl(q_size = 0),           ctx & " empty");
            check_sl(full,          sl(q_size = g_fifo_size), ctx & " full");
            check_sl(threshold_act, sl(thr),                  ctx & " threshold_act (size " & integer'image(q_size) & ")");
            check_sl(push_err,      m_push_e,                 ctx & " push_err");
            check_sl(pop_err,       m_pop_e,                  ctx & " pop_err");
            check_equal(to_integer(unsigned(byte_out_pl)), m_out, ctx & " byte_out_pl");
            if q_size = g_fifo_size then cv_full := cv_full + 1; end if;
            if thr and not prev_thr then cv_thr_rise := cv_thr_rise + 1; end if;
            if prev_thr and not thr then cv_thr_fall := cv_thr_fall + 1; end if;
            prev_thr := thr;
        end procedure;

        -- apply one clock cycle of stimulus and check the result
        procedure cycle(p, o : boolean; ctx : string) is
            variable d : natural := rnd(0, C_MAX_DATA);
        begin
            push    <= sl(p);
            pop     <= sl(o);
            byte_pl <= std_logic_vector(to_unsigned(d, g_byte_size));
            wait until falling_edge(clk);       -- DUT sampled at the rising edge
            model_step(p, o, d);
            compare(ctx);
            cycles := cycles + 1;
        end procedure;

        procedure do_reset is
        begin
            push <= '0';
            pop  <= '0';
            rst  <= '1';
            for i in 1 to 3 loop
                wait until falling_edge(clk);
            end loop;
            rst <= '0';
            model_reset;
            prev_thr := false;
            compare("after reset:");
        end procedure;

        procedure phase_begin(name : string) is
        begin
            err0 := log_error_count;
            log_note("==================== " & name & " ====================");
        end procedure;

        procedure phase_end(name : string) is
            variable e : natural := log_error_count - err0;
        begin
            if e = 0 then
                write(summary, LF & "    PASS  " & name);
            else
                write(summary, LF & "    FAIL  " & name & "  (" & integer'image(e) & " errors)");
            end if;
        end procedure;

        procedure random_phase(name : string; p_push, p_pop : natural) is
        begin
            phase_begin(name);
            for i in 1 to g_num_cycles loop
                cycle(rnd(0, 99) < p_push, rnd(0, 99) < p_pop, name & ":");
            end loop;
            phase_end(name);
        end procedure;

        procedure cov_bin(name : string; hits : natural; reachable : boolean := true) is
        begin
            if reachable then
                check(hits > 0, "coverage hole: " & name & " never exercised");
                write(summary, LF & "    cover " & name & " = " & integer'image(hits));
            else
                check(hits = 0, "coverage: " & name & " must be unreachable in this config, hit "
                                & integer'image(hits) & " times");
                write(summary, LF & "    cover " & name & " = n/a");
            end if;
        end procedure;

    begin
        seed1 := g_seed;
        seed2 := 104729;
        log_set_max_errors(g_max_errors);
        write(summary, string'("Test summary:"));
        log_note("tb_fifo: depth " & integer'image(g_fifo_size) & ", width " & integer'image(g_byte_size)
                 & ", threshold " & integer'image(g_threshold) & ", force_wrap " & integer'image(g_force_wrap)
                 & ", seed " & integer'image(g_seed));
        wait until falling_edge(clk);

        -----------------------------------------------------------------------
        phase_begin("reset");
        do_reset;
        phase_end("reset");

        -----------------------------------------------------------------------
        phase_begin("directed_corners");
        cycle(false, true,  "pop on empty:");                 -- underflow
        cycle(true,  true,  "push+pop on empty:");            -- bypass
        for i in 1 to g_fifo_size loop                        -- fill
            cycle(true, false, "fill:");
        end loop;
        cycle(true,  false, "push on full:");                 -- overflow / wrap
        cycle(true,  false, "push on full again:");
        cycle(true,  true,  "push+pop on full:");
        for i in 1 to g_fifo_size loop                        -- drain
            cycle(false, true, "drain:");
        end loop;
        cycle(false, true,  "pop after drain:");
        cycle(false, false, "idle:");
        phase_end("directed_corners");

        -----------------------------------------------------------------------
        random_phase("random_fill_heavy",  80, 20);
        random_phase("random_drain_heavy", 20, 80);
        random_phase("random_balanced",    50, 50);
        random_phase("random_burst",       95, 95);

        -----------------------------------------------------------------------
        phase_begin("reset_during_traffic");
        for i in 1 to g_fifo_size / 2 + 1 loop
            cycle(true, false, "pre-reset fill:");
        end loop;
        do_reset;
        cycle(false, true, "pop after reset:");
        cycle(true,  false, "push after reset:");
        cycle(false, true,  "pop after reset 2:");
        phase_end("reset_during_traffic");

        -----------------------------------------------------------------------
        cov_bin("full_reached",      cv_full);
        cov_bin("push_rejected",     cv_push_reject, not C_WRAP);
        cov_bin("wrap_overwrite",    cv_wrap,        C_WRAP);
        cov_bin("pop_empty",         cv_pop_empty);
        cov_bin("push_pop_empty",    cv_bypass);
        cov_bin("push_pop_full",     cv_pp_full);
        cov_bin("push_pop_partial",  cv_pp_mid,      g_fifo_size > 1);
        cov_bin("threshold_rise",    cv_thr_rise,    g_threshold < g_fifo_size);
        cov_bin("threshold_fall",    cv_thr_fall,    g_threshold < g_fifo_size);

        writeline(output, summary);
        log_note("Cycles : " & integer'image(cycles));
        log_note("Checks : " & integer'image(log_check_count));
        log_note("Errors : " & integer'image(log_error_count));

        sim_done <= true;
        if log_error_count = 0 then
            log_note("TEST PASSED");
            wait for C_CLK_PERIOD;
            std.env.finish;
        else
            log_note("TEST FAILED");
            report "TEST FAILED" severity failure;
        end if;
        wait;
    end process;

end architecture sim;
