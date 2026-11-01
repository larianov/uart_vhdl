library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity uart is
    generic(
        freq : integer := 50000000;
        baud : positive range 1 to 10_000_000 := 115200;
        amm_data_bits : integer range 1 to 16 := 8;
        amm_stop_bits : integer range 1 to 4 := 1;
        en_pairity : integer := 0;
        pairity : STD_LOGIC := '0';
        fifo_size : integer range 1 to 16 := 16;
        rx_treshold_level : integer range 0 to 16 := 1
    );
    port(
        clk : in std_logic;
        rst : in std_logic;

        tx_enable : in std_logic;   
        tx_line : out std_logic;
        place_for_tx : in std_logic_vector(amm_data_bits-1 downto 0);
        send_byte : in std_logic;
        tx_fifo_full : out std_logic;
        tx_fifo_err : out std_logic;
        tx_busy : out std_logic;
        rx_enable : in std_logic;
        rx_line : in std_logic;
        place_for_rx : out std_logic_vector(amm_data_bits-1 downto 0);
        recieve_byte : in std_logic;
        rx_empty_fifo : out std_logic;
        rx_fifo_err : out std_logic;
        rx_uart_err : out std_logic;
        rx_water_level : out std_logic
    );
end entity uart;

architecture RTL of uart is

begin
      uart_tx_inst : entity work.uart_tx
        generic map(
            freq          => freq,
            baud          => baud,
            amm_data_bits => amm_data_bits,
            amm_stop_bits => amm_stop_bits,
            fifo_size     => fifo_size,
            en_pairity    => en_pairity,
            pairity       => pairity
        )
        port map(
            clk       => clk,
            rst       => rst,
            full      => tx_fifo_full,
            tx        => tx_line,
            push      => send_byte,
            push_err  => tx_fifo_err,
            byte_pl   => place_for_tx,
            uart_en   => tx_enable,
            busy_wait => tx_busy
        );
    uart_rx_inst : entity work.uart_rx
        generic map(
            freq          => freq,
            baud          => baud,
            amm_data_bits => amm_data_bits,
            amm_stop_bits => amm_stop_bits,
            en_pairity    => en_pairity,
            pairity_t     => pairity,
            fifo_size     => fifo_size,
            threshold     => rx_treshold_level
        )
        port map(
            clk           => clk,
            rst           => rst,
            rx_line_async => rx_line,
            data_byte     => place_for_rx,
            pop           => recieve_byte,
            empty         => rx_empty_fifo,
            pop_err       => rx_fifo_err,
            threshold_act => rx_water_level,
            en_uart       => rx_enable,
            uart_err      => rx_uart_err
        );
end architecture RTL;

