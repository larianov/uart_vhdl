--------------------------------------------------------------------------------
-- tb_uart
--   Self-checking testbench for entity work.uart (TX + RX + FIFOs).
--
--   Architecture:
--     main        - test sequencer (stimulus), drives DUT inputs on falling
--                   clock edges, pushes expected data into scoreboards
--     tx_monitor  - decodes tx_line with the independent BFM, checks framing,
--                   parity, bit timing and compares with sb_tx
--     rx_reader   - pops bytes from the DUT RX FIFO and compares with sb_rx
--     watchdog    - global timeout
--
--   Result: prints "TEST PASSED" and calls std.env.finish, or prints
--           "TEST FAILED" and ends with severity failure (non-zero exit code).
--
--   Test selection: g_tests = "all" or a list of names, e.g.
--           -gg_tests="tx_directed,rx_overflow"
--------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;
use std.textio.all;

use work.tb_util_pkg.all;
use work.uart_bfm_pkg.all;

entity tb_uart is
    generic(
        g_clk_freq     : positive := 50_000_000;
        g_baud         : positive := 115_200;
        g_data_bits    : positive := 8;
        g_stop_bits    : positive := 1;
        g_parity_en    : natural  := 0;       -- 0 = none, 1 = enabled
        g_parity_odd   : natural  := 0;       -- 0 = even, 1 = odd
        g_fifo_size    : positive := 16;
        g_rx_threshold : natural  := 1;
        g_seed         : positive := 1;
        g_num_random   : positive := 64;      -- frames in random tests
        g_tx_tol_pct   : real     := 2.0;     -- allowed TX baud error, %
        g_rx_ppm       : natural  := 20_000;  -- sender offset in rx_baud_tol, ppm
        g_max_errors   : natural  := 50;      -- 0 = unlimited
        g_tests        : string   := "all"
    );
end entity tb_uart;

architecture sim of tb_uart is

    function sl(b : boolean) return std_logic is
    begin
        if b then return '1'; end if;
        return '0';
    end function;

    type nat_arr_t is array (natural range <>) of natural;

    constant C_CFG : uart_cfg_t := (
        baud       => g_baud,
        data_bits  => g_data_bits,
        stop_bits  => g_stop_bits,
        parity_en  => g_parity_en /= 0,
        parity_odd => g_parity_odd /= 0);

    constant C_CLK_PERIOD : time    := 1 sec / g_clk_freq;
    constant C_BIT        : time    := bit_period(C_CFG);
    constant C_FRAME      : time    := C_BIT * frame_bits(C_CFG);
    constant C_MAX_DATA   : natural := 2 ** g_data_bits - 1;
    -- one clock of quantisation is unavoidable for an integer baud divider
    constant C_SLACK      : time    := C_CLK_PERIOD;
    constant C_WATCHDOG   : time    := C_FRAME * (8 * g_num_random + 600);

    constant C_PATTERNS : nat_arr_t := (
        0,
        C_MAX_DATA,
        16#5555# mod (C_MAX_DATA + 1),
        16#AAAA# mod (C_MAX_DATA + 1),
        1,
        2 ** (g_data_bits - 1));

    -- DUT interface
    signal clk            : std_logic := '0';
    signal rst            : std_logic := '1';
    signal tx_enable      : std_logic := '0';
    signal tx_line        : std_logic;
    signal place_for_tx   : std_logic_vector(g_data_bits - 1 downto 0) := (others => '0');
    signal send_byte      : std_logic := '0';
    signal tx_fifo_full   : std_logic;
    signal tx_fifo_err    : std_logic;
    signal tx_busy        : std_logic;
    signal rx_enable      : std_logic := '0';
    signal rx_line        : std_logic := '1';
    signal place_for_rx   : std_logic_vector(g_data_bits - 1 downto 0);
    signal recieve_byte   : std_logic;
    signal rx_empty_fifo  : std_logic;
    signal rx_fifo_err    : std_logic;
    signal rx_uart_err    : std_logic;
    signal rx_water_level : std_logic;

    -- TB control / status
    shared variable sb_tx : int_queue_t;   -- expected bytes on tx_line
    shared variable sb_rx : int_queue_t;   -- expected bytes from RX FIFO

    signal rd_en        : std_logic := '0';  -- rx_reader enable
    signal rd_pop       : std_logic := '0';  -- pop from rx_reader
    signal tc_pop       : std_logic := '0';  -- pop from test sequencer
    signal mon_mask     : boolean   := false;
    signal sim_done     : boolean   := false;
    signal tx_frames    : natural   := 0;
    signal rx_bytes     : natural   := 0;
    signal tx_worst_pct : real      := 0.0;

