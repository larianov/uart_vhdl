--------------------------------------------------------------------------------
-- uart_bfm_pkg
--   Bus Functional Model of an asynchronous UART line.
--   Written from the UART *specification*, not from the RTL, so it acts as an
--   independent reference ("golden model") for the DUT:
--     * uart_send : drives an ideal frame (optionally with baud offset in ppm,
--                   corrupted parity or broken stop bit)
--     * uart_recv : decodes a frame by sampling at ideal mid-bit points and
--                   measures every line edge against the ideal bit grid
--------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

package uart_bfm_pkg is

    type uart_cfg_t is record
        baud       : positive;
        data_bits  : positive;
        stop_bits  : positive;
        parity_en  : boolean;
        parity_odd : boolean;   -- false = even, true = odd
    end record;

    type uart_frame_t is record
        data          : natural;
        start_ok      : boolean;  -- start bit low at mid-bit
        parity_ok     : boolean;
        stop_ok       : boolean;  -- all stop bits high at mid-bit
        bits_valid    : boolean;  -- no X/U/Z sampled
        timing_ok     : boolean;  -- all edges within tolerance
        worst_err_pct : real;     -- worst equivalent baud error seen, %
    end record;

    function bit_period(cfg : uart_cfg_t; ppm : integer := 0) return time;
    function frame_bits(cfg : uart_cfg_t) return positive;
    function parity_of(v : std_logic_vector; odd : boolean) return std_logic;
    function cfg_image(cfg : uart_cfg_t) return string;

    procedure uart_send(
        signal   line       : out std_logic;
        constant cfg        : in  uart_cfg_t;
        constant data       : in  natural;
        constant ppm        : in  integer := 0;
        constant bad_parity : in  boolean := false;
        constant bad_stop   : in  boolean := false);

    -- Must be called right after the falling edge of the start bit.
    -- An edge at time dt after the start edge is expected at n*T (n = nearest
    -- integer). It is accepted if |dt - n*T| <= tol_pct% * n*T + slack.
    -- 'slack' covers clock quantisation of the DUT's baud divider.
    procedure uart_recv(
        signal   line    : in  std_logic;
        constant cfg     : in  uart_cfg_t;
        constant tol_pct : in  real;
        constant slack   : in  time;
        variable frame   : out uart_frame_t);

end package uart_bfm_pkg;


package body uart_bfm_pkg is

    function bit_period(cfg : uart_cfg_t; ppm : integer := 0) return time is
        variable t_ps : real;
    begin
        t_ps := 1.0e12 / (real(cfg.baud) * (1.0 + real(ppm) / 1.0e6));
        return integer(t_ps) * 1 ps;
    end function;

    function frame_bits(cfg : uart_cfg_t) return positive is
    begin
        if cfg.parity_en then
            return 1 + cfg.data_bits + 1 + cfg.stop_bits;
        end if;
        return 1 + cfg.data_bits + cfg.stop_bits;
    end function;

    function parity_of(v : std_logic_vector; odd : boolean) return std_logic is
        variable acc : std_logic := '0';
    begin
        for i in v'range loop
            acc := acc xor v(i);
        end loop;
        if odd then
            return not acc;
        end if;
        return acc;
    end function;

    function cfg_image(cfg : uart_cfg_t) return string is
        variable p : character := 'N';
    begin
        if cfg.parity_en then
            if cfg.parity_odd then p := 'O'; else p := 'E'; end if;
        end if;
        return integer'image(cfg.data_bits) & p & integer'image(cfg.stop_bits)
               & " @ " & integer'image(cfg.baud) & " baud";
    end function;

    procedure uart_send(
        signal   line       : out std_logic;
        constant cfg        : in  uart_cfg_t;
        constant data       : in  natural;
        constant ppm        : in  integer := 0;
        constant bad_parity : in  boolean := false;
        constant bad_stop   : in  boolean := false) is
        constant T : time := bit_period(cfg, ppm);
        constant v : std_logic_vector(cfg.data_bits - 1 downto 0)
                   := std_logic_vector(to_unsigned(data, cfg.data_bits));
        variable p : std_logic;
    begin
        line <= '0';                                    -- start bit
        wait for T;
        for i in 0 to cfg.data_bits - 1 loop            -- LSB first
            line <= v(i);
            wait for T;
        end loop;
        if cfg.parity_en then
            p := parity_of(v, cfg.parity_odd);
            if bad_parity then p := not p; end if;
            line <= p;
            wait for T;
        end if;
        for s in 1 to cfg.stop_bits loop
            if bad_stop and s = 1 then line <= '0'; else line <= '1'; end if;
            wait for T;
        end loop;
        line <= '1';
    end procedure;

    procedure uart_recv(
        signal   line    : in  std_logic;
        constant cfg     : in  uart_cfg_t;
        constant tol_pct : in  real;
        constant slack   : in  time;
        variable frame   : out uart_frame_t) is
        constant T      : time     := bit_period(cfg);
        constant T_ps   : real     := real(T / 1 ps);
        constant NBITS  : positive := frame_bits(cfg);
        variable t0     : time;
        variable target : time;
        variable prev   : std_logic;
        variable smp    : std_logic;
        variable dt_ps  : real;
        variable n      : integer;
        variable dev    : real;
        variable errp   : real;
        variable par    : std_logic := '0';
        variable exp_p  : std_logic;
        variable fr     : uart_frame_t;
    begin
        t0 := now;
        fr := (data => 0, start_ok => true, parity_ok => true, stop_ok => true,
               bits_valid => true, timing_ok => true, worst_err_pct => 0.0);

        for k in 0 to NBITS - 1 loop
            target := t0 + T / 2 + k * T;
            -- wait for the sampling point, measuring every edge on the way
            while now < target loop
                prev := line;
                wait on line for target - now;
                if line /= prev then
                    dt_ps := real((now - t0) / 1 ps);
                    n     := integer(dt_ps / T_ps);
                    if n >= 1 then
                        dev  := abs(dt_ps - real(n) * T_ps);
                        errp := dev / (real(n) * T_ps) * 100.0;
                        if dev > tol_pct / 100.0 * real(n) * T_ps + real(slack / 1 ps) then
                            fr.timing_ok := false;
                        end if;
                        if errp > fr.worst_err_pct then
                            fr.worst_err_pct := errp;
                        end if;
                    end if;
                end if;
            end loop;

            smp := to_x01(line);
            if smp = 'X' then
                fr.bits_valid := false;
            end if;

            if k = 0 then
                fr.start_ok := (smp = '0');
            elsif k <= cfg.data_bits then
                if smp = '1' then
                    fr.data := fr.data + 2 ** (k - 1);
                    par     := par xor '1';
                end if;
            elsif cfg.parity_en and k = cfg.data_bits + 1 then
                if cfg.parity_odd then exp_p := not par; else exp_p := par; end if;
                fr.parity_ok := (smp = exp_p);
            else
                fr.stop_ok := fr.stop_ok and (smp = '1');
            end if;
        end loop;

        frame := fr;
    end procedure;

end package body uart_bfm_pkg;
