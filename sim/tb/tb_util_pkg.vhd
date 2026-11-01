--------------------------------------------------------------------------------
-- tb_util_pkg
--   Generic verification utilities (no external frameworks required):
--     * tb_log      : global logger with check/error/warning counters
--     * int_queue_t : FIFO queue used as a scoreboard (expected data)
--     * helpers     : hex(), fmt2(), contains()
--------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;

package tb_util_pkg is

    ---------------------------------------------------------------------------
    -- Logger
    ---------------------------------------------------------------------------
    type tb_log_t is protected
        procedure note(msg : string);
        procedure warn(msg : string);
        procedure fail(msg : string);
        procedure check(cond : boolean; msg : string);
        procedure set_max_errors(n : natural);   -- 0 = unlimited
        impure function error_count   return natural;
        impure function warning_count return natural;
        impure function check_count   return natural;
    end protected tb_log_t;

    procedure log_note(msg : string);
    procedure log_warn(msg : string);
    procedure log_fail(msg : string);
    procedure check(cond : boolean; msg : string);
    procedure check_equal(got, exp : integer; msg : string);
    procedure check_sl(got, exp : std_logic; msg : string);
    procedure log_set_max_errors(n : natural);
    impure function log_error_count return natural;
    impure function log_check_count return natural;

    ---------------------------------------------------------------------------
    -- Scoreboard queue
    ---------------------------------------------------------------------------
    type int_queue_t is protected
        procedure push(v : integer);
        impure function pop return integer;
        impure function count return natural;
        procedure clear;
        procedure drop_oldest(k : natural);
    end protected int_queue_t;

    ---------------------------------------------------------------------------
    -- Helpers
    ---------------------------------------------------------------------------
    function hex(v : natural) return string;
    function fmt2(r : real) return string;          -- real with 2 decimals
    function contains(s : string; sub : string) return boolean;

end package tb_util_pkg;


package body tb_util_pkg is

    procedure emit(tag : string; msg : string) is
        variable l : line;
    begin
        write(l, now, right, 14, ns);
        write(l, string'("  ") & tag & "  " & msg);
        writeline(output, l);
    end procedure emit;

    type tb_log_t is protected body
        variable errs     : natural := 0;
        variable warns    : natural := 0;
        variable chks     : natural := 0;
        variable max_errs : natural := 0;

        procedure note(msg : string) is
        begin
            emit("[INFO ]", msg);
        end procedure;

        procedure warn(msg : string) is
        begin
            warns := warns + 1;
            emit("[WARN ]", msg);
        end procedure;

        procedure fail(msg : string) is
        begin
            errs := errs + 1;
            emit("[ERROR]", msg);
            if max_errs /= 0 and errs >= max_errs then
                emit("[FATAL]", "error limit (" & integer'image(max_errs) & ") reached");
                emit("[FATAL]", "TEST FAILED");
                report "Error limit reached - TEST FAILED" severity failure;
            end if;
        end procedure;

        procedure check(cond : boolean; msg : string) is
        begin
            chks := chks + 1;
            if not cond then
                fail(msg);
            end if;
        end procedure;

        procedure set_max_errors(n : natural) is
        begin
            max_errs := n;
        end procedure;

        impure function error_count return natural is
        begin
            return errs;
        end function;

        impure function warning_count return natural is
        begin
            return warns;
        end function;

        impure function check_count return natural is
        begin
            return chks;
        end function;
    end protected body tb_log_t;

    shared variable tb_log : tb_log_t;

    procedure log_set_max_errors(n : natural) is
    begin
        tb_log.set_max_errors(n);
    end procedure;

    impure function log_error_count return natural is
    begin
        return tb_log.error_count;
    end function;

    impure function log_check_count return natural is
    begin
        return tb_log.check_count;
    end function;

    procedure log_note(msg : string) is
    begin
        tb_log.note(msg);
    end procedure;

    procedure log_warn(msg : string) is
    begin
        tb_log.warn(msg);
    end procedure;

    procedure log_fail(msg : string) is
    begin
        tb_log.fail(msg);
    end procedure;

    procedure check(cond : boolean; msg : string) is
    begin
        tb_log.check(cond, msg);
    end procedure;

    procedure check_equal(got, exp : integer; msg : string) is
    begin
        tb_log.check(got = exp, msg & ": got " & hex(got) & ", expected " & hex(exp));
    end procedure;

    procedure check_sl(got, exp : std_logic; msg : string) is
    begin
        tb_log.check(got = exp, msg & ": got '" & std_logic'image(got)(2)
                                & "', expected '" & std_logic'image(exp)(2) & "'");
    end procedure;

    type int_queue_t is protected body
        constant C_DEPTH : natural := 8192;
        type arr_t is array (0 to C_DEPTH - 1) of integer;
        variable buf : arr_t;
        variable rd  : natural := 0;
        variable wr  : natural := 0;
        variable n   : natural := 0;

        procedure push(v : integer) is
        begin
            assert n < C_DEPTH report "int_queue_t overflow" severity failure;
            buf(wr) := v;
            wr      := (wr + 1) mod C_DEPTH;
            n       := n + 1;
        end procedure;

        impure function pop return integer is
            variable v : integer;
        begin
            assert n > 0 report "int_queue_t: pop from empty queue" severity failure;
            v  := buf(rd);
            rd := (rd + 1) mod C_DEPTH;
            n  := n - 1;
            return v;
        end function;

        impure function count return natural is
        begin
            return n;
        end function;

        procedure clear is
        begin
            rd := 0;
            wr := 0;
            n  := 0;
        end procedure;

        procedure drop_oldest(k : natural) is
        begin
            for i in 1 to k loop
                if n > 0 then
                    rd := (rd + 1) mod C_DEPTH;
                    n  := n - 1;
                end if;
            end loop;
        end procedure;
    end protected body int_queue_t;

    function hex(v : natural) return string is
    begin
        return "0x" & to_hstring(std_logic_vector(to_unsigned(v, 16)));
    end function;

    function fmt2(r : real) return string is
        variable s    : integer := integer(abs(r) * 100.0);
        variable frac : integer := s mod 100;
        variable sign : string(1 to 1) := "-";
    begin
        if r >= 0.0 then
            if frac < 10 then
                return integer'image(s / 100) & ".0" & integer'image(frac);
            end if;
            return integer'image(s / 100) & "." & integer'image(frac);
        end if;
        if frac < 10 then
            return sign & integer'image(s / 100) & ".0" & integer'image(frac);
        end if;
        return sign & integer'image(s / 100) & "." & integer'image(frac);
    end function;

    function contains(s : string; sub : string) return boolean is
    begin
        if sub'length = 0 then
            return true;
        end if;
        if sub'length > s'length then
            return false;
        end if;
        for i in s'low to s'high - sub'length + 1 loop
            if s(i to i + sub'length - 1) = sub then
                return true;
            end if;
        end loop;
        return false;
    end function;

end package body tb_util_pkg;