begin

    clk          <= not clk after C_CLK_PERIOD / 2 when not sim_done;
    recieve_byte <= rd_pop or tc_pop;

    ---------------------------------------------------------------------------
    -- DUT
    ---------------------------------------------------------------------------
    dut : entity work.uart
        generic map(
            freq              => g_clk_freq,
            baud              => g_baud,
            amm_data_bits     => g_data_bits,
            amm_stop_bits     => g_stop_bits,
            en_pairity        => g_parity_en,
            pairity           => sl(g_parity_odd /= 0),
            fifo_size         => g_fifo_size,
            rx_treshold_level => g_rx_threshold)
        port map(
            clk            => clk,
            rst            => rst,
            tx_enable      => tx_enable,
            tx_line        => tx_line,
            place_for_tx   => place_for_tx,
            send_byte      => send_byte,
            tx_fifo_full   => tx_fifo_full,
            tx_fifo_err    => tx_fifo_err,
            tx_busy        => tx_busy,
            rx_enable      => rx_enable,
            rx_line        => rx_line,
            place_for_rx   => place_for_rx,
            recieve_byte   => recieve_byte,
            rx_empty_fifo  => rx_empty_fifo,
            rx_fifo_err    => rx_fifo_err,
            rx_uart_err    => rx_uart_err,
            rx_water_level => rx_water_level);

    ---------------------------------------------------------------------------
    -- TX monitor: decodes every frame on tx_line
    ---------------------------------------------------------------------------
    tx_monitor : process
        variable fr     : uart_frame_t;
        variable masked : boolean;
        variable exp    : integer;
    begin
        wait until rst = '0';
        loop
            wait until falling_edge(tx_line);
            masked := mon_mask;
            uart_recv(tx_line, C_CFG, g_tx_tol_pct, C_SLACK, fr);
            if masked or mon_mask then
                log_note("TX monitor: frame " & hex(fr.data) & " ignored (masked)");
            else
                tx_frames <= tx_frames + 1;
                check(fr.bits_valid, "TX: X/U/Z sampled on tx_line");
                check(fr.start_ok,   "TX: start bit is not low at mid-bit");
                check(fr.parity_ok,  "TX: wrong parity bit, data " & hex(fr.data));
                check(fr.stop_ok,    "TX: stop bit is not high (framing)");
                check(fr.timing_ok,  "TX: bit timing out of tolerance, worst baud error "
                                     & fmt2(fr.worst_err_pct) & "% > " & fmt2(g_tx_tol_pct) & "%");
                if fr.worst_err_pct > tx_worst_pct then
                    tx_worst_pct <= fr.worst_err_pct;
                end if;
                if sb_tx.count = 0 then
                    log_fail("TX: unexpected frame " & hex(fr.data));
                else
                    exp := sb_tx.pop;
                    check_equal(fr.data, exp, "TX: data mismatch");
                end if;
            end if;
        end loop;
    end process;

    ---------------------------------------------------------------------------
    -- RX reader: emulates the host reading the RX FIFO
    ---------------------------------------------------------------------------
    rx_reader : process
        variable got, exp : integer;
    begin
        wait until falling_edge(clk);
        if rd_en = '1' and rx_empty_fifo = '0' then
            rd_pop <= '1';
            wait until falling_edge(clk);
            rd_pop <= '0';
            got := to_integer(unsigned(place_for_rx));
            rx_bytes <= rx_bytes + 1;
            if sb_rx.count = 0 then
                log_fail("RX: unexpected byte " & hex(got) & " in FIFO");
            else
                exp := sb_rx.pop;
                check_equal(got, exp, "RX: data mismatch");
            end if;
        end if;
    end process;

    ---------------------------------------------------------------------------
    -- Watchdog
    ---------------------------------------------------------------------------
    watchdog : process
    begin
        wait until sim_done for C_WATCHDOG;
        if not sim_done then
            log_fail("WATCHDOG: simulation did not finish in " & time'image(C_WATCHDOG));
            report "TEST FAILED (watchdog)" severity failure;
        end if;
        wait;
    end process;

    ---------------------------------------------------------------------------
    -- Test sequencer
    ---------------------------------------------------------------------------
    main : process
        variable seed1    : positive := g_seed;
        variable seed2    : positive := 7919;
        variable cnt      : integer;
        variable f0       : natural;
        variable err0     : natural;
        variable summary  : line;
        variable n_pass   : natural := 0;
        variable n_fail   : natural := 0;
        variable cur_test : line;

        impure function rnd(lo, hi : integer) return integer is
            variable r : real;
        begin
            uniform(seed1, seed2, r);
            return lo + integer(floor(r * real(hi - lo + 1)));
        end function;

        impure function want(name : string) return boolean is
        begin
            return g_tests = "all" or contains(g_tests, name);
        end function;

        procedure tick(n : natural := 1) is
        begin
            for i in 1 to n loop
                wait until falling_edge(clk);
            end loop;
        end procedure;

        procedure test_begin(name : string) is
        begin
            deallocate(cur_test);
            write(cur_test, name);
            err0 := log_error_count;
            log_note("==================== TEST " & name & " ====================");
        end procedure;

        procedure test_end is
            variable e : natural := log_error_count - err0;
        begin
            if e = 0 then
                n_pass := n_pass + 1;
                write(summary, LF & "    PASS  " & cur_test.all);
                log_note("---- " & cur_test.all & ": PASS");
            else
                n_fail := n_fail + 1;
                write(summary, LF & "    FAIL  " & cur_test.all & "  (" & integer'image(e) & " errors)");
                log_note("---- " & cur_test.all & ": FAIL (" & integer'image(e) & " errors)");
            end if;
        end procedure;

        procedure test_skip(name, why : string) is
        begin
            write(summary, LF & "    SKIP  " & name & "  (" & why & ")");
            log_note("---- " & name & ": SKIP (" & why & ")");
        end procedure;

        -- push one word into TX FIFO (single-cycle strobe)
        procedure tx_push(v : natural; accepted : boolean := true) is
        begin
            tick;
            place_for_tx <= std_logic_vector(to_unsigned(v, g_data_bits));
            send_byte    <= '1';
            tick;
            send_byte    <= '0';
            if accepted then
                sb_tx.push(v);
            end if;
        end procedure;

        -- push respecting backpressure
        procedure tx_send(v : natural) is
        begin
            tick;
            while tx_fifo_full = '1' loop
                tick;
            end loop;
            tx_push(v);
        end procedure;

        -- drive one frame on rx_line with random phase vs. DUT clock
        procedure rx_send(v          : natural;
                          ppm        : integer := 0;
                          bad_parity : boolean := false;
                          bad_stop   : boolean := false;
                          expect     : boolean := true) is
        begin
            if expect and not bad_parity and not bad_stop then
                sb_rx.push(v);
            end if;
            wait for (C_CLK_PERIOD * rnd(0, 999)) / 1000;
            uart_send(rx_line, C_CFG, v, ppm, bad_parity, bad_stop);
        end procedure;

        procedure drain_tx is
            variable t_end : time := now + C_FRAME * (sb_tx.count + 4) * 2;
        begin
            tick;
            while (sb_tx.count > 0 or tx_busy = '1') and now < t_end loop
                tick;
            end loop;
            check(sb_tx.count = 0, "drain_tx: timeout, " & integer'image(sb_tx.count)
                                   & " expected frames never appeared on tx_line");
            check_sl(tx_busy, '0', "drain_tx: tx_busy after all frames sent");
            check_sl(tx_line, '1', "drain_tx: tx_line idle level");
            sb_tx.clear;
        end procedure;

        procedure drain_rx is
            variable t_end : time := now + C_FRAME * (sb_rx.count + 4) * 2;
        begin
            tick;
            while sb_rx.count > 0 and now < t_end loop
                tick;
            end loop;
            check(sb_rx.count = 0, "drain_rx: timeout, " & integer'image(sb_rx.count)
                                   & " expected bytes never read from RX FIFO");
            sb_rx.clear;
            tick(4);
        end procedure;

        procedure do_reset is
        begin
            rst <= '1';
            tick(8);
            rst <= '0';
            tick(4);
        end procedure;

    begin
        log_set_max_errors(g_max_errors);
        write(summary, string'("Test summary:"));
        log_note("tb_uart: " & cfg_image(C_CFG) & ", clk " & integer'image(g_clk_freq)
                 & " Hz, FIFO " & integer'image(g_fifo_size) & ", seed " & integer'image(g_seed));
        log_note("divider freq/baud = " & integer'image(g_clk_freq / g_baud)
                 & " clk, ideal = " & fmt2(real(g_clk_freq) / real(g_baud)) & " clk");

        tx_enable <= '1';
        rx_enable <= '1';
        do_reset;

        -----------------------------------------------------------------------
        if want("reset") then
            test_begin("reset");
            check_sl(tx_line,        '1', "reset: tx_line");
            check_sl(tx_busy,        '0', "reset: tx_busy");
            check_sl(tx_fifo_full,   '0', "reset: tx_fifo_full");
            check_sl(tx_fifo_err,    '0', "reset: tx_fifo_err");
            check_sl(rx_empty_fifo,  '1', "reset: rx_empty_fifo");
            check_sl(rx_fifo_err,    '0', "reset: rx_fifo_err");
            check_sl(rx_uart_err,    '0', "reset: rx_uart_err");
            check_sl(rx_water_level, '0', "reset: rx_water_level");
            test_end;
        end if;

        -----------------------------------------------------------------------
        if want("tx_directed") then
            test_begin("tx_directed");
            for i in C_PATTERNS'range loop
                tx_push(C_PATTERNS(i));
                drain_tx;
            end loop;
            test_end;
        end if;

        -----------------------------------------------------------------------
        if want("tx_random") then
            test_begin("tx_random");
            for i in 1 to g_num_random loop
                tx_send(rnd(0, C_MAX_DATA));
                tick(rnd(0, 3));
            end loop;
            drain_tx;
            test_end;
        end if;

        -----------------------------------------------------------------------
        if want("tx_overflow") then
            test_begin("tx_overflow");
            cnt := 0;
            while tx_fifo_full = '0' and cnt < g_fifo_size + 8 loop
                tx_push(rnd(0, C_MAX_DATA));
                cnt := cnt + 1;
            end loop;
            log_note("tx_overflow: FIFO full after " & integer'image(cnt) & " pushes");
            check_sl(tx_fifo_full, '1', "tx_overflow: tx_fifo_full");
            -- up to 2 words may already have left the FIFO (shifter + output register)
            check(cnt >= g_fifo_size and cnt <= g_fifo_size + 2,
                  "tx_overflow: FIFO became full after " & integer'image(cnt) & " pushes");
            tx_push(rnd(0, C_MAX_DATA), accepted => false);
            check_sl(tx_fifo_err,  '1', "tx_overflow: tx_fifo_err after push into full FIFO");
            check_sl(tx_fifo_full, '1', "tx_overflow: tx_fifo_full after rejected push");
            drain_tx;
            tx_push(rnd(0, C_MAX_DATA));
            check_sl(tx_fifo_err, '0', "tx_overflow: tx_fifo_err must clear after good push");
            drain_tx;
            test_end;
        end if;

        -----------------------------------------------------------------------
        if want("tx_disable") then
            test_begin("tx_disable");
            tx_enable <= '0';
            tick(2);
            f0 := tx_frames;
            for i in 1 to 3 loop
                tx_push(rnd(0, C_MAX_DATA));
            end loop;
            wait for C_FRAME * 3;
            tick;
            check(tx_frames = f0, "tx_disable: frames were sent while tx_enable = 0");
            check_sl(tx_line, '1', "tx_disable: tx_line must stay idle");
            tx_enable <= '1';
            drain_tx;
            check(tx_frames = f0 + 3, "tx_disable: expected 3 frames after re-enable, got "
                                      & integer'image(tx_frames - f0));
            test_end;
        end if;

        -----------------------------------------------------------------------
        rd_en <= '1';

        if want("rx_directed") then
            test_begin("rx_directed");
            for i in C_PATTERNS'range loop
                rx_send(C_PATTERNS(i));
                drain_rx;
                check_sl(rx_uart_err, '0', "rx_directed: rx_uart_err");
            end loop;
            test_end;
        end if;

        -----------------------------------------------------------------------
        if want("rx_random") then
            test_begin("rx_random");
            for i in 1 to g_num_random loop
                rx_send(rnd(0, C_MAX_DATA));
                wait for (C_BIT * rnd(0, 4)) / 4;      -- idle gap 0..1 bit
            end loop;
            drain_rx;
            check_sl(rx_uart_err, '0', "rx_random: rx_uart_err");
            test_end;
        end if;

        -----------------------------------------------------------------------
        if want("rx_baud_tol") then
            test_begin("rx_baud_tol");
            for sgn in 0 to 1 loop
                log_note("rx_baud_tol: sender offset " & integer'image((1 - 2 * sgn) * g_rx_ppm) & " ppm");
                for i in 1 to 16 loop                   -- back-to-back frames
                    rx_send(rnd(0, C_MAX_DATA), ppm => (1 - 2 * sgn) * g_rx_ppm);
                end loop;
                drain_rx;
                check_sl(rx_uart_err, '0', "rx_baud_tol: rx_uart_err");
            end loop;
            test_end;
        end if;

        -----------------------------------------------------------------------
        if want("rx_parity_err") then
            if C_CFG.parity_en then
                test_begin("rx_parity_err");
                rx_send(rnd(0, C_MAX_DATA));
                drain_rx;
                rx_send(rnd(0, C_MAX_DATA), bad_parity => true);
                tick(4);
                check_sl(rx_uart_err,   '1', "rx_parity_err: rx_uart_err after bad parity");
                check_sl(rx_empty_fifo, '1', "rx_parity_err: corrupted byte must be dropped");
                rx_send(rnd(0, C_MAX_DATA));
                drain_rx;
                check_sl(rx_uart_err, '0', "rx_parity_err: rx_uart_err must clear after good frame");
                test_end;
            else
                test_skip("rx_parity_err", "parity disabled");
            end if;
        end if;

        -----------------------------------------------------------------------
        if want("rx_framing_err") then
            test_begin("rx_framing_err");
            rx_send(rnd(0, C_MAX_DATA), bad_stop => true);
            wait for C_BIT;
            tick(4);
            check_sl(rx_uart_err,   '1', "rx_framing_err: rx_uart_err after broken stop bit");
            check_sl(rx_empty_fifo, '1', "rx_framing_err: corrupted byte must be dropped");
            rx_send(rnd(0, C_MAX_DATA));
            drain_rx;
            check_sl(rx_uart_err, '0', "rx_framing_err: rx_uart_err must clear after good frame");
            test_end;
        end if;

        -----------------------------------------------------------------------
        if want("rx_glitch") then
            test_begin("rx_glitch");
            tick;
            rx_line <= '0';                 -- short pulse: not a valid start bit
            wait for C_BIT / 4;
            rx_line <= '1';
            wait for C_FRAME * 2;
            tick;
            check_sl(rx_empty_fifo, '1', "rx_glitch: glitch produced a byte");
            check_sl(rx_uart_err,   '0', "rx_glitch: glitch produced an error");
            rx_send(rnd(0, C_MAX_DATA));    -- receiver must still work
            drain_rx;
            test_end;
        end if;

        -----------------------------------------------------------------------
        if want("rx_disable") then
            test_begin("rx_disable");
            rx_enable <= '0';
            tick(4);
            rx_send(rnd(0, C_MAX_DATA), expect => false);
            wait for C_BIT;
            tick(4);
            check_sl(rx_empty_fifo, '1', "rx_disable: byte received while rx_enable = 0");
            rx_enable <= '1';
            tick(4);
            rx_send(rnd(0, C_MAX_DATA));
            drain_rx;
            test_end;
        end if;

        -----------------------------------------------------------------------
        if want("rx_overflow") then
            test_begin("rx_overflow");
            rd_en <= '0';
            tick(4);
            for i in 1 to g_fifo_size + 3 loop
                rx_send(rnd(0, C_MAX_DATA));
                tick(4);
                check_sl(rx_empty_fifo, '0', "rx_overflow: rx_empty_fifo after " & integer'image(i) & " bytes");
                check_sl(rx_water_level, sl(minimum(i, g_fifo_size) > g_rx_threshold),
                         "rx_overflow: rx_water_level after " & integer'image(i) & " bytes");
            end loop;
            -- RX FIFO is built with force_wrap = '1': the oldest bytes are overwritten
            sb_rx.drop_oldest(3);
            rd_en <= '1';
            drain_rx;
            check_sl(rx_empty_fifo,  '1', "rx_overflow: FIFO must be empty after reading");
            check_sl(rx_water_level, '0', "rx_overflow: rx_water_level after reading");
            test_end;
        end if;

        -----------------------------------------------------------------------
        if want("rx_pop_empty") then
            test_begin("rx_pop_empty");
            rd_en <= '0';
            tick(2);
            check_sl(rx_empty_fifo, '1', "rx_pop_empty: precondition empty");
            tc_pop <= '1';
            tick;
            tc_pop <= '0';
            check_sl(rx_fifo_err,   '1', "rx_pop_empty: rx_fifo_err after pop from empty FIFO");
            check_sl(rx_empty_fifo, '1', "rx_pop_empty: still empty");
            rd_en <= '1';
            rx_send(rnd(0, C_MAX_DATA));
            drain_rx;
            check_sl(rx_fifo_err, '0', "rx_pop_empty: rx_fifo_err must clear after good pop");
            test_end;
        end if;

        -----------------------------------------------------------------------
        if want("full_duplex") then
            test_begin("full_duplex");
            for i in 1 to g_num_random loop
                tx_send(rnd(0, C_MAX_DATA));
                rx_send(rnd(0, C_MAX_DATA));
            end loop;
            drain_rx;
            drain_tx;
            test_end;
        end if;

        -----------------------------------------------------------------------
        if want("reset_traffic") then
            test_begin("reset_traffic");
            mon_mask <= true;
            for i in 1 to 4 loop
                tx_push(rnd(0, C_MAX_DATA), accepted => false);
            end loop;
            wait for C_FRAME / 2;           -- reset in the middle of a frame
            do_reset;
            check_sl(tx_line,       '1', "reset_traffic: tx_line after reset");
            check_sl(tx_busy,       '0', "reset_traffic: tx_busy after reset");
            check_sl(tx_fifo_full,  '0', "reset_traffic: tx_fifo_full after reset");
            check_sl(rx_empty_fifo, '1', "reset_traffic: rx_empty_fifo after reset");
            wait for C_FRAME * 2;
            tick;
            check_sl(tx_line, '1', "reset_traffic: no frames after reset");
            mon_mask <= false;
            tick;
            tx_send(rnd(0, C_MAX_DATA));    -- recovery
            rx_send(rnd(0, C_MAX_DATA));
            drain_rx;
            drain_tx;
            test_end;
        end if;

        -----------------------------------------------------------------------
        -- Final report
        -----------------------------------------------------------------------
        tick(10);
        check(sb_tx.count = 0, "end: sb_tx not empty");
        check(sb_rx.count = 0, "end: sb_rx not empty");

        writeline(output, summary);
        log_note("Config      : " & cfg_image(C_CFG));
        log_note("Tests       : " & integer'image(n_pass) & " passed, " & integer'image(n_fail) & " failed");
        log_note("Checks      : " & integer'image(log_check_count));
        log_note("Errors      : " & integer'image(log_error_count));
        log_note("TX frames   : " & integer'image(tx_frames));
        log_note("RX bytes    : " & integer'image(rx_bytes));
        log_note("TX worst baud error : " & fmt2(tx_worst_pct) & " %");

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
