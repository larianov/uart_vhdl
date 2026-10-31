library ieee;
use ieee.NUMERIC_STD.all;
use ieee.std_logic_1164.all;

entity uart_rx is 
    generic(
        freq : natural := 50000000;
        baud : positive := 115200;
        amm_data_bits :integer := 8;
        amm_stop_bits : integer := 1;
        en_pairity : integer := 0; -- 0 for off, 1 for on
        pairity_t : std_logic := '0'; -- 0 for even, 1 for odd
        fifo_size : integer := 16;
        threshold : integer := 1  
    );
    port (
        clk : in std_logic;
        rx_line_async : in std_logic;
        data_byte : out std_logic_vector(amm_data_bits-1 downto 0);
        pop : in std_logic;
        empty : out std_logic;
        pop_err : out std_logic;
        threshold_act : out std_logic;
        
        en_uart : in std_logic;
        uart_err : out std_logic := '0' -- appears on framing err/pairity err, clears after first correct bit
    );
end entity uart_rx;


architecture RTL of uart_rx is
    constant clk_rate : natural := freq / baud;
    signal clock_divider : integer range 0 to clk_rate+1 := 0;

    type uart_rx_t is (INIT, IDLE, START, DATA, PAIRITY, STOP);
    signal state : uart_rx_t := INIT;
    signal push : std_logic;
    signal last_rx : std_logic := '1';
    signal byte_pl : std_logic_vector(amm_data_bits-1 downto 0);
    signal rst : STD_LOGIC;
    signal bit_counter : integer range 0 to amm_data_bits+amm_stop_bits := 0;
    
    signal rx_line_async_fr1 : std_logic := '1';
    signal rx_line : std_logic := '1';
    
    
    
    
    
begin 
    fifo_uart : entity work.fifo
    generic map(
        byte_size => amm_data_bits,
        fifo_size => fifo_size,
        threshold => threshold,
        force_wrap => '1'
    )
    port map(
        push          => push,
        byte_pl       => byte_pl,
        rst           => rst,
        clk           => clk,
        threshold_act => threshold_act,
        empty         => empty,
        full          => open,
        push_err => open,
        pop_err => pop_err,
        pop           => pop,
        byte_out_pl   => data_byte
    );
        
    clocking : process(clk)
        variable acc : std_logic := '0';
        variable pairity_bit : std_logic := '0';
    begin
        if(rising_edge(clk)) then
            rx_line <= rx_line_async_fr1;
            rx_line_async_fr1 <= rx_line_async;
            case state is
                when INIT =>
                    rst <= '1';
                    state <= IDLE;
                when IDLE =>
                    clock_divider <= 0;
                    bit_counter <= 0;
                    push <= '0';
                    rst <= '0';
                    if en_uart = '1' then
                        state <= START;
                    end if;
                when START =>
                    if clock_divider >= clk_rate/2 then
                        if rx_line = '0' then
                            state <= data;
                        else 
                            state <= idle;
                        end if;
                        clock_divider <= 0;
                    elsif clock_divider > 0 then
                        clock_divider <= clock_divider+1;
                    elsif en_uart = '0' then
                        state <= IDLE;
                    elsif last_rx = '1' and rx_line = '0' then
                        clock_divider <= 1;
                    end if;
                when DATA =>
                    if clock_divider >= clk_rate then
                        byte_pl(bit_counter) <= rx_line;
                        if bit_counter = amm_data_bits - 1 then
                            if en_pairity = 1 then
                                state <= PAIRITY;
                            else
                                bit_counter <= 0;
                                state <= STOP;
                            end if;
                        else
                            bit_counter <= bit_counter+1;
                        end if;
                        clock_divider <= 0;
                    else
                        clock_divider <= clock_divider+1;
                    end if;    
                when PAIRITY  =>
                    if clock_divider >= clk_rate then
                        pairity_bit := rx_line;
                        acc := '0';
                        for i in byte_pl'range loop
                            acc := acc xor byte_pl(i);
                        end loop;
                        if pairity_t = '1' then
                            if not acc /= pairity_bit then
                                uart_err <= '1';
                                state <= IDLE;
                            else
                                state <= STOP;
                            end if;
                        else
                            if acc /= pairity_bit then
                                uart_err <= '1';
                                state <= IDLE;
                            else
                                state <= STOP;
                            end if;
                        end if;
                        clock_divider <= 0;
                        bit_counter <= 0;
                    else
                        clock_divider <= clock_divider+1;
                    end if;
                when STOP =>
                    if clock_divider >= clk_rate then
                        if rx_line = '1' then
                            if bit_counter = amm_stop_bits-1 then
                                state <= IDLE;
                                uart_err <= '0';
                                push <= '1';
                            end if;
                            bit_counter <= bit_counter+1;
                        else
                            state <= IDLE;
                            uart_err <= '1';
                        end if;
                        clock_divider <= 0;
                    else
                        clock_divider <= clock_divider+1;
                    end if;
                end case;
            last_rx <= rx_line;
        end if;
    end process clocking;

    
end architecture RTL;
