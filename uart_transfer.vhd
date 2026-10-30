library ieee;
use ieee.std_logic_1164.all;
use ieee.NUMERIC_STD.all;

entity uart_transfer is 
    generic (
        freq : integer := 50000000;
        baud : integer := 115200;
        hi : integer := 7;
        lo : integer := 0;
        stop_bits : integer := 1
    );
    port (
        data : in std_logic_vector(hi downto lo);
        start : in STD_LOGIC;
        clk : in Std_logic;
        busy : out STD_LOGIC;
        tx : out STD_LOGIC
    );
end uart_transfer;

architecture RTL of uart_transfer is
    constant clk_rate : integer := freq / baud;
    signal timer_counter : unsigned(31 downto 0) := (others => '0');
    signal last_start : STD_LOGIC := '0';
    signal started_transmission : STD_LOGIC := '0';
    signal bit_counter : natural range lo to hi+1 := 0;
    type state_transfering_t is (IDLE, START_TRANSMISSION, DATA_OP, STOP_TRANSMISSION);
    signal state : state_transfering_t;
begin
    process(clk) begin
        if rising_edge(clk) then
            case state is 
                when IDLE =>
                    if last_start = '0' and start = '1' and started_transmission /= '1' then
                        tx <= '0';
                        timer_counter <= (others => '0');
                        bit_counter <= 0;
                        state <= START_TRANSMISSION;
                        started_transmission <= '1';
                    else
                        tx <= '1';
                    end if;
                when START_TRANSMISSION =>
                    if timer_counter = 0 then
                        tx <= '0';
                        timer_counter <= timer_counter + 1;
                    end if;
                    if timer_counter >= clk_rate+1 then
                        state <= DATA_OP;
                    else
                        timer_counter <= timer_counter+1;
                    end if;
                when DATA_OP =>
                    if timer_counter >= clk_rate+1 then
                        if bit_counter = hi+1 then
                            state <= STOP_TRANSMISSION;
                            timer_counter <= (others => '0');
                            bit_counter <= 0;
                        else
                            tx <= data(bit_counter);
                            bit_counter <= bit_counter + 1;
                            timer_counter <= (others => '0');
                        end if;
                    else
                        timer_counter <= timer_counter+1;
                    end if;
                when STOP_TRANSMISSION =>
                    if timer_counter >= clk_rate+1 then
                        bit_counter <= bit_counter+1;
                        if bit_counter = stop_bits then
                            state <= IDLE;
                            started_transmission <= '0';
                        end if;
                        timer_counter <= (others => '0');
                    else
                        tx <= '1';
                        timer_counter <= timer_counter+1;
                    end if;
            end case;
            last_start <= start;   
        end if;
    end process;
    busy <= started_transmission;
end architecture RTL;
