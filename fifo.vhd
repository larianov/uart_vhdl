library ieee;
use ieee.std_logic_1164.all;
use ieee.NUMERIC_STD.all;


entity fifo is
    generic(
        byte_size : integer := 8;
        fifo_size : integer := 16;
        threshold : integer := 0
    );
    port(
        push : in std_logic;
        byte_pl : in std_logic_vector(byte_size-1 downto 0);

        rst : in std_logic;
        clk : in std_logic;
        
        threshold_act : out std_logic;
        empty : out std_logic;
        full : out std_logic;
        

        pop : in std_logic;
        byte_out_pl : out std_logic_vector(byte_size-1 downto 0)
    );
end entity fifo;


architecture rtl of fifo is
    type fifo_buff_t is array (0 to fifo_size) of std_logic_vector(byte_size-1 downto 0); 
    signal fifo_buff : fifo_buff_t := (others => (others => 'Z'));
    signal size : natural range 0 to fifo_size := 0;
    signal read : natural range 0 to fifo_size := 0;
    signal write : natural range 0 to fifo_size := 0;    
begin
    clocking : process(clk)
        begin
            if rising_edge(clk) then
                if rst = '1' then
                    size <= 0;
                    read <= 0;
                    write <= 0;
                end if;
                if push = '1' then
                    if size < fifo_size then
                        fifo_buff(write) <= byte_pl;
                        if write = fifo_size-1 then
                            write <= 0;
                        else
                            write <= write+1;
                        end if;
                    end if;
                end if;
                if pop = '1' then
                    if size /= 0 then
                        byte_out_pl <= fifo_buff(read);
                        if read = fifo_size-1 then
                            read <= 0;
                        else
                            read <= read+1;
                        end if;
                    end if;
                end if;
                if push = '1' and pop = '0' and size < fifo_size then
                     size <= size+1;
                end if;
                if pop = '1' and push = '0' and size /= 0 then
                    size <= size-1;
                end if;
            end if;
    end process clocking;
    empty <= '1' when size = 0 else '0';
    full <= '1' when size = fifo_size else '0';
    threshold_act <= '1' when size > threshold;  
end architecture rtl;

