library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity uart_tx is 
    generic(
        strdata : string := "Hello world";
        freq : integer := 50000000;
        baud : integer := 115200;
        hi : integer := 7;
        lo : integer := 0;
        amm_stop_bits : integer := 1;
        en_pairity : integer := 0; -- 1 for on 0 for off
        pairity : std_logic := '1' --1 for odd 0 for even;
    );
    port(
        clk : in std_logic;
        start_transmitting : in std_logic;
        tx : out std_logic;
        busy_wait : out std_logic
    );
end uart_tx;

architecture RTL of uart_tx is

signal data :std_logic_vector(hi+en_pairity downto lo) := (others => '0');
signal start : std_logic := '0';
signal busy : std_logic := '0';
type tx_t is (IDLE, DATA_OP, EOF);
signal state : tx_t;
signal first_start_front : STD_LOGIC := '0';
signal second_start_front : std_logic := '1'; 
signal letter_counter : integer range 0 to strdata'length+1 := 1;





begin
    uart_transfer_inst : entity work.uart_transfer
        generic map(
            freq      => freq,
            baud      => baud,
            hi        => hi+en_pairity,
            lo        => lo,
            stop_bits => amm_stop_bits
        )
        port map(
            data  => data,
            start => start,
            clk   => clk,
            busy  => busy,
            tx    => tx
        );
    
    clocking : process(clk) is
        variable acc : std_logic;
        variable temp_d : std_logic_vector(hi downto lo);
        
        begin
            if rising_edge(clk) then
                case state is
                    when IDLE =>
                        second_start_front <= first_start_front;
                        first_start_front <= start_transmitting;
                        if second_start_front = '1' then
                            state <= DATA_OP;
                            busy_wait <= '1';
                        end if;
                    when DATA_OP =>
                        if letter_counter > strdata'length then
                            state <= EOF;
                        elsif busy = '0' then
                            temp_d := STD_LOGIC_VECTOR(to_unsigned(character'pos(strdata(letter_counter)), temp_d'length));
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
                            letter_counter <= letter_counter+1;
                        else
                            start <= '0';
                        end if;

                    when EOF =>
                        busy_wait <= '0';
                end case;
            end if;
    end process clocking;
end architecture RTL;