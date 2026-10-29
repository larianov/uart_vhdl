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
    );

    port (
        start_
    );
end entity uart_rx;
