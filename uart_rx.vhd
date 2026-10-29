library ieee;
use ieee.NUMERIC_STD.all;
use ieee.std_logic_1164.all;

entity uart_rx is 
    generic(
        freq : integer := 50000000;
        baud : integer := 115200;
        amm_data_bits :integer := 8;
        amm_stop_bits : integer := 1;
        en_pairity : natural := 0; -- 0 for off, 1 for on
        pairity : std_logic := '0'; -- 0 for even, 1 for odd
        threshold : integer := 1  
    );
    port (
        en_fifo : in std_logic;
        read_one_byte : in std_logic; -- if fifo turned on, takes one byte per clock from fifo, if fifo not empty. if fifo empty or not enabled, start reading one byte 
        clk : in std_logic;
        byte_ready : out std_logic;
        data_byte : out std_logic_vector(amm_data_bits-1 downto 0)
    );
end entity uart_rx;


architecture RTL of uart_rx is
    type uart_rx_t is (IDLE, START, DATA, STOP);
    signal state : uart_rx_t;
    signal push : std_logic;
    signal pop : std_logic;
    signal byte_pl : std_logic_vector(amm_data_bits-1 downto 0);
    signal rst : STD_LOGIC;
    signal threshold_act : STD_LOGIC;
    signal empty : std_logic;
    signal full : std_logic;
    

    begin 
        fifo_uart : entity work.fifo
        generic map(
            byte_size => amm_data_bits,
            fifo_size => 16,
            threshold => threshold
        )
        port map(
            push          => push,
            byte_pl       => byte_pl,
            rst           => rst,
            clk           => clk,
            threshold_act => threshold_act,
            empty         => empty,
            full          => full,
            push_err => open,
            pop_err => open,
            pop           => pop,
            byte_out_pl   => data_byte;
        );

    
end architecture RTL;
