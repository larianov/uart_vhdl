library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity uart_tx is 
    generic(
        freq : integer := 50000000;
        baud : integer := 115200;
        amm_data_bits : integer := 8;
        amm_stop_bits : integer := 1;
        fifo_size : integer := 16;
        en_pairity : integer := 0; -- 1 for on 0 for off
        pairity : std_logic := '1' --1 for odd 0 for even;
    );
    port(
        clk : in std_logic;
        rst : in std_logic;
        full : out std_logic;
        tx : out std_logic;
        push : in std_logic;
        push_err : out STD_LOGIC;
        byte_pl : in std_logic_vector(amm_data_bits-1 downto 0);
        uart_en : in std_logic;
        busy_wait : out std_logic
    );
end uart_tx;

architecture RTL of uart_tx is

signal data :std_logic_vector(amm_data_bits+en_pairity-1 downto 0) := (others => '0');
signal start : std_logic := '0';
signal busy : std_logic := '0';
type tx_t is (IDLE, POPPING, DATA_OP, WAIT_SENDER, EOF);
signal state : tx_t := IDLE;
signal empty : std_logic;
signal pop : std_logic := '0';
signal byte_out_pl : std_logic_vector(amm_data_bits-1 downto 0);






begin
    uart_transfer_inst : entity work.uart_transfer
        generic map(
            freq      => freq,
            baud      => baud,
            hi        => amm_data_bits+en_pairity-1,
            lo        => 0,
            stop_bits => amm_stop_bits
        )
        port map(
            data  => data,
            start => start,
            clk   => clk,
            busy  => busy,
            tx    => tx,
            rst   => rst
        );
    
    fifo_uart : entity work.fifo
        generic map(
            byte_size  => amm_data_bits,
            fifo_size  => fifo_size,
            threshold  => 1,
            force_wrap => '0'
        )
        port map(
            push          => push,
            byte_pl       => byte_pl,
            rst           => rst,
            clk           => clk,
            threshold_act => open,
            empty         => empty,
            full          => full,
            push_err      => push_err,
            pop_err       => open,
            pop           => pop,
            byte_out_pl   => byte_out_pl
        );
    
    clocking : process(clk) is
        variable acc : std_logic;
        variable temp_d : std_logic_vector(amm_data_bits-1 downto 0);
        
        begin
            if rising_edge(clk) then
                if rst = '1' then
                    data <= (others => '0');
                    start <= '0';
                    busy_wait <= '0';
                    pop <= '0';
                    state <= IDLE;
                else
                    case state is
                        when IDLE =>
                            if uart_en = '1' and empty = '0' then
                                state <= POPPING;
                                pop <= '1';
                                busy_wait <= '1';
                            elsif busy = '1' then
                                busy_wait <= '1';
                            else
                                busy_wait <= '0';
                            end if;
                        when POPPING =>
                            pop <= '0';
                            state <= DATA_OP;
                        when DATA_OP =>
                            if busy = '0' then
                                temp_d := byte_out_pl;
                                if en_pairity = 1 then
                                    acc := '0';
                                    for i in temp_d'range loop
                                        acc := temp_d(i) xor acc;
                                    end loop;
                                    if pairity = '1' then
                                        data <= (not acc) & temp_d;
                                    else
                                        data <= (acc) & temp_d;                                    
                                    end if;
                                else
                                    data <= temp_d;
                                end if;
                                start <= '1';
                                state <= WAIT_SENDER;
                            else
                                start <= '0';
                            end if;
                        when WAIT_SENDER =>
                            if busy = '1' then
                                start <= '0';
                                state <= EOF;
                            end if;
                        when EOF =>
                            state <= IDLE;
                    end case;
                end if;
            end if;
    end process clocking;
end architecture RTL;