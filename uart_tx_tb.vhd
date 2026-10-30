library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity uart_tx_tb is
    generic (
        HI         : integer := 7;
        LO         : integer := 0;
        STOP_BITS  : integer := 1;
        EN_PARITY  : natural range 0 to 1 := 0;
        PARITY_ODD : natural range 0 to 1 := 1
    );
end uart_tx_tb;

architecture sim of uart_tx_tb is

    constant TEXT         : string  := "Hello" & CR & LF;

    constant FREQ         : integer := 50_000_000;
    constant BAUD         : integer := 115_200;
    constant N_BITS       : integer := HI - LO + 1;

    constant CLK_PERIOD   : time    := 1 sec / FREQ;
    constant CLKS_PER_BIT : integer := FREQ / BAUD;
    constant BIT_TIME     : time    := CLK_PERIOD * CLKS_PER_BIT;
    constant FRAME_BITS   : integer := 1 + N_BITS + EN_PARITY + STOP_BITS;
    constant FRAME_TIME   : time    := BIT_TIME * FRAME_BITS;
    constant TEXT_TIME    : time    := FRAME_TIME * TEXT'length;

    function to_sl(n : natural) return std_logic is
    begin
        if n = 1 then
            return '1';
        else
            return '0';
        end if;
    end function;

    signal clk      : std_logic := '0';
    signal start    : std_logic := '0';
    signal busy     : std_logic;
    signal tx       : std_logic;

    signal sim_done : std_logic := '0';
    signal rx_count : integer   := 0;
    signal errors   : integer   := 0;

begin

    dut : entity work.uart_tx
        generic map (
            strdata          => TEXT,
            freq          => FREQ,
            baud          => BAUD,
            hi            => HI,
            lo            => LO,
            amm_stop_bits => STOP_BITS,
            en_pairity    => EN_PARITY,
            pairity       => to_sl(PARITY_ODD)
        )
        port map (
            clk                => clk,
            start_transmitting => start,
            tx                 => tx,
            busy_wait          => busy
        );

    clk_gen : process
    begin
        while sim_done = '0' loop
            clk <= '0';
            wait for CLK_PERIOD / 2;
            clk <= '1';
            wait for CLK_PERIOD / 2;
        end loop;
        wait;
    end process;

    stimulus : process
    begin
        report "Config: data bits = " & integer'image(N_BITS)
             & ", parity = " & integer'image(EN_PARITY)
             & ", odd = " & integer'image(PARITY_ODD)
             & ", stop bits = " & integer'image(STOP_BITS)
             & ", text length = " & integer'image(TEXT'length);

        wait for 1 ms;

        wait until rising_edge(clk);
        start <= '1';
        wait until rising_edge(clk);
        start <= '0';

        if busy /= '1' then
            wait until busy = '1' for 10 * CLK_PERIOD;
        end if;
        assert busy = '1' report "busy_wait did not rise after start" severity error;

        wait until busy = '0' for 2 * TEXT_TIME;
        assert busy = '0' report "busy_wait did not fall: text takes too long" severity error;

        wait for 5 * BIT_TIME;

        wait until rising_edge(clk);
        start <= '1';
        wait until busy = '1' for 10 * CLK_PERIOD;
        wait until busy = '0' for 2 * TEXT_TIME;
        wait for TEXT_TIME;
        start <= '0';

        wait for 2 * FRAME_TIME;

        if rx_count = 2 * TEXT'length and errors = 0 then
            report "TEST PASSED: received " & integer'image(rx_count) & " frames";
        else
            report "TEST FAILED: frames " & integer'image(rx_count)
                 & "/" & integer'image(2 * TEXT'length)
                 & ", errors " & integer'image(errors)
                severity error;
        end if;

        sim_done <= '1';
        wait;
    end process;

    checker : process
        variable rx_val    : std_logic_vector(N_BITS - 1 downto 0);
        variable p_bit     : std_logic;
        variable acc       : std_logic;
        variable expected  : integer;
        variable idx       : integer;
        variable frame_t0  : time    := 0 ns;
        variable have_prev : boolean := false;
        variable err       : integer := 0;
        variable cnt       : integer := 0;
    begin
        wait until tx = '0';

        if have_prev and (now - frame_t0) < FRAME_TIME - CLK_PERIOD then
            report "Next start bit too early: " & time'image(now - frame_t0)
                 & " after previous start, minimum " & time'image(FRAME_TIME)
                severity error;
            err := err + 1;
        end if;
        frame_t0  := now;
        have_prev := true;

        wait for BIT_TIME / 2;
        if tx /= '0' then
            report "Start bit is not 0 in its middle" severity error;
            err := err + 1;
        end if;

        for i in 0 to N_BITS - 1 loop
            wait for BIT_TIME;
            rx_val(i) := tx;
        end loop;

        if EN_PARITY = 1 then
            wait for BIT_TIME;
            p_bit := tx;
            acc := '0';
            for i in rx_val'range loop
                acc := acc xor rx_val(i);
            end loop;
            if PARITY_ODD = 1 then
                acc := not acc;
            end if;
            if p_bit /= acc then
                report "Wrong parity bit in frame #" & integer'image(cnt)
                     & ": expected " & std_logic'image(acc)
                     & ", got " & std_logic'image(p_bit)
                    severity error;
                err := err + 1;
            end if;
        end if;

        for s in 1 to STOP_BITS loop
            wait for BIT_TIME;
            if tx /= '1' then
                report "Stop bit " & integer'image(s) & " is not 1 in frame #"
                     & integer'image(cnt) severity error;
                err := err + 1;
            end if;
        end loop;

        idx := TEXT'low + (cnt mod TEXT'length);
        expected := character'pos(TEXT(idx)) mod 2**N_BITS;

        report "Received value: " & integer'image(to_integer(unsigned(rx_val)));

        if cnt >= 2 * TEXT'length then
            report "Extra frame received (start repeated?)" severity error;
            err := err + 1;
        elsif to_integer(unsigned(rx_val)) /= expected then
            report "Wrong value in frame #" & integer'image(cnt)
                 & ": expected " & integer'image(expected)
                 & ", got " & integer'image(to_integer(unsigned(rx_val)))
                severity error;
            err := err + 1;
        end if;

        cnt      := cnt + 1;
        errors   <= err;
        rx_count <= cnt;
    end process;

end architecture sim;