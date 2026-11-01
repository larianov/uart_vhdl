library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity uart_main is
    port(
        clk : in std_logic;
        rx_line : in std_logic;
        tx_line : out std_logic
    );
end entity uart_main;

architecture RTL of uart_main is

    function from_string_to_vector(str : string) return STD_LOGIC_VECTOR is
        variable to_ret : std_logic_vector((str'length*8)-1 downto 0) := (others => '0');
        begin
            for i in str'range loop
                to_ret := to_ret(to_ret'length-9 downto 0) & STD_LOGIC_VECTOR(TO_UNSIGNED(character'pos(str(i)), 8));
            end loop;
        return to_ret;
    end function from_string_to_vector;


    constant orig_str1 : string := "hello";
    constant orig_str2 : string := "world";
    constant str1 : std_logic_vector := from_string_to_vector(orig_str1);
    constant str2 : std_logic_vector := from_string_to_vector(orig_str2);
    
    signal boolean_first_line : boolean := true;
    
    signal tx_byte_pl : std_logic_vector(7 downto 0);
    signal rx_byte_pl : std_logic_vector(7 downto 0);
    signal rx_take_byte : std_logic := '0';
    signal tx_send_byte : std_logic := '0';
    signal rst : std_logic := '1';
    
    signal byte_counter : integer range 0 to orig_str1'length+orig_str2'length := 1;
    

    signal tx_busy : std_logic;
    signal tx_fifo_full : std_logic;
    signal rx_fifo_empty : std_logic;
    signal window_string : std_logic_vector(39 downto 0) := (others => '0');
    type state_t is (READING, SENDING, SENT);
    signal state : state_t;
    signal popped : std_logic := '0';
    signal bitt : integer := 0;
    

begin
    uart_inst : entity work.uart
        generic map(
            freq              => 50000000,
            baud              => 2_000_000,
            amm_data_bits     => 8,
            amm_stop_bits     => 2,
            en_pairity        => 1,
            pairity           => '0',
            fifo_size         => 16,
            rx_treshold_level => 1
        )
        port map(
            clk            => clk,
            rst            => rst,
            tx_enable      => '1',
            tx_line        => tx_line,
            place_for_tx   => tx_byte_pl,
            send_byte      => tx_send_byte,
            tx_fifo_full   => tx_fifo_full,
            tx_busy        => tx_busy,
            rx_enable      => '1',
            rx_line        => rx_line,
            place_for_rx   => rx_byte_pl,
            recieve_byte   => rx_take_byte,
            rx_empty_fifo  => rx_fifo_empty,
            tx_fifo_err    => open,
            rx_fifo_err    => open,
            rx_uart_err    => open,
            rx_water_level => open
    );
    
    clocking : process(clk) is        
    begin
        if rising_edge(clk) then
                rst <= '0';
                case state is
                    when READING =>
                        if window_string = str1 or window_string = str2 then
                            if window_string = str1 then
                                boolean_first_line <= FALSE;
                            else
                                boolean_first_line <= TRUE;
                            end if;
                            state <= SENDING;
                        elsif rx_take_byte = '1' then
                            rx_take_byte <= '0';
                            popped <= '1';
                        elsif popped = '1' then
                            popped <= '0';
                            window_string <= window_string(window_string'length-9 downto 0) & rx_byte_pl;
                        elsif rx_fifo_empty = '0' then
                            rx_take_byte <= '1';
                        end if;
        
                    when SENDING =>
                        if boolean_first_line then
                            if byte_counter > orig_str1'length then
                                state <= READING;
                                tx_send_byte <= '0';
                                byte_counter <= 1;
                                window_string <= (others => '0');
                            else
                                if tx_busy = '0' or tx_fifo_full = '0' then
                                    tx_byte_pl <= STD_LOGIC_VECTOR(TO_UNSIGNED(character'pos(orig_str1(byte_counter)), 8));
                                    byte_counter <= byte_counter+1;
                                    tx_send_byte <= '1';
                                    state <= SENT;
                                end if;
                            end if;
                        else
                             if byte_counter > orig_str2'length then
                                state <= READING;
                                tx_send_byte <= '0';
                                byte_counter <= 1;
                                window_string <= (others => '0');
                            else
                                if tx_busy = '0' or tx_fifo_full = '0' then          
                                    tx_byte_pl <= STD_LOGIC_VECTOR(TO_UNSIGNED(character'pos(orig_str2(byte_counter)), 8));
                                    byte_counter <= byte_counter+1;
                                    tx_send_byte <= '1';
                                    state <= SENT;
                                end if;
                            end if;
                        end if;
                    when SENT =>
                        tx_send_byte <= '0';
                        if tx_busy = '1' then
                            state <= SENDING;
                        end if;
                end case;
        end if;
    
    
    end process clocking;
end architecture RTL;
