--------------------------------------------------------------------------------
-- tb_uart_main
--   System-level test of the top entity uart_main (board example):
--     "hello" -> DUT answers "world"
--     "world" -> DUT answers "hello"
--     noise   -> no answer
--   The UART settings must match those hard-coded in uart_main.
--------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;

use work.tb_util_pkg.all;
use work.uart_bfm_pkg.all;

entity tb_uart_main is
    generic(
        g_clk_freq   : positive := 50_000_000;
        g_baud       : positive := 2_000_000;   -- as in uart_main
        g_stop_bits  : positive := 2;
        g_parity_en  : natural  := 1;
        g_parity_odd : natural  := 0;
        g_gap_bits   : natural  := 2;           -- idle bits between sent chars
        g_tx_tol_pct : real     := 2.0;
        g_max_errors : natural  := 20
    );
end entity tb_uart_main;

architecture sim of tb_uart_main is

    constant C_CFG : uart_cfg_t := (
        baud       => g_baud,
        data_bits  => 8,
        stop_bits  => g_stop_bits,
        parity_en  => g_parity_en /= 0,
        parity_odd => g_parity_odd /= 0);

    constant C_CLK_PERIOD : time := 1 sec / g_clk_freq;
    constant C_BIT        : time := bit_period(C_CFG);
    constant C_FRAME      : time := C_BIT * frame_bits(C_CFG);

    signal clk      : std_logic := '0';
    signal rx_line  : std_logic := '1';
    signal tx_line  : std_logic;
    signal sim_done : boolean   := false;
    signal tx_chars : natural   := 0;

    shared variable sb : int_queue_t;

begin

    clk <= not clk after C_CLK_PERIOD / 2 when not sim_done;

    dut : entity work.uart_main
        port map(
            clk     => clk,
            rx_line => rx_line,
            tx_line => tx_line);

    tx_monitor : process
        variable fr  : uart_frame_t;
        variable exp : integer;
    begin
        wait for C_CLK_PERIOD * 4;
        loop
            wait until falling_edge(tx_line);
            uart_recv(tx_line, C_CFG, g_tx_tol_pct, C_CLK_PERIOD, fr);
            tx_chars <= tx_chars + 1;
            log_note("DUT sent '" & character'val(fr.data) & "' (" & hex(fr.data) & ")");
            check(fr.start_ok and fr.stop_ok and fr.bits_valid, "TX: framing error");
            check(fr.parity_ok, "TX: parity error");
            check(fr.timing_ok, "TX: bit timing out of tolerance, worst baud error "
                                & fmt2(fr.worst_err_pct) & "%");
            if sb.count = 0 then
                log_fail("TX: unexpected character " & hex(fr.data));
            else
                exp := sb.pop;
                check_equal(fr.data, exp, "TX: wrong character");
            end if;
        end loop;
    end process;

    main : process

        procedure send_str(s : string) is
        begin
            for i in s'range loop
                uart_send(rx_line, C_CFG, character'pos(s(i)));
                wait for C_BIT * g_gap_bits;
            end loop;
        end procedure;

        procedure expect_str(s : string) is
        begin
            for i in s'range loop
                sb.push(character'pos(s(i)));
            end loop;
        end procedure;

        procedure wait_answer(what : string) is
            variable t_end : time := now + C_FRAME * 40;
        begin
            while sb.count > 0 and now < t_end loop
                wait for C_BIT;
            end loop;
            check(sb.count = 0, what & ": answer incomplete, "
                                & integer'image(sb.count) & " chars missing");
            sb.clear;
            wait for C_FRAME * 4;
        end procedure;

        variable n0 : natural;

    begin
        log_set_max_errors(g_max_errors);
        log_note("tb_uart_main: " & cfg_image(C_CFG) & ", gap " & integer'image(g_gap_bits) & " bits");
        wait for C_CLK_PERIOD * 20;

        log_note("== hello -> world");
        expect_str("world");
        send_str("hello");
        wait_answer("hello->world");

        log_note("== world -> hello");
        expect_str("hello");
        send_str("world");
        wait_answer("world->hello");

        log_note("== noise prefix: xyhello -> world");
        expect_str("world");
        send_str("xyhello");
        wait_answer("xyhello->world");

        log_note("== no keyword -> silence");
        n0 := tx_chars;
        send_str("abcde");
        wait for C_FRAME * 20;
        check(tx_chars = n0, "no keyword: DUT must not answer");

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
