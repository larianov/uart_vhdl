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
        rst : in std_logic;
        tx : out STD_LOGIC := '1'
    );
end uart_transfer;

architecture RTL of uart_transfer is
    constant clk_rate : natural := (freq + baud/2)/baud;
    signal timer_counter : unsigned(31 downto 0) := (others => '0');
    signal last_start : STD_LOGIC := '0';
    signal started_transmission : STD_LOGIC := '0';
    signal data_copy : std_logic_vector(hi downto lo);
    signal bit_counter : natural range lo to hi+1 := 0;
    type state_transfering_t is (IDLE, DATA_OP, STOP_TRANSMISSION);
    signal state : state_transfering_t;
begin
    process(clk) begin
        if rising_edge(clk) then
            if rst = '1' then
                bit_counter <= 0;
                data_copy <= (others => '0');
                started_transmission <= '0';
                timer_counter <= (others => '0');
                tx <= '1';
                state <= IDLE;
            else
                case state is 
                    when IDLE =>
                        if last_start = '0' and start = '1' and started_transmission /= '1' then
                            tx <= '0';
                            timer_counter <= (others => '0');
                            bit_counter <= 0;
                            state <= DATA_OP;
                            data_copy <= data;
                            started_transmission <= '1';
                        else
                            tx <= '1';
                        end if;
                    when DATA_OP =>
                        if timer_counter >= clk_rate-1 then
                            if bit_counter = hi+1 then
                                state <= STOP_TRANSMISSION;
                                tx <= '1';
                                timer_counter <= (others => '0');
                                bit_counter <= 0;
                            else
                                tx <= data_copy(bit_counter);
                                bit_counter <= bit_counter + 1;
                                timer_counter <= (others => '0');
                            end if;
                        else
                            timer_counter <= timer_counter+1;
                        end if;
                    when STOP_TRANSMISSION =>
                        if timer_counter >= clk_rate-1 then
                            bit_counter <= bit_counter+1;
                            if bit_counter = stop_bits-1 then
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
        end if;
    end process;
    busy <= started_transmission;
end architecture RTL;
